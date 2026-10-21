//! Fetching a plugin's package into a project, in the background: `zig fetch` it, check its
//! `build.zig.zon` has the fingerprint the plugin's manifest names, and only then save it as a
//! dependency (`zig fetch --save`), which pins its content hash. The Plugins window then lists the
//! plugin in the project's `eggy.zon`.
const std = @import("std");
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
    /// `zig-pkg` folder, or Zig's global cache.
    fn fingerprintOf(self: *Install, arena: std.mem.Allocator, hash: []const u8) !u64 {
        const io = self.threaded.io();
        var places: std.ArrayList([]const u8) = .empty;
        try places.append(arena, try std.fs.path.join(arena, &.{ self.request.project_dir, "zig-pkg", hash, "build.zig.zon" }));
        if (globalCache(arena)) |cache| try places.append(arena, try std.fs.path.join(arena, &.{ cache, "p", hash, "build.zig.zon" }));
        for (places.items) |path| {
            const text = std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0) catch continue;
            return fingerprintIn(arena, text) catch {
                self.fail("The package's build.zig.zon has no fingerprint, so it can't be checked.", .{});
                return error.NoFingerprint;
            };
        }
        self.fail("Couldn't find the fetched package {s}.", .{hash});
        return error.FileNotFound;
    }

    fn fail(self: *Install, comptime fmt: []const u8, args: anytype) void {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.reason.clearRetainingCapacity();
        self.reason.print(self.gpa, fmt, args) catch {};
    }
};

/// The `.fingerprint` of `text`, a `build.zig.zon`.
fn fingerprintIn(arena: std.mem.Allocator, text: [:0]const u8) !u64 {
    const zon = try std.zon.parse.fromSliceAlloc(struct { fingerprint: u64 }, arena, text, null, .{ .ignore_unknown_fields = true });
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
