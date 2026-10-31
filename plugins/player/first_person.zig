//! A first-person player: WASD or the left stick walks, the mouse or right stick looks, and Shift
//! or the controller's west button sprints. Add `FirstPersonPlayer` to an entity and it makes its
//! own camera at eye height. This file is yours to change; keep it in `src/`, beside the game.
//!
//! List it in your game (`src/main.zig`), or in any plugin of yours:
//!
//!     const first_person = @import("First Person 3D Player Controller.zig"); // this file, by its name
//!
//!     pub const Game = struct {
//!         pub const components = .{first_person.FirstPersonPlayer};
//!         pub const input_maps = .{first_person.Controls};
//!
//!         pub fn update(self: *Game, app: *eggy.App) !void {
//!             try first_person.update(app);
//!         }
//!
//!         /// Playing stopped or paused: give the mouse back.
//!         pub fn editorUpdate(self: *Game, editor: *eggy.editor.Context) !void {
//!             try first_person.releaseMouse(editor.app);
//!         }
//!     };
const std = @import("std");
const eggy = @import("eggy");
const ecs = eggy.ecs;

pub const FirstPersonPlayer = struct {
    pub const dependencies = .{eggy.Transform};

    walk_speed_m_per_s: f32 = 4,
    sprint_speed_m_per_s: f32 = 8,
    /// How quickly walking speeds up and slows down; higher is snappier.
    acceleration_per_s: f32 = 12,
    mouse_sensitivity_deg_per_point: f32 = 0.1,
    stick_look_speed_deg_per_s: f32 = 150,
    /// How high the camera sits above the entity's origin (its feet).
    eye_height_m: f32 = 1.6,
    fov_deg: f32 = 75,
    min_pitch_deg: f32 = -89,
    max_pitch_deg: f32 = 89,
    /// The camera you look through, a child of this entity. Made at Play when empty.
    camera: eggy.EntityRef(eggy.Transform) = .{},
    /// Up is positive. Set by looking.
    pitch_deg: f32 = 0,
    /// Which way the body faces about the world's up. Set by looking.
    yaw_deg: f32 = 0,
    /// Ground velocity along world X and Z. Set by walking.
    velocity_m_per_s: eggy.math.Vec2 = .zero,
};

pub const Controls = eggy.input.Map(enum { move, look, look_stick, sprint }, .{
    .key = "first_person_player",
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

/// Run once per frame while playing: give new players a camera, then look and walk.
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

    var players = world.query(.{ *FirstPersonPlayer, *eggy.Transform });
    while (players.next()) |view| {
        const player = view.get(*FirstPersonPlayer);
        const body = view.get(*eggy.Transform);

        // Mapped vectors are right/down positive; the mouse is per frame, the stick per second.
        const turn_x_deg = mouse.x * player.mouse_sensitivity_deg_per_point + stick.x * player.stick_look_speed_deg_per_s * delta_s;
        const turn_y_deg = mouse.y * player.mouse_sensitivity_deg_per_point + stick.y * player.stick_look_speed_deg_per_s * delta_s;
        player.yaw_deg = @mod(player.yaw_deg - turn_x_deg, 360);
        player.pitch_deg = std.math.clamp(player.pitch_deg - turn_y_deg, player.min_pitch_deg, player.max_pitch_deg);

        // Walk along the ground the way the body faces, speeding up and slowing down smoothly.
        const yaw_rad = player.yaw_deg * std.math.rad_per_deg;
        const forward = eggy.math.Vec2.init(-@sin(yaw_rad), -@cos(yaw_rad));
        const right = eggy.math.Vec2.init(@cos(yaw_rad), -@sin(yaw_rad));
        const speed = if (sprinting) player.sprint_speed_m_per_s else player.walk_speed_m_per_s;
        const ahead = -move.y;
        const wanted = forward.scale(ahead).add(right.scale(move.x)).scale(speed);
        const blend = smoothing(player.acceleration_per_s, delta_s);
        player.velocity_m_per_s = player.velocity_m_per_s.lerp(wanted, blend);
        body.translate(.init(player.velocity_m_per_s.x * delta_s, 0, player.velocity_m_per_s.y * delta_s));

        // The body turns left and right; the camera, its child, tilts up and down.
        body.rotation_deg = .init(0, player.yaw_deg, 0);
        if (player.camera.get(world)) |camera| {
            camera.position = .init(0, player.eye_height_m, 0);
            camera.rotation_deg = .init(player.pitch_deg, 0, 0);
        }
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
    var players = world.query(.{*const FirstPersonPlayer});
    while (players.next()) |view| {
        if (view.get(*const FirstPersonPlayer).camera.get(world) == null) return view.entity;
    }
    return null;
}

fn addCamera(world: *ecs.World, entity: ecs.EntityId) !void {
    const settings = world.get(entity, FirstPersonPlayer).?.*;
    const camera = try world.spawn(.{
        eggy.Transform{ .position = .init(0, settings.eye_height_m, 0) },
        eggy.Camera{ .fov_deg = settings.fov_deg },
    });
    try world.setParent(camera, entity);
    world.get(entity, FirstPersonPlayer).?.camera = .init(camera);
}

/// The fraction of the way to close toward a target this frame, at `rate_per_s`, the same
/// whatever the frame rate.
fn smoothing(rate_per_s: f32, delta_s: f32) f32 {
    return 1 - @exp(-rate_per_s * delta_s);
}

test "a player without a camera gets one at eye height, as its child" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const body = try world.spawn(.{ eggy.Transform{}, FirstPersonPlayer{ .eye_height_m = 1.7 } });
    while (playerWithoutCamera(&world)) |entity| try addCamera(&world, entity);

    const camera = world.get(body, FirstPersonPlayer).?.camera.entity.?;
    try std.testing.expect(world.getParent(camera).?.eql(body));
    try std.testing.expectEqual(@as(f32, 1.7), world.get(camera, eggy.Transform).?.position.y);
    try std.testing.expect(playerWithoutCamera(&world) == null);
}
