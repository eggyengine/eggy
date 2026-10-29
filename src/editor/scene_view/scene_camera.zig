//! The Scene panel's camera, which the editor looks through whatever the game's cameras do. It
//! circles a focus point, and is steered with the mouse or touchpad over the panel, telling
//! them apart by each scroll event:
//!
//! - right-drag looks around, and while it is held W, A, S, D fly, Q and E go down and up
//!   (Shift faster) and the wheel changes how fast; the host captures relative movement inside
//!   the rendered Scene for drags;
//! - Alt+left-drag orbits the focus point; middle-drag pans;
//! - the wheel zooms towards the focus point; F frames what is selected;
//! - on a touchpad, two-finger scroll orbits, Shift+scroll pans, Ctrl+scroll or pinch zooms;
//! - on a gamepad, the left stick flies, the right stick looks around (orbits with the right
//!   shoulder held), the right and left triggers go up and down, holding the left shoulder
//!   flies faster, and holding the D-pad up or down changes how fast.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const View = eggy.camera.View;

/// Degrees turned for each point the pointer moves.
const turn_per_point: f32 = 0.25;
/// Metres flown per second to begin with, how far the wheel or D-pad can take it, and how much
/// faster with Shift.
const default_fly_speed_m_per_s: f32 = 8;
const min_fly_speed_m_per_s: f32 = 0.1;
const max_fly_speed_m_per_s: f32 = 1000;
const fast: f32 = 3;
/// How much each wheel notch changes the fly speed, and how many times faster or slower it gets
/// each second the D-pad is held.
const fly_speed_step: f32 = 1.2;
const fly_speed_per_dpad_s: f32 = 2;
/// How long the fly speed stays shown over the panel after it changes.
const fly_speed_note_s: f32 = 1.5;
/// Degrees turned per second with a stick pushed all the way.
const stick_turn_deg_per_s: f32 = 120;
/// Stick deflection ignored, so a resting stick doesn't drift the camera.
const stick_dead_zone: f32 = 0.15;
/// How far each wheel step zooms, as a share of the distance.
const zoom_step: f32 = 0.12;
const min_distance: f32 = 0.5;
/// Pointer-equivalent points per SDL scroll unit, retaining fractional touchpad motion.
const scroll_points: f32 = 24;

/// Whether `wheel` came from a touchpad: SDL doesn't say, but wheels step whole notches on one
/// axis while two-finger scrolling moves fractionally and sideways.
// ponytail: high-resolution mouse wheels also scroll fractionally and orbit; read SDL's device
// kind if it ever reports one.
fn fromTouchpad(wheel: sdl3.events.MouseWheel) bool {
    return wheel.scroll_x != 0 or @round(wheel.scroll_y) != wheel.scroll_y;
}

pub const SceneCamera = struct {
    /// What it circles and zooms towards.
    focus: [3]f32 = .{ 0, 1, 0 },
    /// How fast W, A, S, D and the left stick fly, before Shift or the left shoulder.
    fly_speed_m_per_s: f32 = default_fly_speed_m_per_s,
    /// Seconds left showing the fly speed over the panel, since it last changed.
    fly_speed_note_s: f32 = 0,
    /// Turned about y (0 looks down -z) and up or down, in degrees.
    yaw_deg: f32 = 0,
    pitch_deg: f32 = -21,
    /// How far the eye is from the focus point.
    distance: f32 = 19,
    fov_deg: f32 = 60,
    /// The lens it shows through: its own is always perspective; through an orthographic game
    /// camera it takes that camera's, so panning moves what is under the pointer.
    projection: eggy.camera.Projection = .perspective,
    orthographic_height_m: f32 = 10,
    /// The drag steering it, from a press over the Scene panel until its button is let go.
    drag: ?Drag = null,
    /// Whether the pointer is over the Scene panel, for F.
    hovered: bool = false,
    /// A native pinch is captured only if it began over this panel, in this window.
    pinch: ?struct { window_id: ?sdl3.video.WindowId } = null,

    pub const Drag = enum { look, orbit, pan };

    /// Compute the editor camera's world-space eye/basis and degree FOV as an owned value.
    /// Uses focus/distance in scene metres; no world mutation or allocation.
    ///
    /// ```zig
    /// const camera = SceneCamera{};
    /// const view = camera.view();
    /// ```
    pub fn view(self: *const SceneCamera) View {
        return .{ .eye = self.eye(), .forward = self.forward(), .up = self.up(), .fov_deg = self.fov_deg, .far = std.math.inf(f32), .projection = self.projection, .orthographic_height_m = self.orthographic_height_m };
    }

    /// Steer by `event`, from window `scene`, the Scene panel's rect (in the event's window;
    /// null when it isn't there). Returns whether the camera used it.
    /// Desktop editor only: event coordinates and scene rect must use the same window points.
    /// Active drags can continue outside the panel; pinch updates require the captured window.
    /// Reads SDL modifier/mouse state, mutates navigation/pose, and clears captures on focus loss.
    ///
    /// ```zig
    /// const used = camera.handle(event, scene_rect); // SceneCamera, raw SDL event, optional rect.
    /// ```
    pub fn handle(self: *SceneCamera, event: sdl3.events.Event, scene: ?eggy.ui.Rect) bool {
        switch (event) {
            .mouse_button_down => |down| {
                const area = scene orelse return false;
                if (!area.contains(down.x, down.y)) return false;
                self.drag = switch (down.button) {
                    .right => .look,
                    .middle => .pan,
                    .left => if (sdl3.keyboard.getModState().altDown()) .orbit else return false,
                    else => return false,
                };
                return true;
            },
            .mouse_button_up => {
                const was_dragging = self.drag != null;
                self.drag = null;
                return was_dragging;
            },
            .mouse_motion => |motion| {
                self.hovered = if (scene) |area| area.contains(motion.x, motion.y) else false;
                const drag = self.drag orelse return false;
                switch (drag) {
                    .look => {
                        const eye_before = self.eye();
                        self.turn(motion.x_rel, motion.y_rel);
                        self.focus = add(eye_before, scale(self.forward(), self.distance));
                    },
                    .orbit => self.turn(motion.x_rel, motion.y_rel),
                    .pan => self.pan(motion.x_rel, motion.y_rel, if (scene) |area| area.h else 600),
                }
                return true;
            },
            .mouse_wheel => |wheel| {
                const area = scene orelse return false;
                if (!area.contains(wheel.x, wheel.y)) return false;
                self.scroll(wheel, area.h, sdl3.keyboard.getModState());
                return true;
            },
            .pinch_begin => |gesture| {
                const mouse = sdl3.mouse.getState();
                return self.beginPinch(scene, .{ .x = mouse[1], .y = mouse[2] }, gesture.window_id);
            },
            .pinch_update => |gesture| {
                const captured = self.pinch orelse return false;
                if (gesture.window_id != captured.window_id) return false;
                self.zoom(gesture.scale);
                return true;
            },
            .pinch_end => |gesture| {
                const captured = self.pinch orelse return false;
                if (gesture.window_id != captured.window_id) return false;
                self.pinch = null;
                return true;
            },
            .window_mouse_leave => {
                self.hovered = false;
                return false;
            },
            .window_focus_lost => {
                self.cancelNavigation();
                return false;
            },
            else => return false,
        }
    }

    /// Release captured camera input when the window loses focus.
    /// Desktop editor only: clears drag/pinch/hover state without changing camera pose or
    /// calling SDL to alter OS mouse capture.
    ///
    /// ```zig
    /// camera.cancelNavigation(); // Existing SceneCamera when leaving navigation mode.
    /// ```
    pub fn cancelNavigation(self: *SceneCamera) void {
        self.drag = null;
        self.pinch = null;
        self.hovered = false;
    }

    fn beginPinch(self: *SceneCamera, scene: ?eggy.ui.Rect, at: eggy.ui.Vec2, window_id: ?sdl3.video.WindowId) bool {
        if (self.drag != null) return false;
        const area = scene orelse return false;
        if (!area.contains(at.x, at.y)) return false;
        self.pinch = .{ .window_id = window_id };
        return true;
    }

    fn scroll(self: *SceneCamera, wheel: sdl3.events.MouseWheel, height: f32, modifiers: sdl3.keycode.KeyModifier) void {
        // While looking around, scrolling changes how fast the keys fly instead of moving.
        if (self.drag == .look) {
            const direction: f32 = if (wheel.direction == .flipped) -1 else 1;
            self.scaleFlySpeed(std.math.pow(f32, fly_speed_step, wheel.scroll_y * direction));
            return;
        }
        if (!fromTouchpad(wheel)) {
            self.distance = @max(min_distance, self.distance * std.math.pow(f32, 1 - zoom_step, wheel.scroll_y));
            return;
        }
        // Some backends also emit wheel events during a pinch; don't navigate twice.
        if (self.pinch != null) return;
        const direction: f32 = if (wheel.direction == .flipped) -1 else 1;
        const dx = wheel.scroll_x * direction * scroll_points;
        const dy = -wheel.scroll_y * direction * scroll_points;
        if (modifiers.controlDown()) {
            self.zoom(std.math.pow(f32, 1 - zoom_step, -wheel.scroll_y * direction));
        } else if (modifiers.shiftDown()) {
            self.pan(dx, dy, height);
        } else {
            self.turn(dx, dy);
        }
    }

    /// The fly speed shown over the panel, while it has just changed.
    pub fn flySpeedNote(self: *const SceneCamera) ?f32 {
        return if (self.fly_speed_note_s > 0) self.fly_speed_m_per_s else null;
    }

    fn scaleFlySpeed(self: *SceneCamera, factor: f32) void {
        if (!std.math.isFinite(factor) or factor <= 0) return;
        self.fly_speed_m_per_s = std.math.clamp(self.fly_speed_m_per_s * factor, min_fly_speed_m_per_s, max_fly_speed_m_per_s);
        self.fly_speed_note_s = fly_speed_note_s;
    }

    fn zoom(self: *SceneCamera, factor: f32) void {
        // Pinch begin/end may have no scale; only finite, positive updates move the camera.
        if (!std.math.isFinite(factor) or factor <= 0) return;
        self.distance = std.math.clamp(self.distance / factor, min_distance, std.math.floatMax(f32));
    }

    fn pan(self: *SceneCamera, dx: f32, dy: f32, height: f32) void {
        // Match the focus point's screen motion at any zoom level.
        const visible_height_m = if (self.projection == .orthographic) self.orthographic_height_m else 2 * self.distance * @tan(self.fov_deg * std.math.rad_per_deg / 2);
        const metres_per_point = visible_height_m / @max(1, height);
        self.focus = add(self.focus, add(scale(self.right(), -dx * metres_per_point), scale(self.up(), dy * metres_per_point)));
    }

    /// Fly by the keys held, over `seconds`, while looking around (right-drag).
    /// Desktop editor only: pass a finite nonnegative frame duration in seconds. Reads SDL
    /// keyboard state and translates focus at `fly_speed_m_per_s` (three times faster with
    /// Shift); only counts down the speed note without a look drag. Call once per frame, not
    /// once per key event.
    ///
    /// ```zig
    /// camera.fly(1.0 / 60.0); // Existing SceneCamera, one 60 Hz navigation frame.
    /// ```
    pub fn fly(self: *SceneCamera, seconds: f32) void {
        self.fly_speed_note_s = @max(0, self.fly_speed_note_s - seconds);
        if (self.drag != .look) return;
        const keys = sdl3.keyboard.getState();
        const held = struct {
            fn f(state: []const bool, code: sdl3.Scancode) f32 {
                const index: usize = @intCast(@backingInt(code));
                return if (index < state.len and state[index]) 1 else 0;
            }
        }.f;
        const ahead = held(keys, .w) - held(keys, .s);
        const across = held(keys, .d) - held(keys, .a);
        const rise = held(keys, .e) - held(keys, .q);
        if (ahead == 0 and across == 0 and rise == 0) return;
        const speed = self.fly_speed_m_per_s * seconds * (if (held(keys, .left_shift) + held(keys, .right_shift) > 0) fast else 1);
        const step = add(add(scale(self.forward(), ahead * speed), scale(self.right(), across * speed)), .{ 0, rise * speed, 0 });
        self.focus = add(self.focus, step);
    }

    /// Fly and look by a gamepad's sticks and triggers, over `seconds`.
    /// Desktop editor only: pass a finite nonnegative frame duration and the pad's raw state
    /// (sticks -1..1, right/down positive; triggers 0..1). Looking turns about the eye, as
    /// right-drag does, or about the focus point with the right shoulder held, as Alt+left-drag
    /// does; flying matches `fly`'s speeds, which the D-pad's up and down change. Call once per
    /// frame.
    ///
    /// ```zig
    /// camera.steer(pad, 1.0 / 60.0); // Existing SceneCamera, one connected gamepad's state.
    /// ```
    pub fn steer(self: *SceneCamera, pad: eggy.input.ControllerState, seconds: f32) void {
        const faster = @as(f32, @floatFromInt(@intFromBool(pad.buttons.contains(.up)))) - @as(f32, @floatFromInt(@intFromBool(pad.buttons.contains(.down))));
        if (faster != 0) self.scaleFlySpeed(std.math.pow(f32, fly_speed_per_dpad_s, faster * seconds));
        const look = deadZone(pad.right_stick);
        const travel = deadZone(pad.left_stick);
        const rise = pad.triggers[1] - pad.triggers[0];
        if (look[0] == 0 and look[1] == 0 and travel[0] == 0 and travel[1] == 0 and @abs(rise) < stick_dead_zone) return;

        // Turn about the eye (or orbit the focus point), then fly from where it now looks.
        const eye_before = self.eye();
        const points_per_s = stick_turn_deg_per_s / turn_per_point;
        self.turn(look[0] * points_per_s * seconds, look[1] * points_per_s * seconds);
        if (!pad.buttons.contains(.right_shoulder)) self.focus = add(eye_before, scale(self.forward(), self.distance));
        const speed = self.fly_speed_m_per_s * seconds * (if (pad.buttons.contains(.left_shoulder)) fast else 1);
        const step = add(add(scale(self.forward(), -travel[1] * speed), scale(self.right(), travel[0] * speed)), .{ 0, rise * speed, 0 });
        self.focus = add(self.focus, step);
    }

    /// Where it is and which way it looks, to tell when it moved.
    /// Editor-only: returns focus x/y/z in metres, yaw/pitch degrees, then distance metres.
    /// Does not include FOV or transient navigation state.
    ///
    /// ```zig
    /// const before = camera.pose(); // Existing SceneCamera, for change detection.
    /// ```
    pub fn pose(self: *const SceneCamera) [6]f32 {
        return .{ self.focus[0], self.focus[1], self.focus[2], self.yaw_deg, self.pitch_deg, self.distance };
    }

    /// Look from `from`'s eye the way it looks, keeping the distance to the focus point.
    /// Editor-only: requires a normalized forward vector; copies pose, ignores incoming up/
    /// roll and lens fields, and clamps pitch away from vertical. No world/camera entity write.
    ///
    /// ```zig
    /// camera.place(game_view); // Existing SceneCamera and copied eggy.camera.View.
    /// ```
    pub fn place(self: *SceneCamera, from: View) void {
        const f = from.forward;
        self.yaw_deg = @mod(std.math.atan2(-f[0], -f[2]) * std.math.deg_per_rad, 360);
        self.pitch_deg = std.math.clamp(std.math.asin(std.math.clamp(f[1], -1, 1)) * std.math.deg_per_rad, -89, 89);
        self.focus = add(from.eye, scale(self.forward(), self.distance));
    }

    /// Look at `centre` from far enough away to see `radius` around it.
    /// Editor-only: finite centre/radius use world metres; radius should be nonnegative.
    /// Preserves yaw/pitch/FOV, setting distance from the vertical FOV with a 0.5 metre minimum.
    ///
    /// ```zig
    /// camera.frame(.{ 0, 1, 0 }, 2); // Existing SceneCamera; frame a 2 m radius.
    /// ```
    pub fn frame(self: *SceneCamera, centre: [3]f32, radius: f32) void {
        self.focus = centre;
        self.distance = @max(min_distance, radius / @sin(self.fov_deg * std.math.rad_per_deg / 2));
    }

    fn turn(self: *SceneCamera, dx: f32, dy: f32) void {
        self.yaw_deg = @mod(self.yaw_deg - dx * turn_per_point, 360);
        self.pitch_deg = std.math.clamp(self.pitch_deg - dy * turn_per_point, -89, 89);
    }

    fn forward(self: *const SceneCamera) [3]f32 {
        const yaw = self.yaw_deg * std.math.rad_per_deg;
        const pitch = self.pitch_deg * std.math.rad_per_deg;
        return .{ -@sin(yaw) * @cos(pitch), @sin(pitch), -@cos(yaw) * @cos(pitch) };
    }

    fn right(self: *const SceneCamera) [3]f32 {
        return eggy.camera.normalize(eggy.camera.cross(self.forward(), .{ 0, 1, 0 }));
    }

    fn up(self: *const SceneCamera) [3]f32 {
        return eggy.camera.cross(self.right(), self.forward());
    }

    fn eye(self: *const SceneCamera) [3]f32 {
        return add(self.focus, scale(self.forward(), -self.distance));
    }
};

/// `stick` with its resting wobble removed, rescaled so just past the dead zone starts at 0.
pub fn deadZone(stick: [2]f32) [2]f32 {
    const length = @sqrt(stick[0] * stick[0] + stick[1] * stick[1]);
    if (length <= stick_dead_zone) return .{ 0, 0 };
    const kept = @min(1, (length - stick_dead_zone) / (1 - stick_dead_zone)) / length;
    return .{ stick[0] * kept, stick[1] * kept };
}

fn add(a: [3]f32, b: [3]f32) [3]f32 {
    return @as(@Vector(3, f32), a) + @as(@Vector(3, f32), b);
}

fn scale(v: [3]f32, by: f32) [3]f32 {
    return @as(@Vector(3, f32), v) * @as(@Vector(3, f32), @splat(by));
}

test "looking around turns about the eye, and orbiting about the focus point" {
    const area = eggy.ui.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    var camera = SceneCamera{};
    const eye_before = camera.eye();
    try std.testing.expect(camera.handle(press(.right), area));
    _ = camera.handle(move(40, 10), area);
    for (camera.eye(), eye_before) |now, before| try std.testing.expectApproxEqAbs(before, now, 0.001);
    try std.testing.expect(camera.handle(.{ .mouse_button_up = .{ .common = .{ .timestamp = 0 }, .button = .right, .down = false, .clicks = 1, .x = 0, .y = 0 } }, area));

    const focus_before = camera.focus;
    camera.drag = .orbit;
    _ = camera.handle(move(40, 10), area);
    try std.testing.expectEqualSlices(f32, &focus_before, &camera.focus);
}

test "a press outside the Scene panel doesn't steer it, and zoom stops short of the focus" {
    var camera = SceneCamera{};
    try std.testing.expect(!camera.handle(press(.right), .{ .x = 500, .y = 500, .w = 10, .h = 10 }));
    try std.testing.expect(camera.drag == null);
    for (0..100) |_| _ = camera.handle(.{ .mouse_wheel = .{ .common = .{ .timestamp = 0 }, .id = .{ .value = 0 }, .scroll_x = 0, .scroll_y = 1, .direction = .normal, .x = 1, .y = 1 } }, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try std.testing.expectEqual(min_distance, camera.distance);
}

test "whole one-axis notches are a mouse wheel; fractional or sideways scrolling is a touchpad" {
    try std.testing.expect(!fromTouchpad(scrollWheel(0, -2)));
    try std.testing.expect(fromTouchpad(scrollWheel(0, 0.5)));
    try std.testing.expect(fromTouchpad(scrollWheel(1, 0)));
}

test "fractional two-axis touchpad scrolling orbits without changing focus or zoom" {
    var camera = SceneCamera{ .pitch_deg = 0, .distance = 10 };
    const focus = camera.focus;
    camera.scroll(scrollWheel(0.25, 0.5), 600, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 358.5), camera.yaw_deg, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), camera.pitch_deg, 0.001);
    try std.testing.expectEqualSlices(f32, &focus, &camera.focus);
    try std.testing.expectEqual(@as(f32, 10), camera.distance);
}

test "Shift touchpad scrolling pans in screen space at the viewport scale" {
    var camera = SceneCamera{ .focus = .{ 0, 0, 0 }, .pitch_deg = 0, .distance = 10, .fov_deg = 90 };
    camera.scroll(scrollWheel(0.25, 0.5), 100, .{ .left_shift = true });
    for (camera.focus, [3]f32{ -1.2, -2.4, 0 }) |got, want| try std.testing.expectApproxEqAbs(want, got, 0.001);
    try std.testing.expectEqual(@as(f32, 0), camera.yaw_deg);
    try std.testing.expectEqual(@as(f32, 0), camera.pitch_deg);
    try std.testing.expectEqual(@as(f32, 10), camera.distance);
}

test "Ctrl touchpad scrolling zooms like a whole mouse-wheel notch" {
    var touchpad = SceneCamera{ .distance = 10 };
    var mouse = touchpad;
    touchpad.scroll(scrollWheel(0.5, 1), 600, .{ .right_control = true });
    mouse.scroll(scrollWheel(0, 1), 600, .{ .left_shift = true });
    try std.testing.expectApproxEqAbs(@as(f32, 8.8), touchpad.distance, 0.001);
    try std.testing.expectApproxEqAbs(mouse.distance, touchpad.distance, 0.001);
    try std.testing.expectEqualSlices(f32, &mouse.focus, &touchpad.focus);
    try std.testing.expectEqual(mouse.yaw_deg, touchpad.yaw_deg);
}

test "flipped touchpad scrolling is normalized and scrolling outside the Scene is ignored" {
    var camera = SceneCamera{ .pitch_deg = 0 };
    var wheel = scrollWheel(0.5, 0.5);
    wheel.direction = .flipped;
    camera.scroll(wheel, 600, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 3), camera.yaw_deg, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -3), camera.pitch_deg, 0.001);
    const before = camera.pose();
    try std.testing.expect(!camera.handle(.{ .mouse_wheel = wheel }, .{ .x = 100, .y = 100, .w = 400, .h = 300 }));
    try std.testing.expectEqualSlices(f32, &before, &camera.pose());
}

test "pinch requires a Scene start and only its originating window can update or end it" {
    const area = eggy.ui.Rect{ .x = 100, .y = 100, .w = 400, .h = 300 };
    var camera = SceneCamera{ .distance = 10 };
    try std.testing.expect(!camera.beginPinch(area, .{ .x = 10, .y = 10 }, 1));
    try std.testing.expect(!camera.beginPinch(null, .{ .x = 150, .y = 150 }, 1));
    try std.testing.expect(!camera.handle(.{ .pinch_update = .{ .common = .{ .timestamp = 0 }, .scale = 2, .window_id = 1 } }, area));
    try std.testing.expect(camera.beginPinch(area, .{ .x = 150, .y = 150 }, 1));
    try std.testing.expect(!camera.handle(.{ .pinch_update = .{ .common = .{ .timestamp = 0 }, .scale = 2, .window_id = 2 } }, area));
    try std.testing.expect(!camera.handle(.{ .pinch_end = .{ .common = .{ .timestamp = 0 }, .scale = 1, .window_id = 2 } }, area));
    try std.testing.expect(camera.pinch != null);
    try std.testing.expectEqual(@as(f32, 10), camera.distance);
    // A captured gesture continues outside the panel, without applying duplicate scroll.
    const before = camera.pose();
    camera.scroll(scrollWheel(1, 1), 600, .{});
    try std.testing.expectEqualSlices(f32, &before, &camera.pose());
    try std.testing.expect(camera.handle(.{ .pinch_update = .{ .common = .{ .timestamp = 0 }, .scale = 2, .window_id = 1 } }, null));
    try std.testing.expectEqual(@as(f32, 5), camera.distance);
    try std.testing.expect(camera.handle(.{ .pinch_update = .{ .common = .{ .timestamp = 0 }, .scale = 0.5, .window_id = 1 } }, null));
    try std.testing.expectEqual(@as(f32, 10), camera.distance);
    try std.testing.expect(camera.handle(.{ .pinch_end = .{ .common = .{ .timestamp = 0 }, .scale = 1, .window_id = 1 } }, null));
    try std.testing.expect(camera.pinch == null);
}

test "pinch clamps zoom, ignores invalid scales and releases capture on focus loss" {
    var camera = SceneCamera{ .distance = 10, .pinch = .{ .window_id = 1 }, .hovered = true };
    for ([_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32) }) |invalid| camera.zoom(invalid);
    try std.testing.expectEqual(@as(f32, 10), camera.distance);
    camera.zoom(100);
    try std.testing.expectEqual(min_distance, camera.distance);
    _ = camera.handle(.{ .window_focus_lost = .{ .common = .{ .timestamp = 0 }, .id = 1 } }, null);
    try std.testing.expect(camera.pinch == null);
    try std.testing.expect(!camera.hovered);
    try std.testing.expect(!camera.handle(.{ .pinch_update = .{ .common = .{ .timestamp = 0 }, .scale = 0.5, .window_id = 1 } }, null));
    try std.testing.expectEqual(min_distance, camera.distance);
}

test "a gamepad's left stick flies, its right stick looks about the eye, and rest is ignored" {
    var camera = SceneCamera{ .focus = .{ 0, 0, 0 }, .pitch_deg = 0, .distance = 10 };
    camera.steer(.{ .left_stick = .{ 0.1, -0.1 }, .right_stick = .{ -0.1, 0 } }, 1);
    try std.testing.expectEqualSlices(f32, &[6]f32{ 0, 0, 0, 0, 0, 10 }, &camera.pose());

    // Full forward for half a second flies 4 m down -z.
    camera.steer(.{ .left_stick = .{ 0, -1 } }, 0.5);
    for (camera.focus, [3]f32{ 0, 0, -4 }) |got, want| try std.testing.expectApproxEqAbs(want, got, 0.001);

    const eye_before = camera.eye();
    camera.steer(.{ .right_stick = .{ 1, 0 } }, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 300), camera.yaw_deg, 0.001);
    for (camera.eye(), eye_before) |now, before| try std.testing.expectApproxEqAbs(before, now, 0.001);

    // With the right shoulder held it orbits: the focus point stays put.
    const focus_before = camera.focus;
    var orbiting = eggy.input.ControllerState{ .right_stick = .{ 1, 0 } };
    orbiting.buttons.insert(.right_shoulder);
    camera.steer(orbiting, 0.5);
    try std.testing.expectEqualSlices(f32, &focus_before, &camera.focus);
}

test "scrolling while looking around changes the fly speed, not the view, and shows it briefly" {
    var camera = SceneCamera{ .drag = .look };
    const before = camera.pose();
    camera.scroll(scrollWheel(0, 2), 600, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 8 * 1.44), camera.fly_speed_m_per_s, 0.001);
    try std.testing.expectEqualSlices(f32, &before, &camera.pose());
    try std.testing.expect(camera.flySpeedNote() != null);
    camera.fly(2);
    try std.testing.expect(camera.flySpeedNote() == null);

    // Holding the D-pad down for a second halves it, and it never stops altogether.
    var pad = eggy.input.ControllerState{};
    pad.buttons.insert(.down);
    camera.steer(pad, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0 * 1.44 / 2.0), camera.fly_speed_m_per_s, 0.001);
    camera.steer(pad, 100);
    try std.testing.expectEqual(min_fly_speed_m_per_s, camera.fly_speed_m_per_s);
}

fn scrollWheel(x: f32, y: f32) sdl3.events.MouseWheel {
    return .{ .common = .{ .timestamp = 0 }, .scroll_x = x, .scroll_y = y, .direction = .normal, .x = 10, .y = 10 };
}

fn press(button: sdl3.mouse.Button) sdl3.events.Event {
    return .{ .mouse_button_down = .{ .common = .{ .timestamp = 0 }, .button = button, .down = true, .clicks = 1, .x = 10, .y = 10 } };
}

fn move(dx: f32, dy: f32) sdl3.events.Event {
    return .{ .mouse_motion = .{ .common = .{ .timestamp = 0 }, .state = .{ .left = false, .middle = false, .right = false, .side1 = false, .side2 = false }, .x = 10, .y = 10, .x_rel = dx, .y_rel = dy } };
}
