//! The game's cameras as the Scene panel sees them: the view through an entity with a `Camera`
//! (as the runtime would look through it), the one the game looks through, and moving it with
//! the Scene panel's own camera controls (`steer`), which writes the entity's `Transform`.
const std = @import("std");
const eggy = @import("eggy");
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
const SceneCamera = @import("scene_camera.zig").SceneCamera;
const View = eggy.camera.View;

/// The camera the game looks through: the first entity with a `Camera`, and its view; null when
/// the scene has none.
/// Editor-only: queries library-local component types in slot order; missing library or
/// unreadable camera transforms also yield null. Returns copied view/entity values, not
/// pointers into component storage.
///
/// ```zig
/// const camera = find(game, app); // Loaded HotGame and its App pointer.
/// ```
pub fn find(game: *const HotGame, app: *eggy.App) ?struct { entity: eggy.ecs.EntityId, view: View } {
    const component = game.builtinComponent("Camera") orelse return null;
    for (app.world.slots.items, 0..) |slot, i| {
        if (!slot.alive) continue;
        const entity = eggy.ecs.EntityId.init(@intCast(i), slot.generation);
        if (!game.hasComponent(app, entity, component)) continue;
        return .{ .entity = entity, .view = viewOf(game, app, entity) orelse continue };
    }
    return null;
}

/// The view through `entity`'s `Camera`, placed by its transform (down its -z, its +y up), as
/// `eggy.camera.find` places one; null when it has no `Camera`.
/// Editor-only: also returns null for missing library/dead entity. Copies transform/lens
/// through the game ABI; unreadable lens fields retain View defaults. No ownership transfer.
///
/// ```zig
/// const view = viewOf(game, app, entity); // Existing HotGame/App and entity id.
/// ```
pub fn viewOf(game: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId) ?View {
    const component = game.builtinComponent("Camera") orelse return null;
    if (!game.hasComponent(app, entity, component)) return null;
    const placed = game.worldMatrix(app, entity) orelse return null;
    var view = View{
        .eye = .{ placed[3][0], placed[3][1], placed[3][2] },
        .forward = eggy.camera.normalize(.{ -placed[2][0], -placed[2][1], -placed[2][2] }),
        .up = eggy.camera.normalize(.{ placed[1][0], placed[1][1], placed[1][2] }),
    };
    // Its lens, field by field, where they read.
    for (game.component_types[component].fields, 0..) |field, index| {
        var buffer: [64]u8 = undefined;
        const value = parseNumber(game.readField(app, entity, component, index, &buffer) orelse continue) orelse continue;
        if (std.mem.eql(u8, field.name, "fov_deg")) view.fov_deg = value;
        if (std.mem.eql(u8, field.name, "near")) view.near = value;
        if (std.mem.eql(u8, field.name, "far")) view.far = value;
    }
    return view;
}

/// Put `entity` (a camera) where `camera` is, looking where it looks, through its `Transform`.
/// ponytail: the pose is written as the entity's own, so a camera inside a moved parent ends up off; turn it into the parent's space once cameras are parented.
/// Editor-only: caller supplies a live camera with Transform; writes position and Euler degrees
/// synchronously through current ABI field indices. Missing Transform/library, formatting
/// failure or rejected writes are silently ignored; undo tracking belongs to the host.
///
/// ```zig
/// steer(game, app, entity, &scene_camera); // Existing host game/App, camera entity and SceneCamera.
/// ```
pub fn steer(game: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, camera: *const SceneCamera) void {
    const component = game.builtinComponent("Transform") orelse return;
    const view = camera.view();
    var buffer: [160]u8 = undefined;
    // A camera looks down its -z: turning it by the scene camera's pitch about x, then its yaw
    // about y, points it the same way.
    const position = std.fmt.bufPrintZ(&buffer, ".{{ {d}, {d}, {d} }}", .{ view.eye[0], view.eye[1], view.eye[2] }) catch return;
    _ = game.writeField(app, entity, component, 0, position);
    const rotation = std.fmt.bufPrintZ(&buffer, ".{{ {d}, {d}, 0 }}", .{ camera.pitch_deg, camera.yaw_deg }) catch return;
    _ = game.writeField(app, entity, component, 1, rotation);
}

fn parseNumber(text: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, std.mem.trim(u8, text, " ")) catch null;
}

test "a camera turned by the scene camera's pitch and yaw looks where it looks" {
    var camera = SceneCamera{ .yaw_deg = 30, .pitch_deg = -20 };
    const transform = eggy.Transform{ .rotation_deg = .{ camera.pitch_deg, camera.yaw_deg, 0 } };
    const placed = transform.matrix().data;
    const forward = eggy.camera.normalize(.{ -placed[2][0], -placed[2][1], -placed[2][2] });
    const expected = camera.view().forward;
    for (forward, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 0.001);
    camera.place(.{ .eye = .{ 1, 2, 3 }, .forward = expected, .up = .{ 0, 1, 0 } });
    try std.testing.expectApproxEqAbs(@as(f32, 30), camera.yaw_deg, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -20), camera.pitch_deg, 0.01);
    for (camera.view().eye, [3]f32{ 1, 2, 3 }) |got, want| try std.testing.expectApproxEqAbs(want, got, 0.001);
}
