//! The game's cameras as the Scene panel sees them: the view through an entity with a `Camera`
//! (as the runtime would look through it), the one the game looks through, and moving it with
//! the Scene panel's own camera controls (`steer`), which writes the entity's `Transform`.
const std = @import("std");
const eggy = @import("eggy");
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
const SceneCamera = @import("scene_camera.zig").SceneCamera;
const View = eggy.camera.View;

/// The camera the game looks through, chosen as `eggy.camera.Cameras.activeEntity` does: among
/// cameras that are `active` and valid, the highest `priority`, the lowest entity ID on a tie.
/// Null when the scene has none.
/// Editor-only: queries library-local component types in slot order (so the first tie wins);
/// missing library or unreadable camera transforms also yield null. Returns copied
/// view/entity values, not pointers into component storage.
///
/// ```zig
/// const camera = find(game, app); // Loaded HotGame and its App pointer.
/// ```
pub fn find(game: *const HotGame, app: *eggy.App) ?struct { entity: eggy.ecs.EntityId, view: View } {
    const component = game.builtinComponent("Camera") orelse return null;
    var best: ?struct { entity: eggy.ecs.EntityId, view: View, priority: i32 } = null;
    for (app.world.slots.items, 0..) |slot, i| {
        if (!slot.alive) continue;
        const entity = eggy.ecs.EntityId.init(@intCast(i), slot.generation);
        if (!game.hasComponent(app, entity, component)) continue;
        const lens = lensOf(game, app, entity, component) orelse continue;
        if (!lens.active) continue;
        if (best == null or lens.priority > best.?.priority) best = .{ .entity = entity, .view = lens.view, .priority = lens.priority };
    }
    const found = best orelse return null;
    return .{ .entity = found.entity, .view = found.view };
}

/// The view through `entity`'s `Camera`, placed by its transform (down its -z, its +y up), as
/// `eggy.camera.find` places one, whether or not it is the active camera; null when it has no
/// `Camera`, or its lens is invalid.
/// Editor-only: also returns null for missing library/dead entity. Copies transform/lens
/// through the game ABI. No ownership transfer.
///
/// ```zig
/// const view = viewOf(game, app, entity); // Existing HotGame/App and entity id.
/// ```
pub fn viewOf(game: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId) ?View {
    const component = game.builtinComponent("Camera") orelse return null;
    if (!game.hasComponent(app, entity, component)) return null;
    return (lensOf(game, app, entity, component) orelse return null).view;
}

const Lens = struct { view: View, active: bool, priority: i32 };

/// `entity`'s camera: its view (placed, with the lens read field by field) and its selection fields.
fn lensOf(game: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId, component: usize) ?Lens {
    const placed = game.worldMatrix(app, entity) orelse return null;
    var lens = Lens{
        .view = .{
            .eye = eggy.math.transformPoint4x4(f32, placed, .zero),
            .forward = eggy.math.transformDirection4x4(f32, placed, .forward).normalize(),
            .up = eggy.math.transformDirection4x4(f32, placed, .up).normalize(),
        },
        .active = true,
        .priority = 0,
    };
    for (game.component_types[component].fields, 0..) |field, index| {
        var buffer: [64]u8 = undefined;
        const text = std.mem.trim(u8, game.readField(app, entity, component, index, &buffer) orelse continue, " ");
        if (std.mem.eql(u8, field.name, "fov_deg")) lens.view.fov_deg = parseNumber(text) orelse continue;
        if (std.mem.eql(u8, field.name, "near")) lens.view.near = parseNumber(text) orelse continue;
        if (std.mem.eql(u8, field.name, "far")) lens.view.far = parseNumber(text) orelse continue;
        if (std.mem.eql(u8, field.name, "orthographic_height_m")) lens.view.orthographic_height_m = parseNumber(text) orelse continue;
        if (std.mem.eql(u8, field.name, "projection")) lens.view.projection = if (std.mem.eql(u8, text, ".orthographic")) .orthographic else .perspective;
        if (std.mem.eql(u8, field.name, "active")) lens.active = !std.mem.eql(u8, text, "false");
        if (std.mem.eql(u8, field.name, "priority")) lens.priority = std.fmt.parseInt(i32, text, 10) catch continue;
    }
    // The same checks as `eggy.camera.Camera.validate`, so the preview never shows what the runtime refuses.
    const camera = eggy.Camera{ .fov_deg = lens.view.fov_deg, .near = lens.view.near, .far = lens.view.far, .projection = lens.view.projection, .orthographic_height_m = lens.view.orthographic_height_m };
    camera.validate() catch return null;
    return lens;
}

/// Every entity with a valid `Camera`, in slot order, in `arena`, and which of them the game
/// looks through now (as `find` chooses), if any.
/// Editor-only: an entity whose lens is invalid is left out, as the runtime would refuse it.
pub fn list(arena: std.mem.Allocator, game: *const HotGame, app: *eggy.App) !struct { entities: []eggy.ecs.EntityId, current: ?usize } {
    const component = game.builtinComponent("Camera") orelse return .{ .entities = &.{}, .current = null };
    const current = find(game, app);
    var found: std.ArrayList(eggy.ecs.EntityId) = .empty;
    var current_index: ?usize = null;
    for (app.world.slots.items, 0..) |slot, i| {
        if (!slot.alive) continue;
        const entity = eggy.ecs.EntityId.init(@intCast(i), slot.generation);
        if (!game.hasComponent(app, entity, component) or lensOf(game, app, entity, component) == null) continue;
        if (current != null and current.?.entity.eql(entity)) current_index = found.items.len;
        try found.append(arena, entity);
    }
    return .{ .entities = found.items, .current = current_index };
}

/// Make `entity`'s camera the only active one, so the game looks through it, by writing every
/// camera's `active` field. Editor-only: writes go straight into the world; undo is the host's.
pub fn makeOnlyActive(game: *const HotGame, app: *eggy.App, entity: eggy.ecs.EntityId) void {
    const component = game.builtinComponent("Camera") orelse return;
    const active_field = for (game.component_types[component].fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, "active")) break index;
    } else return;
    for (app.world.slots.items, 0..) |slot, i| {
        if (!slot.alive) continue;
        const camera = eggy.ecs.EntityId.init(@intCast(i), slot.generation);
        if (!game.hasComponent(app, camera, component)) continue;
        _ = game.writeField(app, camera, component, active_field, if (camera.eql(entity)) "true" else "false");
    }
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
    const position = std.fmt.bufPrintSentinel(&buffer, ".{{ {d}, {d}, {d} }}", .{ view.eye.x, view.eye.y, view.eye.z }, 0) catch return;
    _ = game.writeField(app, entity, component, 0, position);
    const rotation = std.fmt.bufPrintSentinel(&buffer, ".{{ {d}, {d}, 0 }}", .{ camera.pitch_deg, camera.yaw_deg }, 0) catch return;
    _ = game.writeField(app, entity, component, 1, rotation);
}

fn parseNumber(text: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, std.mem.trim(u8, text, " ")) catch null;
}

test "a camera turned by the scene camera's pitch and yaw looks where it looks" {
    var camera = SceneCamera{ .yaw_deg = 30, .pitch_deg = -20 };
    const transform = eggy.Transform{ .rotation_deg = .init(camera.pitch_deg, camera.yaw_deg, 0) };
    const expected = camera.view().forward;
    try std.testing.expect(transform.forward().approxEql(expected, 0.001));
    camera.place(.{ .eye = .init(1, 2, 3), .forward = expected, .up = .up });
    try std.testing.expectApproxEqAbs(@as(f32, 30), camera.yaw_deg, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -20), camera.pitch_deg, 0.01);
    try std.testing.expect(camera.view().eye.approxEql(.init(1, 2, 3), 0.001));
}
