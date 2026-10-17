//! eggy_template_name: the game. Every hook is optional; see eggy's `plugins.zig` for the full list.
const std = @import("std");
const eggy = @import("eggy");

const PlayerInput = eggy.input.Map(enum { jump, move }, .{
    .key = "player",
    .controls = &.{
        .{ .control = .jump, .bindings = &.{ .{ .key = .space }, .{ .controller = .{ .button = .south } } } },
        .{ .control = .move, .kind = .vector, .bindings = &.{ .{ .keys_2d = .{} }, .{ .controller_stick = .{} } } },
    },
});

pub const Game = struct {
    pub const input_maps = .{PlayerInput};
    frames: u64 = 0,
    jumps: u64 = 0,

    /// Runs once per frame, before drawing.
    pub fn update(self: *Game, app: *eggy.App) !void {
        if (try app.input.map(PlayerInput).pressed(.jump)) self.jumps += 1;
        self.frames += 1;
    }

    /// Builds the game's HUD. Omit this hook to use only your own `draw` renderer.
    pub fn gameUi(self: *Game, app: *eggy.App, ui: *eggy.ui.Context) !void {
        _ = app;
        ui.label("Frames: {d}", .{self.frames});
        ui.label("Jump presses: {d}", .{self.jumps});
    }

    /// Adds to the editor's panel. Never called in the runtime.
    pub fn editorUi(self: *Game, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void {
        try self.gameUi(editor.app, ui);
    }
};
