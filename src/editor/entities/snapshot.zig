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
        for (info.fields) |field| try validateReferenceField(field);
        // ponytail: the core snapshot's bounded field reader is retained; fail safely until it supports unbounded fields end to end.
        if (component.fields.len != info.fields.len) return error.IncompleteSceneCapture;
    };
    return scene;
}

/// The core scene remapper only understands top-level EntityRef fields.
pub fn validateReferenceField(field: eggy.components.Field) error{NestedEntityReferencesUnsupported}!void {
    if (field.kind == .entity) return;
    for (field.parts) |part| if (part.kind == .entity) return error.NestedEntityReferencesUnsupported;
}
