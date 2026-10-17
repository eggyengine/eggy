//! Game-viewport focus and UI/gameplay input ownership in the editor.
const eggy = @import("eggy");
const std = @import("std");
const sdl = eggy.sdl_adapter.sdl;
const TouchKey = struct { device: u64, finger: u64 };

fn touchKey(event: eggy.Event) ?TouchKey {
    return switch (event) {
        .finger_down, .finger_motion, .finger_up, .finger_canceled => |finger| .{ .device = @bitCast(finger.id.value), .finger = @bitCast(finger.finger_id.value) },
        else => null,
    };
}

pub const State = struct {
    focused: bool = false,
    buttons: u32 = 0,
    pointer_in_scene: bool = false,
    touches: std.AutoHashMapUnmanaged(TouchKey, void) = .empty,

    pub fn cancel(self: *State, app: *eggy.App) void {
        self.touches.clearRetainingCapacity();
        self.* = .{ .touches = self.touches };
        app.input.cancel();
        if (app.ui_layer) |layer| layer.cancel();
    }
    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.touches.deinit(gpa);
    }
    pub fn ownsTouch(self: *const State, event: eggy.Event) bool {
        return self.touches.contains(touchKey(event) orelse return false);
    }

    /// Forward one viewport-local event to UI, then gameplay only if UI declined it.
    /// Pointer ownership survives leaving the viewport until its buttons are released.
    pub fn route(self: *State, app: *eggy.App, game: anytype, event: eggy.Event, viewport: eggy.ui.Rect, window_points: [2]f32, running: bool) !void {
        if (eggy.game_ui.syntheticTouchMouse(event)) return;
        if (viewport.w <= 0 or viewport.h <= 0) return;
        const local = eggy.game_ui.localEvent(event, viewport, window_points);
        app.input.viewport_points = .{ viewport.w, viewport.h };
        const at: ?[2]f32 = switch (local) {
            .mouse_motion => |e| .{ e.x, e.y },
            .mouse_button_down, .mouse_button_up => |e| .{ e.x, e.y },
            .mouse_wheel => |e| .{ e.x, e.y },
            .finger_down, .finger_motion, .finger_up, .finger_canceled => |finger| .{ finger.x * viewport.w, finger.y * viewport.h },
            else => null,
        };
        if (at) |position| self.pointer_in_scene = position[0] >= 0 and position[1] >= 0 and position[0] < viewport.w and position[1] < viewport.h;
        switch (local) {
            .mouse_button_down => |button| {
                self.focused = true;
                self.buttons |= buttonBit(button.button);
            },
            .mouse_button_up => |button| self.buttons &= ~buttonBit(button.button),
            .finger_down => {
                self.focused = true;
                try self.touches.put(app.world.allocator, touchKey(local).?, {});
            },
            .finger_up, .finger_canceled => _ = self.touches.remove(touchKey(local).?),
            else => {},
        }
        const consumed = if (app.ui_layer) |layer| layer.handle(local, true) else false;
        if (consumed or game.uiEvent(app, local)) {
            app.input.suppress(local);
            return;
        }
        if (running) {
            try app.input.handle(local);
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
    try state.route(&app, &game, event, viewport, .{ 500, 300 }, true);
    try std.testing.expect(!app.input.held(.w));
    try std.testing.expectEqual(@as(usize, 0), game.events);
    game.consumed = false;
    try state.route(&app, &game, event, viewport, .{ 500, 300 }, true);
    try std.testing.expect(app.input.pressed(.w));
    try std.testing.expectEqual(@as(usize, 1), game.events);
    state.cancel(&app);
    try std.testing.expect(!app.input.held(.w) and !app.input.released(.w));
}

test "Scene touch ownership follows exact contacts outside the viewport and clears on cancel" {
    const Game = struct {
        pub fn uiEvent(_: *@This(), _: *eggy.App, _: eggy.Event) bool {
            return false;
        }
        pub fn event(_: *@This(), _: *eggy.App, _: eggy.Event) void {}
    };
    const gpa = std.testing.allocator;
    var app: eggy.App = undefined;
    app.world = .init(gpa);
    defer app.world.deinit();
    app.ui_layer = null;
    app.input = .{};
    var game = Game{};
    var state = State{};
    defer state.deinit(gpa);
    const finger = sdl.events.TouchFinger{ .common = undefined, .id = .{ .value = 1 }, .finger_id = .{ .value = 2 }, .x = 0.5, .y = 0.5, .dx = 0, .dy = 0, .pressure = 1 };
    try state.route(&app, &game, .{ .finger_down = finger }, .{ .x = 100, .y = 50, .w = 300, .h = 200 }, .{ 500, 300 }, true);
    try std.testing.expect(state.ownsTouch(.{ .finger_motion = finger }));
    var other = finger;
    other.finger_id.value = 3;
    try std.testing.expect(!state.ownsTouch(.{ .finger_motion = other }));
    state.cancel(&app);
    try std.testing.expect(!state.ownsTouch(.{ .finger_motion = finger }));
}
