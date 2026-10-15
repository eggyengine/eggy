//! Which of the project's plugins are turned off, as its `eggy.plugins.registry_file` (`.eggy/
//! plugins.zon`) says; the runtime has that file baked in. The editor starts the game with these
//! off (see `HotGame.start`) and writes them back with the registry (`preferences.writeRegistry`).
const std = @import("std");
const eggy = @import("eggy");
const log = std.log.scoped(.plugins);

pub const PluginSwitches = struct {
    gpa: std.mem.Allocator,
    /// The keys of the plugins turned off, each owned.
    off_keys: std.ArrayList([]u8) = .empty,

    /// The switches as `project_dir`'s registry has them (every plugin on without one).
    pub fn load(gpa: std.mem.Allocator, project_dir: ?[]const u8) PluginSwitches {
        var self = PluginSwitches{ .gpa = gpa };
        const dir_path = project_dir orelse return self;
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return self;
        defer dir.close(io);
        const source = dir.readFileAllocOptions(io, eggy.plugins.registry_file, gpa, .limited(1 << 20), .of(u8), 0) catch return self;
        defer gpa.free(source);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const keys = eggy.plugins.parseOff(arena.allocator(), source) catch |err| {
            log.warn("{s} doesn't parse ({t}): every plugin is on", .{ eggy.plugins.registry_file, err });
            return self;
        };
        for (keys) |key| self.set(key, false) catch {};
        return self;
    }

    pub fn deinit(self: *PluginSwitches) void {
        for (self.off_keys.items) |key| self.gpa.free(key);
        self.off_keys.deinit(self.gpa);
    }

    /// The keys turned off, for `HotGame.start` and the registry.
    pub fn off(self: *const PluginSwitches) []const []const u8 {
        return self.off_keys.items;
    }

    pub fn isOn(self: *const PluginSwitches, key: []const u8) bool {
        return self.indexOf(key) == null;
    }

    /// Turn plugin `key` on or off. The caller saves it with the registry.
    pub fn set(self: *PluginSwitches, key: []const u8, on: bool) !void {
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
};

test "switches are read from the project's registry" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    try tmp.dir.createDirPath(std.testing.io, ".eggy");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = eggy.plugins.registry_file, .data = ".{ .plugins = .{ .{ .key = \"stats\", .on = false }, .{ .key = \"audio\" } } }" });

    var switches = PluginSwitches.load(gpa, dir);
    defer switches.deinit();
    try std.testing.expect(!switches.isOn("stats"));
    try std.testing.expect(switches.isOn("audio"));
    try switches.set("audio", false);
    try switches.set("audio", false); // already off: still once
    try switches.set("stats", true);
    try std.testing.expectEqual(@as(usize, 1), switches.off().len);
}
