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

test "editor snapshots refuse fields the scene format's bounded reader omitted" {
    const Large = struct { values: [eggy.components.max_field_bytes]u8 = @splat(1) };
    const Registry = eggy.components.Registry(&.{Large}, &.{"game"});
    var world = eggy.ecs.World.init(std.testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{Large{}});
    try std.testing.expectError(error.IncompleteSceneCapture, capture(std.testing.allocator, &world, eggy.scene.registryAccess(Registry), null));
}

test "editor snapshots reject entity references inside structs arrays optionals and unions" {
    const Ref = eggy.EntityRef(void);
    const StructRefs = struct { value: struct { target: Ref = .{} } = .{} };
    const ArrayRefs = struct { value: [2]Ref = @splat(.{}) };
    const OptionalRefs = struct { value: ?Ref = null };
    const UnionRefs = struct { value: union(enum) { none, target: Ref } = .none };
    inline for (.{ StructRefs, ArrayRefs, UnionRefs }) |Component| {
        const Registry = eggy.components.Registry(&.{Component}, &.{"game"});
        var world = eggy.ecs.World.init(std.testing.allocator);
        defer world.deinit();
        const entity = try world.spawn(.{Component{}});
        try std.testing.expectError(error.NestedEntityReferencesUnsupported, capture(std.testing.allocator, &world, eggy.scene.registryAccess(Registry), &.{entity}));
        try std.testing.expect(world.isAlive(entity));
    }
    const optional_fields = eggy.components.Registry(&.{OptionalRefs}, &.{"game"}).infos[0].fields;
    try std.testing.expectError(error.NestedEntityReferencesUnsupported, validateReferenceField(optional_fields[0]));
}
