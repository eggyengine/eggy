//! The Scene panel's camera, which the editor looks through whatever the game's cameras do. It
//! circles a focus point, and is steered with the mouse over the panel:
//!
//! - right-drag looks around, and while it is held W, A, S, D fly, Q and E go down and up
//!   (Shift faster);
//! - Alt+left-drag orbits the focus point; middle-drag pans;
//! - the wheel zooms towards the focus point; F frames what is selected.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const View = eggy.camera.View;

/// Degrees turned for each point the pointer moves.
const turn_per_point: f32 = 0.25;
/// Metres flown per second, and how much faster with Shift.
const fly_speed: f32 = 8;
const fast: f32 = 3;
/// How far each wheel step zooms, as a share of the distance.
const zoom_step: f32 = 0.12;
const min_distance: f32 = 0.5;

pub const SceneCamera = struct {
    /// What it circles and zooms towards.
    focus: [3]f32 = .{ 0, 1, 0 },
    /// Turned about y (0 looks down -z) and up or down, in degrees.
    yaw_deg: f32 = 0,
    pitch_deg: f32 = -21,
    /// How far the eye is from the focus point.
    distance: f32 = 19,
    fov_deg: f32 = 60,
    /// The drag steering it, from a press over the Scene panel until its button is let go.
    drag: ?Drag = null,
    /// Whether the pointer is over the Scene panel, for F.
    hovered: bool = false,

    pub const Drag = enum { look, orbit, pan };

    pub fn view(self: *const SceneCamera) View {
        return .{ .eye = self.eye(), .forward = self.forward(), .up = self.up(), .fov_deg = self.fov_deg };
    }

    /// Steer by `event`, from window `scene`, the Scene panel's rect (in the event's window;
    /// null when it isn't there). Returns whether the camera used it.
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
                    .pan => {
                        // As far as the focus point moves on screen, whatever the zoom.
                        const height = if (scene) |area| area.h else 600;
                        const metres_per_point = 2 * self.distance * @tan(self.fov_deg * std.math.rad_per_deg / 2) / @max(1, height);
                        const shift = add(scale(self.right(), -motion.x_rel * metres_per_point), scale(self.up(), motion.y_rel * metres_per_point));
                        self.focus = add(self.focus, shift);
                    },
                }
                return true;
            },
            .mouse_wheel => |wheel| {
                const area = scene orelse return false;
                if (!area.contains(wheel.x, wheel.y)) return false;
                self.distance = @max(min_distance, self.distance * std.math.pow(f32, 1 - zoom_step, wheel.scroll_y));
                return true;
            },
            else => return false,
        }
    }

    /// Fly by the keys held, over `seconds`, while looking around (right-drag).
    pub fn fly(self: *SceneCamera, seconds: f32) void {
        if (self.drag != .look) return;
        const keys = sdl3.keyboard.getState();
        const held = struct {
            fn f(state: []const bool, code: sdl3.Scancode) f32 {
                const index: usize = @intCast(@intFromEnum(code));
                return if (index < state.len and state[index]) 1 else 0;
            }
        }.f;
        const ahead = held(keys, .w) - held(keys, .s);
        const across = held(keys, .d) - held(keys, .a);
        const rise = held(keys, .e) - held(keys, .q);
        if (ahead == 0 and across == 0 and rise == 0) return;
        const speed = fly_speed * seconds * (if (held(keys, .left_shift) + held(keys, .right_shift) > 0) fast else 1);
        const step = add(add(scale(self.forward(), ahead * speed), scale(self.right(), across * speed)), .{ 0, rise * speed, 0 });
        self.focus = add(self.focus, step);
    }

    /// Look at `centre` from far enough away to see `radius` around it.
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

fn press(button: sdl3.mouse.Button) sdl3.events.Event {
    return .{ .mouse_button_down = .{ .common = .{ .timestamp = 0 }, .button = button, .down = true, .clicks = 1, .x = 10, .y = 10 } };
}

fn move(dx: f32, dy: f32) sdl3.events.Event {
    return .{ .mouse_motion = .{ .common = .{ .timestamp = 0 }, .state = .{ .left = false, .middle = false, .right = false, .side1 = false, .side2 = false }, .x = 10, .y = 10, .x_rel = dx, .y_rel = dy } };
}
