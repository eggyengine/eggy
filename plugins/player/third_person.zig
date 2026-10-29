//! A third-person player: WASD or the left stick walks, the mouse or right stick orbits the camera,
//! and Shift or the controller's west button sprints. Add `ThirdPersonPlayer` to an entity (its
//! model as a child) and it makes its own camera over the shoulder; the body turns to face where
//! it walks. This file is yours to change; keep it in `src/`, beside the game.
//!
//! List it in your game (`src/main.zig`), or in any plugin of yours:
//!
//!     const third_person = @import("Third Person 3D Player Controller.zig"); // this file, by its name
//!
//!     pub const Game = struct {
//!         pub const components = .{third_person.ThirdPersonPlayer};
//!         pub const input_maps = .{third_person.Controls};
//!
//!         pub fn update(self: *Game, app: *eggy.App) !void {
//!             try third_person.update(app);
//!         }
//!
//!         /// Playing stopped or paused: give the mouse back.
//!         pub fn editorUpdate(self: *Game, editor: *eggy.editor.Context) !void {
//!             try third_person.releaseMouse(editor.app);
//!         }
//!     };
const std = @import("std");
const eggy = @import("eggy");
const ecs = eggy.ecs;

pub const ThirdPersonPlayer = struct {
    pub const dependencies = .{eggy.Transform};

    walk_speed_m_per_s: f32 = 4,
    sprint_speed_m_per_s: f32 = 8,
    /// How quickly walking speeds up and slows down; higher is snappier.
    acceleration_per_s: f32 = 12,
    /// How quickly the body turns to face where it walks; higher is snappier.
    turn_rate_per_s: f32 = 12,
    mouse_sensitivity_deg_per_point: f32 = 0.1,
    stick_look_speed_deg_per_s: f32 = 150,
    /// How high above the entity's origin (its feet) the camera orbits around.
    pivot_height_m: f32 = 1.6,
    /// How far behind the pivot the camera sits, and how far to the right of it.
    distance_m: f32 = 4,
    shoulder_offset_m: f32 = 0.5,
    fov_deg: f32 = 60,
    /// Keep the minimum above about -20 so the camera stays out of the ground.
    min_pitch_deg: f32 = -20,
    max_pitch_deg: f32 = 80,
    /// What the camera orbits, a child of this entity, and the camera on it. Made at Play.
    pivot: eggy.EntityRef(eggy.Transform) = .{},
    camera: eggy.EntityRef(eggy.Transform) = .{},
    /// Up is positive. Set by looking.
    pitch_deg: f32 = 0,
    /// Which way the camera faces about the world's up. Set by looking.
    yaw_deg: f32 = 0,
    /// Ground velocity along world X and Z. Set by walking.
    velocity_m_per_s: [2]f32 = .{ 0, 0 },
};

pub const Controls = eggy.input.Map(enum { move, look, look_stick, sprint }, .{
    .key = "third_person_player",
    .controls = &.{
        .{ .control = .move, .kind = .vector, .bindings = &.{
            .{ .keys_2d = .{} },
            .{ .controller_stick = .{ .stick = .left } },
        } },
        .{ .control = .look, .kind = .vector, .bindings = &.{
            .{ .mouse_delta = .{} },
        } },
        .{ .control = .look_stick, .kind = .vector, .bindings = &.{
            .{ .controller_stick = .{ .stick = .right } },
        } },
        .{ .control = .sprint, .bindings = &.{
            .{ .key = .left_shift },
            .{ .controller = .{ .button = .west } },
        } },
    },
});

/// Run once per frame while playing: give new players a pivot and camera, then look and walk.
pub fn update(app: *eggy.App) !void {
    const world = &app.world;
    // Spawning moves entities about, so it happens before the query below.
    while (playerWithoutCamera(world)) |entity| try addCamera(world, entity);

    // Click to capture the mouse (so the editor isn't trapped on Play); Escape lets it go.
    const window = app.window.window;
    const captured = eggy.sdl_adapter.sdl.mouse.getWindowRelativeMode(window);
    if (!captured and app.input.mousePressed(.left)) try setMouseCaptured(app, true);
    if (captured and app.input.pressed(.escape)) try releaseMouse(app);

    const controls = app.input.map(Controls);
    const move = try controls.vector(.move);
    const mouse = if (captured) try controls.vector(.look) else eggy.math.Vec2{ .x = 0, .y = 0 };
    const stick = try controls.vector(.look_stick);
    const sprinting = try controls.held(.sprint);
    const delta_s = app.time.delta_s;

    var players = world.query(.{ *ThirdPersonPlayer, *eggy.Transform });
    while (players.next()) |view| {
        const player = view.get(*ThirdPersonPlayer);
        const body = view.get(*eggy.Transform);

        // Mapped vectors are right/down positive; the mouse is per frame, the stick per second.
        const turn_x_deg = mouse.x * player.mouse_sensitivity_deg_per_point + stick.x * player.stick_look_speed_deg_per_s * delta_s;
        const turn_y_deg = mouse.y * player.mouse_sensitivity_deg_per_point + stick.y * player.stick_look_speed_deg_per_s * delta_s;
        player.yaw_deg = @mod(player.yaw_deg - turn_x_deg, 360);
        player.pitch_deg = std.math.clamp(player.pitch_deg - turn_y_deg, player.min_pitch_deg, player.max_pitch_deg);

        // Walk along the ground relative to the camera, speeding up and slowing down smoothly.
        const yaw_rad = player.yaw_deg * std.math.rad_per_deg;
        const forward = [2]f32{ -@sin(yaw_rad), -@cos(yaw_rad) };
        const right = [2]f32{ @cos(yaw_rad), -@sin(yaw_rad) };
        const speed = if (sprinting) player.sprint_speed_m_per_s else player.walk_speed_m_per_s;
        const ahead = -move.y;
        const wanted = [2]f32{
            (forward[0] * ahead + right[0] * move.x) * speed,
            (forward[1] * ahead + right[1] * move.x) * speed,
        };
        const blend = smoothing(player.acceleration_per_s, delta_s);
        for (&player.velocity_m_per_s, wanted) |*velocity, target| velocity.* += (target - velocity.*) * blend;
        body.translate(.{ player.velocity_m_per_s[0] * delta_s, 0, player.velocity_m_per_s[1] * delta_s });

        // The body turns, smoothly, toward where it walks.
        var body_yaw_deg = body.rotation_deg[1];
        if (move.x != 0 or move.y != 0) {
            const facing_deg = std.math.atan2(-wanted[0], -wanted[1]) * std.math.deg_per_rad;
            body_yaw_deg = @mod(body_yaw_deg + angleBetween(body_yaw_deg, facing_deg) * smoothing(player.turn_rate_per_s, delta_s), 360);
        }
        body.rotation_deg = .{ 0, body_yaw_deg, 0 };

        // The pivot is the body's child, so it undoes the body's turn to face where you look.
        if (player.pivot.get(world)) |pivot| {
            pivot.position = .{ 0, player.pivot_height_m, 0 };
            pivot.rotation_deg = .{ player.pitch_deg, player.yaw_deg - body_yaw_deg, 0 };
        }
        if (player.camera.get(world)) |camera| camera.position = .{ player.shoulder_offset_m, 0, player.distance_m };
    }
}

/// Frees the mouse again. Call it whenever the game stops running, from `editorUpdate`.
pub fn releaseMouse(app: *eggy.App) !void {
    if (eggy.sdl_adapter.sdl.mouse.getWindowRelativeMode(app.window.window)) try setMouseCaptured(app, false);
}

/// SDL's capture for mouse look: relative mode (hides the cursor, reports raw movement) and a
/// grab (keeps the pointer inside the window).
fn setMouseCaptured(app: *eggy.App, captured: bool) !void {
    const window = app.window.window;
    try window.setMouseGrab(captured);
    try eggy.sdl_adapter.sdl.mouse.setWindowRelativeMode(window, captured);
}

fn playerWithoutCamera(world: *ecs.World) ?ecs.EntityId {
    var players = world.query(.{*const ThirdPersonPlayer});
    while (players.next()) |view| {
        if (view.get(*const ThirdPersonPlayer).camera.get(world) == null) return view.entity;
    }
    return null;
}

/// A pivot under `entity`, and the camera on the pivot.
fn addCamera(world: *ecs.World, entity: ecs.EntityId) !void {
    const settings = world.get(entity, ThirdPersonPlayer).?.*;
    const pivot = try world.spawn(.{eggy.Transform{ .position = .{ 0, settings.pivot_height_m, 0 } }});
    try world.setParent(pivot, entity);
    const camera = try world.spawn(.{
        eggy.Transform{ .position = .{ settings.shoulder_offset_m, 0, settings.distance_m } },
        eggy.Camera{ .fov_deg = settings.fov_deg },
    });
    try world.setParent(camera, pivot);
    const player = world.get(entity, ThirdPersonPlayer).?;
    player.pivot = .init(pivot);
    player.camera = .init(camera);
}

/// The fraction of the way to close toward a target this frame, at `rate_per_s`, the same
/// whatever the frame rate.
fn smoothing(rate_per_s: f32, delta_s: f32) f32 {
    return 1 - @exp(-rate_per_s * delta_s);
}

/// The shortest turn from `from_deg` to `to_deg`, in -180..180.
fn angleBetween(from_deg: f32, to_deg: f32) f32 {
    return @mod(to_deg - from_deg + 540, 360) - 180;
}

test "a player gets a pivot at its height and a camera behind it on the pivot" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const body = try world.spawn(.{ eggy.Transform{}, ThirdPersonPlayer{ .distance_m = 5 } });
    while (playerWithoutCamera(&world)) |entity| try addCamera(&world, entity);

    const player = world.get(body, ThirdPersonPlayer).?;
    const pivot = player.pivot.entity.?;
    const camera = player.camera.entity.?;
    try std.testing.expect(world.getParent(pivot).?.eql(body));
    try std.testing.expect(world.getParent(camera).?.eql(pivot));
    try std.testing.expectEqual(@as(f32, 5), world.get(camera, eggy.Transform).?.position[2]);
}

test "the body turns the short way round" {
    try std.testing.expectEqual(@as(f32, -20), angleBetween(10, 350));
    try std.testing.expectEqual(@as(f32, 20), angleBetween(350, 10));
}
