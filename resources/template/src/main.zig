//! eggy_template_name: the game. Every hook is optional; see eggy's `plugins.zig` for the full list.
const std = @import("std");
const eggy = @import("eggy");

pub const Game = struct {
    frames: u64 = 0,

    /// Runs once per frame, before drawing.
    pub fn update(self: *Game, app: *eggy.App) !void {
        _ = app;
        self.frames += 1;
    }

    /// Builds the game's HUD. Omit this hook to use only your own `draw` renderer.
    pub fn gameUi(self: *Game, app: *eggy.App, ui: *eggy.ui.Context) !void {
        _ = app;
        ui.label("Frames: {d}", .{self.frames});
    }

    /// Adds to the editor's panel. Never called in the runtime.
    pub fn editorUi(self: *Game, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void {
        try self.gameUi(editor.app, ui);
    }
};
