//! Scene instances created through the current world's registry and file provider.
const std = @import("std");
const ecs = @import("clutch");
const refs = @import("../refs.zig");
const scene = @import("../scene.zig");
const instances = @import("../scene_instances.zig");
const Resources = @import("../resources/resources.zig").Resources;
const support = @import("../support.zig");
pub const streaming_support: support.Support = .not_implemented;

/// A borrowed view of the current world. Do not retain it across world resets or hot reload.
pub const Scenes = struct {
    world: *ecs.World,
    instances: *instances.SceneInstances,
    resources: Resources,
    access: ?scene.Access,

    pub const Options = struct { parent: ?ecs.EntityId = null };

    /// Create a scene-instance root and its immediate scene entities synchronously. Nested
    /// instances synchronize at the normal scene-sync point. Returns the root; the world owns
    /// it. Read/parse/allocation failures remove everything this call spawned.
    /// `options.parent`, when supplied, must be alive in this world. Requires a scene registry
    /// and resource provider; do not retain the returned ID across world resets.
    ///
    /// ```zig
    /// // In a game hook:
    /// const root = try app.scenes().instantiate(.init("resources/enemy.scene.zon"), .{});
    /// ```
    pub fn instantiate(self: Scenes, file: refs.AssetRef(.scene), options: Options) !ecs.EntityId {
        if (file.len == 0) return error.UnsetAsset;
        const access = self.access orelse return error.NoSceneRegistry;
        if (options.parent) |parent| if (!self.world.isAlive(parent)) return error.InvalidEntity;
        var resources = self.resources;
        return self.instances.create(resources.sceneFiles(), self.world, access, file, options.parent);
    }

    // ponytail: scenes instantiate synchronously, add streaming ownership and completion before exposing loaded handles.
    /// Reserved streaming API; always returns `NotImplemented` without creating entities.
    /// Use `instantiate` for supported synchronous loading.
    ///
    /// ```zig
    /// // With the current world's scenes view:
    /// try std.testing.expectError(error.NotImplemented,
    ///     scenes.stream(.init("resources/enemy.scene.zon"), .{}));
    /// ```
    pub fn stream(_: Scenes, file: refs.AssetRef(.scene), options: Options) support.Error!ecs.EntityId {
        return support.notImplemented(.{ file, options });
    }
    /// Reserved world-replacement API; always returns `NotImplemented`, leaving the world
    /// untouched. Instantiation does not implicitly replace the current scene.
    ///
    /// ```zig
    /// // With the current world's scenes view:
    /// try std.testing.expectError(error.NotImplemented,
    ///     scenes.replace(.init("resources/level.scene.zon")));
    /// ```
    pub fn replace(_: Scenes, file: refs.AssetRef(.scene)) support.Error!void {
        return support.notImplemented(file);
    }
};

test "scene instantiation reports missing context rather than manufacturing a root" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    var made = instances.SceneInstances.init(std.testing.allocator);
    defer made.deinit();
    const scenes = Scenes{ .world = &world, .instances = &made, .resources = .{}, .access = null };
    try std.testing.expectError(error.NoSceneRegistry, scenes.instantiate(.init("level.scene.zon"), .{}));
}
