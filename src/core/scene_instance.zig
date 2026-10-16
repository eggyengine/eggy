//! `SceneInstance`: an entity that stands for a whole scene file, as an instanced scene does in
//! Godot. The scene's entities are made under it, from the file, and they aren't saved with the
//! scene the instance is in, only the instance itself, so a change to the file shows wherever
//! it is instanced. A built-in component. The editor makes and remakes the entities
//! (`src/editor/scene_instances.zig`).
//!
//!     .{ .type = "SceneInstance", .owner = "eggy", .fields = .{ .scene = "resources/scene/rat.scene.zon" } }
// ponytail: the runtime doesn't load scenes yet, so instances are only made in the editor; make them where the runtime loads its scene, once it does.
const std = @import("std");
const components = @import("components.zig");
const AssetRef = @import("refs.zig").AssetRef;
const Transform = @import("transform.zig").Transform;

pub const SceneInstance = struct {
    /// Its entities go where its `Transform` puts them.
    pub const dependencies = .{Transform};

    /// The scene file made under it; none (no entities) when empty.
    scene: AssetRef(.scene) = .{},
};

/// Where `SceneInstance` is among `types`, if it is there.
pub fn typeIndex(types: []const components.Info) ?usize {
    for (types, 0..) |info, i| {
        if (std.mem.eql(u8, info.name, "SceneInstance") and std.mem.eql(u8, info.owner, "eggy")) return i;
    }
    return null;
}

test "the instance is found among a registry's types" {
    const Registry = components.Registry(&.{ Transform, SceneInstance }, &.{ "eggy", "eggy" });
    try std.testing.expectEqual(@as(?usize, 1), typeIndex(Registry.infos));
    try std.testing.expectEqual(@as(?usize, null), typeIndex(Registry.infos[0..1]));
}
