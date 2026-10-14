//! An example plugin: shows the window's pixel size in the editor. A plugin package exports a
//! module like this one, and a game lists it in `addGame`'s `plugins`.
const std = @import("std");
const eggy = @import("eggy");

pub const Plugin = struct {
    width_px: u32 = 0,
    height_px: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Plugin {
        _ = gpa;
        std.log.info("window info plugin started", .{});
        var self = Plugin{};
        try self.update(app);
        return self;
    }

    pub fn update(self: *Plugin, app: *eggy.App) !void {
        const width, const height = try app.window.window.getSizeInPixels();
        self.width_px = @intCast(width);
        self.height_px = @intCast(height);
    }

    pub fn editorUi(self: *Plugin, ui: *eggy.ui.Context) void {
        ui.muted("Window info plugin");
        ui.label("{d} x {d} px", .{ self.width_px, self.height_px });
    }
};
