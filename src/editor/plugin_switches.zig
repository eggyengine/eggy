//! Which of the project's plugins are turned off, kept in its `eggy.plugins.off_file`, which the
//! runtime has baked in. The editor starts the game with these off (see `HotGame.start`).
const std = @import("std");
const eggy = @import("eggy");
const log = std.log.scoped(.plugins);

pub const PluginSwitches = struct {
    gpa: std.mem.Allocator,
    /// The project's folder; null without a project, where nothing can be turned off.
    project_dir: ?[]const u8,
    /// The keys of the plugins turned off, each owned.
    off_keys: std.ArrayList([]u8) = .empty,

    /// The switches as `project_dir`'s off file has them (none without one).
    pub fn load(gpa: std.mem.Allocator, project_dir: ?[]const u8) PluginSwitches {
        var self = PluginSwitches{ .gpa = gpa, .project_dir = project_dir };
        const dir_path = project_dir orelse return self;
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return self;
        defer dir.close(io);
        const source = dir.readFileAllocOptions(io, eggy.plugins.off_file, gpa, .limited(1 << 20), .of(u8), 0) catch return self;
        defer gpa.free(source);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const keys = eggy.plugins.parseOff(arena.allocator(), source) catch |err| {
            log.warn("{s} doesn't parse ({t}): every plugin is on", .{ eggy.plugins.off_file, err });
            return self;
        };
        for (keys) |key| self.setOn(key, false) catch {};
        return self;
    }

    pub fn deinit(self: *PluginSwitches) void {
        for (self.off_keys.items) |key| self.gpa.free(key);
        self.off_keys.deinit(self.gpa);
    }

    /// The keys turned off, for `HotGame.start`.
    pub fn off(self: *const PluginSwitches) []const []const u8 {
        return self.off_keys.items;
    }

    pub fn isOn(self: *const PluginSwitches, key: []const u8) bool {
        return self.indexOf(key) == null;
    }

    /// Turn plugin `key` on or off, and save the project's off file.
    pub fn set(self: *PluginSwitches, key: []const u8, on: bool) !void {
        try self.setOn(key, on);
        try self.save();
    }

    fn setOn(self: *PluginSwitches, key: []const u8, on: bool) !void {
        if (self.indexOf(key)) |index| {
            if (on) self.gpa.free(self.off_keys.orderedRemove(index));
        } else if (!on) {
            const copy = try self.gpa.dupe(u8, key);
            errdefer self.gpa.free(copy);
            try self.off_keys.append(self.gpa, copy);
        }
    }

    fn indexOf(self: *const PluginSwitches, key: []const u8) ?usize {
        for (self.off_keys.items, 0..) |off_key, index| if (std.mem.eql(u8, off_key, key)) return index;
        return null;
    }

    /// Write the off file; with every plugin on, delete it, so a project that never turned one off
    /// has none.
    fn save(self: *const PluginSwitches) !void {
        const dir_path = self.project_dir orelse return error.NoProject;
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);
        if (self.off_keys.items.len == 0) {
            dir.deleteFile(io, eggy.plugins.off_file) catch |err| if (err != error.FileNotFound) return err;
            return;
        }
        var text: std.Io.Writer.Allocating = .init(self.gpa);
        defer text.deinit();
        try text.writer.writeAll("// The plugins this project turns off, which the Eggy editor keeps (Preferences > Plugins).\n");
        try std.zon.stringify.serialize(eggy.plugins.OffList{ .off = self.off() }, .{}, &text.writer);
        try text.writer.writeByte('\n');
        if (std.fs.path.dirname(eggy.plugins.off_file)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = eggy.plugins.off_file, .data = text.written() });
    }
};

test "switches are saved to the project and read back" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);

    var switches = PluginSwitches.load(gpa, dir);
    defer switches.deinit();
    try std.testing.expect(switches.isOn("stats"));
    try switches.set("stats", false);
    try switches.set("stats", false); // already off: still once
    try std.testing.expectEqual(@as(usize, 1), switches.off().len);

    var reread = PluginSwitches.load(gpa, dir);
    defer reread.deinit();
    try std.testing.expect(!reread.isOn("stats"));
    try reread.set("stats", true);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, eggy.plugins.off_file, .{}));
}
