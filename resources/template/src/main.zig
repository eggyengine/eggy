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
    /// Reads the registered PlayerInput map and updates game-owned counters; input errors
    /// propagate. The engine calls this only during running gameplay, not editing or pause.
    ///
    /// ```zig
    /// // Engine dispatch; game code normally implements rather than calls this hook.
    /// try game.update(app);
    /// ```
    pub fn update(self: *Game, app: *eggy.App) !void {
        if (try app.input.map(PlayerInput).pressed(.jump)) self.jumps += 1;
        self.frames += 1;
    }

    /// Builds the game's HUD. Omit this hook to use only your own `draw` renderer.
    /// `ui` is borrowed for this already-begun frame; do not store it, begin/end a second
    /// frame or render it yourself. Also runs during paused editor Play.
    ///
    /// ```zig
    /// // Engine UI dispatch with the current game's instance:
    /// try game.gameUi(app, ui);
    /// ```
    pub fn gameUi(self: *Game, app: *eggy.App, ui: *eggy.ui.Context) !void {
        _ = app;
        ui.theme = .dark;
        ui.label("Frames: {d}", .{self.frames});
        ui.label("Jump presses: {d}", .{self.jumps});
    }

    /// Adds to the editor's panel. Never called in the runtime.
    /// Borrows `editor` and `ui` for the hook, forwarding the HUD to the project Inspector.
    /// Its error union permits UI work to report failures to the Console.
    ///
    /// ```zig
    /// try game.editorUi(editor, ui); // Editor's Inspector dispatch.
    /// ```
    pub fn editorUi(self: *Game, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void {
        try self.gameUi(editor.app, ui);
    }
};
