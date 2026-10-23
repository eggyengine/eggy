//! Reading a plugin's `eggy.zon` and read-me from where it is, an address or a path, in the
//! background, so the Plugins window keeps drawing meanwhile.
const std = @import("std");
const builtin = @import("builtin");
const eggy = @import("eggy");
const source = @import("source.zig");
const Manifest = eggy.plugin_manifest.Manifest;

/// The most a manifest or read-me may be.
const max_file = 1 << 20;

/// A plugin as read, ready for the Plugins window to show and install. Owns its strings.
pub const Fetched = struct {
    arena: std.heap.ArenaAllocator,
    origin: source.Origin,
    manifest: Manifest,
    /// Its read-me's markdown; null when it has none.
    readme: ?[]const u8,
    package: source.Package,

    pub fn destroy(self: *Fetched) void {
        var arena = self.arena;
        arena.deinit();
    }

    /// A plugin from its manifest and read-me's text (both copied), as found at `origin`.
    /// Fails as `eggy.plugin_manifest.parse` does, or as `source.packageFor`.
    pub fn create(gpa: std.mem.Allocator, origin: source.Origin, manifest_text: []const u8, readme: ?[]const u8, package_root: ?[]const u8) !*Fetched {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const kept_origin: source.Origin = switch (origin) {
            .url => |url| .{ .url = try a.dupe(u8, url) },
            .path => |path| .{ .path = try a.dupe(u8, path) },
        };
        const manifest = try eggy.plugin_manifest.parse(a, try a.dupeSentinel(u8, manifest_text, 0));
        const package = try source.packageFor(a, manifest, kept_origin, if (package_root) |root| try a.dupe(u8, root) else null);
        const self = try a.create(Fetched);
        self.* = .{ .arena = undefined, .origin = kept_origin, .manifest = manifest, .readme = if (readme) |text| try a.dupe(u8, text) else null, .package = package };
        self.arena = arena;
        return self;
    }
};

/// What a fetch ended with.
pub const Outcome = union(enum) {
    fetched: *Fetched,
    /// Why it failed, for people: static text.
    failed: []const u8,
};

/// One plugin being read on a worker.
pub const Fetch = struct {
    gpa: std.mem.Allocator,
    /// The worker's I/O, with the editor's environment (for proxies and certificates).
    threaded: std.Io.Threaded,
    origin_arena: std.heap.ArenaAllocator,
    origin: source.Origin,
    worker: std.Io.Future(void) = undefined,

    // Shared with the worker, under `mutex`.
    mutex: std.Io.Mutex = .init,
    outcome: ?Outcome = null,
    /// Whether `take` handed the outcome out.
    taken: bool = false,

    /// Start reading the plugin at `typed` (see `source.locate`; relative paths from `cwd`).
    /// Fails at once only for blank input or allocation; reading failures come from `take`.
    pub fn start(gpa: std.mem.Allocator, typed: []const u8, cwd: []const u8) !*Fetch {
        const self = try gpa.create(Fetch);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .threaded = .init(gpa, .{ .environ = processEnviron() }), .origin_arena = .init(gpa), .origin = undefined };
        errdefer self.threaded.deinit();
        errdefer self.origin_arena.deinit();
        self.origin = try source.locate(self.origin_arena.allocator(), typed, cwd);
        self.worker = try self.threaded.io().concurrent(work, .{self});
        return self;
    }

    /// Where it is reading from.
    pub fn location(self: *const Fetch) []const u8 {
        return self.origin.text();
    }

    /// Its outcome, once, when it has one; the caller then owns a `Fetched`.
    pub fn take(self: *Fetch) ?Outcome {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.taken) return null;
        const outcome = self.outcome orelse return null;
        self.taken = true;
        return outcome;
    }

    /// Stop reading if it still is, and free it (and an outcome nobody took).
    pub fn destroy(self: *Fetch) void {
        const gpa = self.gpa;
        const io = self.threaded.io();
        self.worker.cancel(io);
        if (self.outcome) |outcome| if (outcome == .fetched and !self.taken) outcome.fetched.destroy();
        self.threaded.deinit();
        self.origin_arena.deinit();
        gpa.destroy(self);
    }

    fn work(self: *Fetch) void {
        const outcome: Outcome = if (self.read()) |fetched| .{ .fetched = fetched } else |err| .{ .failed = describe(err) };
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.outcome = outcome;
    }

    fn read(self: *Fetch) !*Fetched {
        const io = self.threaded.io();
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var client: std.http.Client = .{ .allocator = self.gpa, .io = io };
        defer client.deinit();

        const manifest_text = try readFile(arena, io, &client, self.origin);
        const manifest = try eggy.plugin_manifest.parse(arena, try arena.dupeSentinel(u8, manifest_text, 0));
        // No read-me is fine: the window says so.
        const readme_at = try source.sibling(arena, self.origin, manifest.readme);
        const readme = readFile(arena, io, &client, readme_at) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const root = if (self.origin == .path) source.packageRoot(arena, io, self.origin.path) else null;
        return Fetched.create(self.gpa, self.origin, manifest_text, readme, root);
    }
};

/// The file at `origin`, in `arena`: `error.FileNotFound` when it isn't there (a 404, too).
fn readFile(arena: std.mem.Allocator, io: std.Io, client: *std.http.Client, origin: source.Origin) ![]const u8 {
    switch (origin) {
        .path => |path| return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file)),
        .url => |url| {
            var body: std.Io.Writer.Allocating = .init(arena);
            const result = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer });
            if (result.status == .not_found) return error.FileNotFound;
            if (result.status.class() != .success) return error.HttpError;
            if (body.written().len > max_file) return error.FileTooBig;
            return body.written();
        },
    }
}

/// What to tell someone when `err` stops a fetch.
fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "There is no eggy.zon there.",
        error.NotAPlugin => "That eggy.zon isn't a plugin's: it has no .plugin section.",
        error.ParseZon => "That eggy.zon's .plugin section is missing a field or has one it can't read: it needs .title, .module, .version, .repository and .fingerprint.",
        error.InvalidVersion => "The plugin's .version (or .minimum_eggy_version) isn't a semver version like 1.2.0.",
        error.InvalidModule => "The plugin's .module isn't a module name: use letters, digits and _.",
        error.InvalidRepository => "The plugin's .repository isn't an https address like https://github.com/me/plugin.",
        error.PackageOutsideRepository => "The plugin's .package isn't in the repository it names, so it can't be trusted.",
        error.NotFromRepository => "That eggy.zon is hosted outside the repository it names, so it can't be trusted.",
        error.HttpError => "The server didn't send the file.",
        error.FileTooBig => "The file is too big to be a plugin's eggy.zon or read-me.",
        error.UnknownHostName, error.ConnectionRefused, error.NetworkUnreachable, error.TlsInitializationFailed => "Couldn't reach the server. Check the address and your connection.",
        else => "Couldn't read the plugin: see the Console.",
    };
}

fn processEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => .{ .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) } },
    };
}

test "a plugin is read from a folder, without a read-me" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "pack/stats");
    try tmp.dir.writeFile(io, .{ .sub_path = "pack/build.zig.zon", .data = ".{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pack/stats/eggy.zon", .data = ".{ .plugin = .{ .title = \"Stats\", .module = \"stats\", .version = \"1.0.0\", .repository = \"https://github.com/me/pack\", .fingerprint = 7 } }" });
    const folder = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(folder);

    const fetch = try Fetch.start(std.testing.allocator, "pack/stats", folder);
    defer fetch.destroy();
    const outcome = while (true) {
        if (fetch.take()) |taken| break taken;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    };
    const fetched = outcome.fetched;
    defer fetched.destroy();
    try std.testing.expectEqualStrings("stats", fetched.manifest.module);
    try std.testing.expect(fetched.readme == null);
    try std.testing.expect(std.mem.endsWith(u8, fetched.package.fetch.url, "pack"));
}
