//! Scene instances created through the current world's registry and file provider.
const std = @import("std");
const ecs = @import("clutch");
const refs = @import("../refs.zig");
const scene = @import("../scene.zig");
const instances = @import("../scene_instances.zig");

/// A borrowed view of the current world. Do not retain it across world resets or hot reload.
pub const Scenes = struct {
    world: *ecs.World,
    instances: *instances.SceneInstances,
    files: ?instances.Files,
    access: ?scene.Access,

    pub const Options = struct { parent: ?ecs.EntityId = null };

    /// Create a scene-instance root and its immediate scene entities synchronously. Nested
    /// instances synchronize at the normal scene-sync point. Returns the root; the world owns
    /// it. Read/parse/allocation failures remove everything this call spawned.
    pub fn instantiate(self: Scenes, file: refs.AssetRef(.scene), options: Options) !ecs.EntityId {
        if (file.len == 0) return error.UnsetAsset;
        const files = self.files orelse return error.NoResourceProvider;
        const access = self.access orelse return error.NoSceneRegistry;
        if (options.parent) |parent| if (!self.world.isAlive(parent)) return error.InvalidEntity;
        return self.instances.create(files, self.world, access, file, options.parent);
    }
};

test "scene instantiation reports missing context rather than manufacturing a root" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    var made = instances.SceneInstances.init(std.testing.allocator);
    defer made.deinit();
    const scenes = Scenes{ .world = &world, .instances = &made, .files = null, .access = null };
    try std.testing.expectError(error.NoResourceProvider, scenes.instantiate(.init("level.scene.zon"), .{}));
}
