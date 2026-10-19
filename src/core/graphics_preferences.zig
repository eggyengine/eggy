//! Atomic per-user graphics overrides, separate from game saves and shipped project defaults.
const std = @import("std");
const builtin = @import("builtin");
const render = @import("render_settings.zig");
const web = @import("web_storage.zig");
const identityHash = @import("storage.zig").identityHash;
const max_bytes = 16384;
const Envelope = struct { version: u32 = 1, settings: render.Settings };

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    scope: render.Scope,
    namespace: [64]u8,
    directory: ?std.Io.Dir = null,
    has_override: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, project_name: []const u8, scope: render.Scope) !Store {
        if (project_name.len == 0) return error.InvalidProjectId;
        var self = Store{ .gpa = gpa, .io = io, .scope = scope, .namespace = identityHash(if (scope == .editor) "eggy" else project_name) };
        if (comptime builtin.os.tag == .emscripten) {
            try web.checkAvailable();
        } else {
            const sdl = @import("vitellus_sdl3").sdl;
            const pref = try sdl.filesystem.getPrefPath("eggy", if (scope == .editor) "eggy" else "games");
            defer sdl.free(pref);
            const path = if (scope == .editor) try gpa.dupe(u8, pref) else try std.fs.path.join(gpa, &.{ pref, &self.namespace });
            defer gpa.free(path);
            self.directory = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
        }
        return self;
    }

    pub fn deinit(self: *Store) void {
        if (self.directory) |dir| dir.close(self.io);
    }

    /// Null means no override. Malformed/versioned/invalid preferences and I/O failures propagate.
    pub fn load(self: *Store) !?render.Settings {
        const bytes = self.read() catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer self.gpa.free(bytes);
        const source = try self.gpa.dupeZ(u8, bytes);
        defer self.gpa.free(source);
        const envelope = try std.zon.parse.fromSlice(Envelope, self.gpa, source, null, .{});
        if (envelope.version != 1) return error.UnsupportedGraphicsSettingsVersion;
        try envelope.settings.validateValues();
        self.has_override = true;
        return envelope.settings;
    }

    /// Validate before atomically replacing the complete override; failures preserve the old file.
    pub fn save(self: *Store, settings: render.Settings) !void {
        try settings.validateValues();
        var output: std.Io.Writer.Allocating = .init(self.gpa);
        defer output.deinit();
        try std.zon.stringify.serialize(Envelope{ .settings = settings }, .{}, &output.writer);
        if (comptime builtin.os.tag == .emscripten) {
            var key: [96]u8 = undefined;
            try web.write(try self.webKey(&key), output.written());
        } else {
            var atomic = try self.directory.?.createFileAtomic(self.io, self.fileName(), .{ .replace = true });
            defer atomic.deinit(self.io);
            var buffer: [4096]u8 = undefined;
            var writer = atomic.file.writer(self.io, &buffer);
            writer.interface.writeAll(output.written()) catch return writer.err.?;
            writer.interface.flush() catch return writer.err.?;
            try atomic.file.sync(self.io);
            try atomic.replace(self.io);
        }
        self.has_override = true;
    }

    fn read(self: *Store) ![]u8 {
        if (comptime builtin.os.tag == .emscripten) {
            var key: [96]u8 = undefined;
            return web.read(self.gpa, try self.webKey(&key), max_bytes);
        }
        return self.directory.?.readFileAlloc(self.io, self.fileName(), self.gpa, .limited(max_bytes));
    }

    fn fileName(self: *const Store) []const u8 {
        return if (self.scope == .editor) "graphics-editor.zon" else "graphics.zon";
    }

    fn webKey(self: *const Store, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "eggy.graphics.{s}.{s}", .{ @tagName(self.scope), self.namespace });
    }
};

test "graphics preferences roundtrip separately from saves and reject invalid replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store{ .gpa = std.testing.allocator, .io = std.testing.io, .scope = .runtime, .namespace = identityHash("test"), .directory = try tmp.dir.openDir(std.testing.io, ".", .{}) };
    defer store.deinit();
    try std.testing.expect(try store.load() == null);
    const settings = render.Settings{ .anti_aliasing = .fxaa, .frame_limit = 120, .anisotropy = 4 };
    try store.save(settings);
    try std.testing.expectEqualDeep(settings, (try store.load()).?);
    try std.testing.expectError(error.InvalidRenderScale, store.save(.{ .render_scale = 0 }));
    try std.testing.expectEqualDeep(settings, (try store.load()).?);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "graphics.zon", .data = ".{ .version = 2, .settings = .{} }" });
    try std.testing.expectError(error.UnsupportedGraphicsSettingsVersion, store.load());
}
