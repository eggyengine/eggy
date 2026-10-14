//! The sandbox game: the smallest game Eggy runs, and the example to copy for your own.
const std = @import("std");
const eggy = @import("eggy");

pub const Game = struct {
    frames: u64 = 0,

    pub fn update(self: *Game, app: *eggy.App) !void {
        _ = app;
        self.frames += 1;
    }

    pub fn editorUi(self: *Game, ui: *eggy.ui.Context) void {
        ui.label("Frames: {d}", .{self.frames});
    }
};
