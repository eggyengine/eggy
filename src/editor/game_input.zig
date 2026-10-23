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
    mouse_captured: bool = false,
    relative_mouse: bool = false,
    touches: std.AutoHashMapUnmanaged(TouchKey, void) = .empty,

    /// Clear editor viewport focus, captured contacts/buttons, gameplay input, and any UI
    /// layer interaction on focus loss/stop. Retains touch storage for reuse; emits no releases.
    ///
    /// ```zig
    /// // Host, when the Scene loses input ownership:
    /// state.cancel(app);
    /// ```
    pub fn cancel(self: *State, app: *eggy.App) void {
        self.touches.clearRetainingCapacity();
        self.* = .{ .touches = self.touches };
        app.input.cancel();
        if (app.ui_layer) |layer| layer.cancel();
    }
    /// Free captured-touch storage using the world's allocator used by `route`.
    /// Does not cancel app/UI input; call `cancel` first if the host is still running.
    ///
    /// ```zig
    /// state.cancel(app);
    /// state.deinit(app.world.allocator);
    /// ```
    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.touches.deinit(gpa);
    }
    /// Test whether a touch event's device/finger pair is captured by this viewport.
    /// Non-touch events return false; ownership lasts until up/cancel or `cancel`.
    ///
    /// ```zig
    /// // Host may route captured finger motion even outside the Scene.
    /// const captured = state.ownsTouch(event);
    /// _ = captured;
    /// ```
    pub fn ownsTouch(self: *const State, event: eggy.Event) bool {
        return self.touches.contains(touchKey(event) orelse return false);
    }

    /// Localize one window-space event for the viewport's UI, then gameplay if UI declined it.
    /// Pointer ownership survives leaving the viewport until its buttons are released.
    /// Editor-host only: pass a window-space event, Scene rectangle in logical points, and
    /// window width/height in points; it converts to viewport-local coordinates.
    /// The host decides which events belong here. `game` supplies `uiEvent(app,event) bool`
    /// and `event(app,event) void`; gameplay only receives declined input while `running`.
    /// While running, a left press the UI declined goes to the billboard button under it, seen
    /// through `view` (the game's camera), before gameplay.
    /// Relative mouse capture bypasses pointer UI so hidden movement cannot hover or consume it.
    /// Touch allocation and input-backend errors propagate; zero-sized viewports are ignored.
    ///
    /// ```zig
    /// // Host has already checked Scene focus/capture and event window ownership.
    /// try state.route(app, game, event, scene_rect, window_points, play_mode.running(), view);
    /// ```
    pub fn route(self: *State, app: *eggy.App, game: anytype, event: eggy.Event, viewport: eggy.ui.Rect, window_points: [2]f32, running: bool, view: ?eggy.camera.View) !void {
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
        if (at) |position| self.pointer_in_scene = self.mouse_captured or (position[0] >= 0 and position[1] >= 0 and position[0] < viewport.w and position[1] < viewport.h);
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
        const relative_pointer = self.relative_mouse and at != null and !eggy.game_ui.isTouchInput(local);
        const consumed = if (!relative_pointer) if (app.ui_layer) |layer| layer.handle(local, true) else false else false;
        if (!relative_pointer and (consumed or game.uiEvent(app, local) or (running and try pressBillboard(app, local, view, viewport)))) {
            app.input.suppress(local);
            return;
        }
        if (running) {
            try app.input.handle(local);
            game.event(app, local);
        } else app.input.suppress(local);
    }
};

/// Press the button of a billboard under a left click at viewport-local `local`, seen through
/// `view`. Returns whether one was pressed.
fn pressBillboard(app: *eggy.App, local: eggy.Event, view: ?eggy.camera.View, viewport: eggy.ui.Rect) !bool {
    const down = switch (local) {
        .mouse_button_down => |down| down,
        else => return false,
    };
    const seen_from = view orelse return false;
    if (down.button != .left or app.ui_scenes.billboard_count == 0) return false;
    return eggy.ui_scenes.billboards.press(&app.ui_scenes, app.resources(), seen_from, .{ viewport.w, viewport.h }, .{ down.x, down.y });
}

fn buttonBit(button: sdl.mouse.Button) u32 {
    const value = @intFromEnum(button);
    return if (value > 0 and value <= 32) @as(u32, 1) << @intCast(value - 1) else 0;
}

test "custom UI consumption withholds both gameplay polling and event hooks" {
    const Game = struct {
        consumed: bool = true,
        events: usize = 0,
        /// Test game UI hook; returns the fixture's consumption flag without reading app/event.
        ///
        /// ```zig
        /// var game = Game{};
        /// try std.testing.expect(game.uiEvent(&app, event)); // Test's app/event fixtures.
        /// ```
        pub fn uiEvent(self: *@This(), _: *eggy.App, _: eggy.Event) bool {
            return self.consumed;
        }
        /// Test gameplay hook; counts events that viewport routing did not consume.
        ///
        /// ```zig
        /// game.event(&app, event); // Test fixtures; increments game.events.
        /// ```
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
    try state.route(&app, &game, event, viewport, .{ 500, 300 }, true, null);
    try std.testing.expect(!app.input.held(.w));
    try std.testing.expectEqual(@as(usize, 0), game.events);
    game.consumed = false;
    try state.route(&app, &game, event, viewport, .{ 500, 300 }, true, null);
    try std.testing.expect(app.input.pressed(.w));
    try std.testing.expectEqual(@as(usize, 1), game.events);
    state.cancel(&app);
    try std.testing.expect(!app.input.held(.w) and !app.input.released(.w));
}

test "Scene touch ownership follows exact contacts outside the viewport and clears on cancel" {
    const Game = struct {
        /// Touch-routing fixture UI hook; always declines without accessing its arguments.
        ///
        /// ```zig
        /// try std.testing.expect(!game.uiEvent(&app, event)); // Test fixtures.
        /// ```
        pub fn uiEvent(_: *@This(), _: *eggy.App, _: eggy.Event) bool {
            return false;
        }
        /// Touch-routing fixture gameplay hook; deliberately ignores forwarded events.
        ///
        /// ```zig
        /// game.event(&app, event); // No observable effect in this fixture.
        /// ```
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
    try state.route(&app, &game, .{ .finger_down = finger }, .{ .x = 100, .y = 50, .w = 300, .h = 200 }, .{ 500, 300 }, true, null);
    try std.testing.expect(state.ownsTouch(.{ .finger_motion = finger }));
    var other = finger;
    other.finger_id.value = 3;
    try std.testing.expect(!state.ownsTouch(.{ .finger_motion = other }));
    state.cancel(&app);
    try std.testing.expect(!state.ownsTouch(.{ .finger_motion = finger }));
}

test "relative capture keeps tracking outside the viewport without hovering or consuming game UI" {
    const Game = struct {
        ui_events: usize = 0,
        events: usize = 0,
        pub fn uiEvent(self: *@This(), _: *eggy.App, _: eggy.Event) bool {
            self.ui_events += 1;
            return true;
        }
        pub fn event(self: *@This(), _: *eggy.App, _: eggy.Event) void {
            self.events += 1;
        }
    };
    var app: eggy.App = undefined;
    app.input = .{};
    app.ui_layer = null;
    var game = Game{};
    var state = State{ .focused = true, .mouse_captured = true, .relative_mouse = true };
    const motion = eggy.Event{ .mouse_motion = .{
        .common = .{ .timestamp = 0 },
        .state = .{ .left = false, .middle = false, .right = false, .side1 = false, .side2 = false },
        .x = 900,
        .y = 500,
        .x_rel = 400,
        .y_rel = -250,
    } };
    const viewport = eggy.ui.Rect{ .x = 100, .y = 50, .w = 300, .h = 200 };
    try state.route(&app, &game, motion, viewport, .{ 1200, 800 }, true, null);
    try state.route(&app, &game, motion, viewport, .{ 1200, 800 }, true, null);
    try std.testing.expectEqual([2]f32{ 800, -500 }, app.input.mouse_delta);
    try std.testing.expect(state.pointer_in_scene);
    try std.testing.expectEqual(@as(usize, 0), game.ui_events);
    try std.testing.expectEqual(@as(usize, 2), game.events);

    state.mouse_captured = false;
    state.relative_mouse = false;
    try state.route(&app, &game, motion, viewport, .{ 1200, 800 }, true, null);
    try std.testing.expect(!state.pointer_in_scene);
    try std.testing.expectEqual(@as(usize, 1), game.ui_events);
    try std.testing.expectEqual(@as(usize, 2), game.events);
}
