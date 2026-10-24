//! Fetching a plugin's package into a project, in the background: `zig fetch` it, check its
//! `build.zig.zon` has the fingerprint the plugin's manifest names, and only then save it as a
//! dependency (`zig fetch --save`), which pins its content hash. The Plugins window then lists the
//! plugin in the project's `eggy.zon`.
const std = @import("std");
const zon_file = @import("eggy").assets.zon;
const builtin = @import("builtin");

pub const Request = struct {
    /// The project's folder, absolute.
    project_dir: []const u8,
    /// The package, as `zig fetch` takes it.
    url: []const u8,
    /// The dependency to save it as.
    dependency: []const u8,
    /// The fingerprint its `build.zig.zon` must have.
    fingerprint: u64,
};

/// What an install ended with.
pub const Outcome = union(enum) {
    saved,
    /// Why it failed, for people.
    failed: []const u8,
};

/// One package being fetched on a worker.
pub const Install = struct {
    gpa: std.mem.Allocator,
    /// The worker's I/O, with the editor's environment so `zig` is found on PATH.
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,
    request: Request,
    worker: std.Io.Future(void) = undefined,

    // Shared with the worker, under `mutex`.
    mutex: std.Io.Mutex = .init,
    /// What it did so far, a line each.
    log: std.ArrayList(u8) = .empty,
    outcome: ?Outcome = null,
    /// `failed`'s text, owned.
    reason: std.ArrayList(u8) = .empty,

    /// Start fetching `request`'s package (copied).
    pub fn start(gpa: std.mem.Allocator, request: Request) !*Install {
        const self = try gpa.create(Install);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .threaded = .init(gpa, .{ .environ = processEnviron() }), .arena = .init(gpa), .request = undefined };
        errdefer self.threaded.deinit();
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.request = .{ .project_dir = try a.dupe(u8, request.project_dir), .url = try a.dupe(u8, request.url), .dependency = try a.dupe(u8, request.dependency), .fingerprint = request.fingerprint };
        self.worker = try self.threaded.io().concurrent(work, .{self});
        return self;
    }

    /// Stop it if it is still fetching (the dependency stays unsaved), and free it.
    pub fn destroy(self: *Install) void {
        const gpa = self.gpa;
        self.worker.cancel(self.threaded.io());
        self.threaded.deinit();
        self.log.deinit(gpa);
        self.reason.deinit(gpa);
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Its log so far and its outcome, if it has one, copied into `arena`.
    pub fn status(self: *Install, arena: std.mem.Allocator) !struct { log: []const u8, outcome: ?Outcome } {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const outcome: ?Outcome = if (self.outcome) |done| switch (done) {
            .saved => .saved,
            .failed => .{ .failed = try arena.dupe(u8, self.reason.items) },
        } else null;
        return .{ .log = try arena.dupe(u8, self.log.items), .outcome = outcome };
    }

    fn say(self: *Install, comptime fmt: []const u8, args: anytype) void {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.log.print(self.gpa, fmt ++ "\n", args) catch {};
    }

    fn work(self: *Install) void {
        const outcome: Outcome = if (self.fetchChecked()) .saved else |err| blk: {
            const io = self.threaded.io();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.reason.items.len == 0) self.reason.appendSlice(self.gpa, describe(err)) catch {};
            break :blk .{ .failed = self.reason.items };
        };
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.outcome = outcome;
    }

    fn fetchChecked(self: *Install) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const request = self.request;

        // Fetched, not saved yet: Zig names it by its content hash.
        self.say("$ zig fetch {s}", .{request.url});
        const hash = std.mem.trim(u8, try self.zig(arena, &.{ "zig", "fetch", request.url }), " \r\n");

        // Its fingerprint, against the one the manifest names.
        const found = try self.fingerprintOf(arena, hash);
        if (found != request.fingerprint) {
            self.fail("The package's build.zig.zon has fingerprint 0x{x}, but the plugin's eggy.zon names 0x{x}: it isn't the package the plugin says it is, so it wasn't installed.", .{ found, request.fingerprint });
            return error.FingerprintMismatch;
        }
        self.say("Fingerprint 0x{x} matches", .{found});

        // Saved: Zig pins its hash in build.zig.zon.
        self.say("$ zig fetch --save={s} {s}", .{ request.dependency, request.url });
        _ = try self.zig(arena, &.{ "zig", "fetch", try std.fmt.allocPrint(arena, "--save={s}", .{request.dependency}), request.url });
    }

    /// Run `argv` in the project, returning its standard output; a failure keeps its error output
    /// as the reason.
    fn zig(self: *Install, arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
        const result = std.process.run(arena, self.threaded.io(), .{ .argv = argv, .cwd = .{ .path = self.request.project_dir } }) catch |err| return switch (err) {
            error.FileNotFound => error.ZigNotFound,
            else => err,
        };
        if (result.term == .exited and result.term.exited == 0) return result.stdout;
        self.fail("{s}", .{std.mem.trim(u8, result.stderr, " \r\n")});
        return error.FetchFailed;
    }

    /// The fingerprint in the `build.zig.zon` of the package fetched as `hash`: in the project's
    /// `zig-pkg` folder, or Zig's global cache, unpacked or as the `<hash>.tar.gz` Zig 0.17 keeps.
    fn fingerprintOf(self: *Install, arena: std.mem.Allocator, hash: []const u8) !u64 {
        const text = try self.packageZon(arena, hash) orelse {
            self.fail("Couldn't find the fetched package {s}.", .{hash});
            return error.FileNotFound;
        };
        return fingerprintIn(arena, text) catch {
            self.fail("The package's build.zig.zon has no fingerprint, so it can't be checked.", .{});
            return error.NoFingerprint;
        };
    }

    /// The text of the fetched package's `build.zig.zon`, or null where Zig left none.
    fn packageZon(self: *Install, arena: std.mem.Allocator, hash: []const u8) !?[:0]u8 {
        const io = self.threaded.io();
        const cache = globalCache(arena);
        const folders = [_]?[]const u8{
            try std.fs.path.join(arena, &.{ self.request.project_dir, "zig-pkg", hash }),
            if (cache) |dir| try std.fs.path.join(arena, &.{ dir, "p", hash }) else null,
        };
        for (folders) |maybe| if (maybe) |folder| {
            const path = try std.fs.path.join(arena, &.{ folder, "build.zig.zon" });
            if (std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0)) |text| return text else |_| {}
        };
        const dir = cache orelse return null;
        const archive = try std.fs.path.join(arena, &.{ dir, "p", try std.fmt.allocPrint(arena, "{s}.tar.gz", .{hash}) });
        var file = std.Io.Dir.cwd().openFile(io, archive, .{}) catch return null;
        defer file.close(io);
        var file_buffer: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &file_buffer);
        return try zonInArchive(arena, &file_reader.interface, hash);
    }

    fn fail(self: *Install, comptime fmt: []const u8, args: anytype) void {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.reason.clearRetainingCapacity();
        self.reason.print(self.gpa, fmt, args) catch {};
    }
};

/// The `<hash>/build.zig.zon` inside `gzipped`, a package as Zig's cache archives it; null
/// without one.
fn zonInArchive(arena: std.mem.Allocator, gzipped: *std.Io.Reader, hash: []const u8) !?[:0]u8 {
    const wanted = try std.fmt.allocPrint(arena, "{s}/build.zig.zon", .{hash});
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var gunzip = std.compress.flate.Decompress.init(gzipped, .gzip, window);
    var file_name: [std.fs.max_path_bytes]u8 = undefined;
    var link_name: [std.fs.max_path_bytes]u8 = undefined;
    var entries = std.tar.Iterator.init(&gunzip.reader, .{ .file_name_buffer = &file_name, .link_name_buffer = &link_name });
    while (try entries.next()) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.name, wanted)) continue;
        if (entry.size > 1 << 20) return error.StreamTooLong;
        const text = try arena.allocSentinel(u8, @intCast(entry.size), 0);
        try entries.reader.readSliceAll(text);
        return text;
    }
    return null;
}

/// The `.fingerprint` of `text`, a `build.zig.zon`.
fn fingerprintIn(arena: std.mem.Allocator, text: [:0]const u8) !u64 {
    const zon = try zon_file.parse(struct { fingerprint: u64 }, arena, text, .{ .ignore_unknown_fields = true });
    return zon.fingerprint;
}

/// Zig's global cache folder, as `zig env` would name it, in `arena`.
fn globalCache(arena: std.mem.Allocator) ?[]const u8 {
    if (std.c.getenv("ZIG_GLOBAL_CACHE_DIR")) |dir| return arena.dupe(u8, std.mem.span(dir)) catch null;
    if (builtin.os.tag == .windows) {
        const local = std.c.getenv("LOCALAPPDATA") orelse return null;
        return std.fs.path.join(arena, &.{ std.mem.span(local), "zig" }) catch null;
    }
    if (std.c.getenv("XDG_CACHE_HOME")) |cache| return std.fs.path.join(arena, &.{ std.mem.span(cache), "zig" }) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fs.path.join(arena, &.{ std.mem.span(home), if (builtin.os.tag == .macos) "Library/Caches/zig" else ".cache/zig" }) catch null;
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.ZigNotFound => "Zig 0.16 isn't on your PATH. Install it, then try again.",
        else => "Couldn't fetch the plugin's package: see the Console.",
    };
}

fn processEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => .{ .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) } },
    };
}

test "a package's build.zig.zon is read out of the archive Zig's cache keeps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A package as Zig 0.17 caches it: `<hash>.tar.gz`, its files under a `<hash>/` folder.
    var gzipped: std.Io.Writer.Allocating = .init(a);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip = try std.compress.flate.Compress.Raw.init(&gzipped.writer, &window, .gzip);
    var tar = std.tar.Writer{ .underlying_writer = &gzip.writer };
    try tar.writeFileBytes("pkg-0.1.0-abc/build.zig", "", .{});
    try tar.writeFileBytes("pkg-0.1.0-abc/build.zig.zon", ".{ .name = .pkg, .fingerprint = 0x9fbfb05e800ea209 }", .{});
    try tar.finishPedantically();
    try gzip.finish();

    var archive: std.Io.Reader = .fixed(gzipped.written());
    const text = (try zonInArchive(a, &archive, "pkg-0.1.0-abc")).?;
    try std.testing.expectEqual(@as(u64, 0x9fbfb05e800ea209), try fingerprintIn(a, text));
    archive = .fixed(gzipped.written());
    try std.testing.expect(try zonInArchive(a, &archive, "other-hash") == null);
}

test "a package's fingerprint is read past its other fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u64, 0x634131700cbdf8dd), try fingerprintIn(arena.allocator(),
        \\.{
        \\    .name = .eggy,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x634131700cbdf8dd,
        \\    .dependencies = .{ .sdl3 = .{ .url = "git+https://example.com/sdl", .hash = "sdl3-0" } },
        \\    .paths = .{ "build.zig", "src" },
        \\}
    ));
}
