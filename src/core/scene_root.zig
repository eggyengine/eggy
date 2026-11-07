//! The scene's root: one entity per scene carrying its settings (`PhysicsSettings` and whatever
//! else a scene sets as a whole), which the editor lists first in the Hierarchy under the scene's
//! name and keeps from being deleted, renamed or moved.
const std = @import("std");
const ecs = @import("clutch");
const components = @import("components.zig");
const scene = @import("scene.zig");
const PhysicsSettings = @import("physics.zig").PhysicsSettings;

pub const SceneRoot = struct {
    /// Marks it in the editor (nf-md-file_tree).
    pub const icon = "\u{f0645}";
    pub const category = "Scene";
    pub const dependencies = .{PhysicsSettings};

    /// Whether it is a 2D or a 3D scene, which its physics runs in.
    dimension: Dim = .three,
};

pub const Dim = @import("humpty").Dim;

/// Where `SceneRoot` is among `types`, if it is there.
///
/// ```zig
/// const index = typeIndex(access.types()) orelse return;
/// ```
pub fn typeIndex(types: []const components.Info) ?usize {
    for (types, 0..) |info, i| {
        if (std.mem.eql(u8, info.name, "SceneRoot") and std.mem.eql(u8, info.owner, "eggy")) return i;
    }
    return null;
}

/// The top-level entity of `world` with a `SceneRoot`, through `access`; null without one.
///
/// ```zig
/// if (scene_root.find(&world, access)) |root| select(root);
/// ```
pub fn find(world: *ecs.World, access: scene.Access) ?ecs.EntityId {
    const component = typeIndex(access.types()) orelse return null;
    for (world.slots.items, 0..) |slot, index| {
        if (!slot.alive) continue;
        const entity = ecs.EntityId.init(@intCast(index), slot.generation);
        if (world.getParent(entity) == null and access.has(world, entity, component)) return entity;
    }
    return null;
}

/// The scene root of `world`, spawned with its settings' defaults as a `dimension` scene when
/// it has none (a scene saved before roots existed, or a new one); null when `access` doesn't
/// know the component.
///
/// ```zig
/// _ = try scene_root.ensure(&world, access, .three); // After opening a scene.
/// ```
pub fn ensure(world: *ecs.World, access: scene.Access, dimension: Dim) !?ecs.EntityId {
    if (find(world, access)) |root| return root;
    const component = typeIndex(access.types()) orelse return null;
    const root = try world.spawn(.{});
    errdefer world.despawn(root);
    if (!access.add(world, root, component)) return error.NoSceneRoot;
    // Through the access, as the editor's world is the game library's.
    if (dimension != .three) {
        const field = for (access.types()[component].fields, 0..) |found, i| {
            if (std.mem.eql(u8, found.name, "dimension")) break i;
        } else return error.NoSceneRoot;
        if (!access.writeField(world, root, component, field, "." ++ @tagName(Dim.two))) return error.NoSceneRoot;
    }
    return root;
}

test "a world gets one scene root, with physics settings, however often it is ensured" {
    const gpa = std.testing.allocator;
    const access = scene.registryAccess(components.Registry(&.{ PhysicsSettings, SceneRoot }, &.{ "eggy", "eggy" }));
    var world = ecs.World.init(gpa);
    defer world.deinit();
    _ = try world.spawn(.{});

    const root = (try ensure(&world, access, .two)).?;
    try std.testing.expect((try ensure(&world, access, .three)).?.eql(root));
    try std.testing.expectEqual(Dim.two, world.get(root, SceneRoot).?.dimension);
    try std.testing.expect(world.get(root, PhysicsSettings) != null);
    try std.testing.expect(find(&world, access).?.eql(root));
}
