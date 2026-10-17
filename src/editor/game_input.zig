//! Game-viewport focus and UI/gameplay input ownership in the editor.
const eggy = @import("eggy");
const std = @import("std");
const sdl = eggy.sdl_adapter.sdl;

pub const State = struct {
    focused: bool = false,
    buttons: u32 = 0,

    pub fn cancel(self: *State, app: *eggy.App) void {
        self.* = .{};
        app.input.cancel();
        if (app.ui_layer) |layer| layer.cancel();
    }

    /// Forward one viewport-local event to UI, then gameplay only if UI declined it.
    /// Pointer ownership survives leaving the viewport until its buttons are released.
    pub fn route(self: *State, app: *eggy.App, game: anytype, event: eggy.Event, viewport: eggy.ui.Rect, running: bool) void {
        const local = eggy.game_ui.localEvent(event, viewport);
        switch (local) {
            .mouse_button_down => |button| {
                self.focused = true;
                self.buttons |= buttonBit(button.button);
            },
            .mouse_button_up => |button| self.buttons &= ~buttonBit(button.button),
            else => {},
        }
        const consumed = if (app.ui_layer) |layer| layer.handle(local, true) else false;
        if (consumed or game.uiEvent(app, local)) {
            app.input.suppress(local);
            return;
        }
        if (running) {
            app.input.handle(local);
            game.event(app, local);
        } else app.input.suppress(local);
    }
};

fn buttonBit(button: sdl.mouse.Button) u32 {
    const value = @intFromEnum(button);
    return if (value > 0 and value <= 32) @as(u32, 1) << @intCast(value - 1) else 0;
}

test "custom UI consumption withholds both gameplay polling and event hooks" {
    const Game = struct {
        consumed: bool = true,
        events: usize = 0,
        pub fn uiEvent(self: *@This(), _: *eggy.App, _: eggy.Event) bool {
            return self.consumed;
        }
        pub fn event(self: *@This(), _: *eggy.App, _: eggy.Event) void {
            self.events += 1;
        }
    };
    var app: eggy.App = undefined;
    app.input = .{};
    app.ui_layer = null;
    var game = Game{};
    var state = State{ .focused = true };
    const event = eggy.Event{ .key_down = .{ .common = undefined, .id = null, .scancode = .w, .key = .w, .mod = .{}, .raw = 0, .down = true, .repeat = false } };
    const viewport = eggy.ui.Rect{ .x = 100, .y = 50, .w = 300, .h = 200 };
    state.route(&app, &game, event, viewport, true);
    try std.testing.expect(!app.input.held(.w));
    try std.testing.expectEqual(@as(usize, 0), game.events);
    game.consumed = false;
    state.route(&app, &game, event, viewport, true);
    try std.testing.expect(app.input.pressed(.w));
    try std.testing.expectEqual(@as(usize, 1), game.events);
    state.cancel(&app);
    try std.testing.expect(!app.input.held(.w) and !app.input.released(.w));
}
