//! Lossless-or-failing snapshots for destructive editor commands and their undo history.
const std = @import("std");
const eggy = @import("eggy");

/// Reject unreadable fields rather than treating a partial scene capture as a safe backup.
pub fn capture(gpa: std.mem.Allocator, world: *eggy.ecs.World, access: eggy.scene.Access, roots: ?[]const eggy.ecs.EntityId) !eggy.scene.Scene {
    var scene = try eggy.scene.Scene.capture(gpa, world, access, roots);
    errdefer scene.deinit();
    for (scene.entities) |entity| for (entity.components) |component| {
        const info = for (access.types()) |info| {
            if (std.mem.eql(u8, info.name, component.type) and std.mem.eql(u8, info.owner, component.owner)) break info;
        } else return error.IncompleteSceneCapture;
        // ponytail: the core snapshot's bounded field reader is retained; fail safely until it supports unbounded fields end to end.
        if (component.fields.len != info.fields.len) return error.IncompleteSceneCapture;
    };
    return scene;
}

test "editor snapshots refuse fields the scene format's bounded reader omitted" {
    const Large = struct { values: [eggy.components.max_field_bytes]u8 = @splat(1) };
    const Registry = eggy.components.Registry(&.{Large}, &.{"game"});
    var world = eggy.ecs.World.init(std.testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{Large{}});
    try std.testing.expectError(error.IncompleteSceneCapture, capture(std.testing.allocator, &world, eggy.scene.registryAccess(Registry), null));
}
