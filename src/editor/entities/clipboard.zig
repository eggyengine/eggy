//! An editor-owned entity-tree clipboard, independent of the loaded game library.
const std = @import("std");
const eggy = @import("eggy");
const ecs = eggy.ecs;

pub const Clipboard = struct {
    gpa: std.mem.Allocator,
    scene: ?eggy.scene.Scene = null,
    external_refs: []*eggy.scene.Scene.Field = &.{},

    pub fn deinit(self: *Clipboard) void {
        if (self.scene) |*scene| scene.deinit();
        self.scene = null;
        self.external_refs = &.{};
    }

    /// Replace the clipboard only after capturing the complete tree successfully.
    pub fn copy(self: *Clipboard, world: *ecs.World, access: eggy.scene.Access, entity: ecs.EntityId) !void {
        if (!world.isAlive(entity)) return error.DeadEntity;
        var captured = try @import("snapshot.zig").capture(self.gpa, world, access, &.{entity});
        errdefer captured.deinit();
        const arena = captured.arena.allocator();
        var external: std.ArrayList(*eggy.scene.Scene.Field) = .empty;
        for (captured.entities) |saved| for (saved.components) |component| {
            const info = for (access.types()) |info| {
                if (std.mem.eql(u8, component.type, info.name) and std.mem.eql(u8, component.owner, info.owner)) break info;
            } else unreachable;
            for (@constCast(component.fields), info.fields) |*field, metadata| {
                if (metadata.kind != .entity) continue;
                const source = try arena.dupeZ(u8, field.value);
                const target = (std.zon.parse.fromSlice(?ecs.EntityId, arena, source, null, .{}) catch continue) orelse continue;
                _ = target;
                try external.append(arena, field);
            }
        };
        self.deinit();
        self.scene = captured;
        self.external_refs = external.items;
    }

    /// A new world can reuse IDs for unrelated entities; retain only scene-local references.
    pub fn worldChanged(self: *Clipboard) void {
        for (self.external_refs) |field| field.value = "null";
        self.external_refs = &.{};
    }

    /// Paste a fresh tree, remapping its internal references; reject incomplete copies.
    pub fn paste(self: *const Clipboard, world: *ecs.World, access: eggy.scene.Access, parent: ?ecs.EntityId) !?ecs.EntityId {
        const scene = if (self.scene) |*scene| scene else return null;
        const made = try scene.instantiate(self.gpa, world, access, parent);
        defer self.gpa.free(made.entities);
        if (made.skipped != 0) {
            for (made.entities) |entity| world.despawn(entity);
            return error.IncompletePaste;
        }
        return if (made.entities.len != 0) made.entities[0] else null;
    }
};

test "clipboard survives deleting the source and remaps references on every paste" {
    const Link = struct { target: eggy.EntityRef(void) = .{} };
    const Registry = eggy.components.Registry(&.{Link}, &.{"game"});
    const access = eggy.scene.registryAccess(Registry);
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    var clipboard = Clipboard{ .gpa = gpa };
    defer clipboard.deinit();
    const root = try world.spawn(.{Link{}});
    const child = try world.spawn(.{});
    try world.setParent(child, root);
    world.get(root, Link).?.target = .{ .entity = child };
    try clipboard.copy(&world, access, root);
    world.despawnRecursive(root);
    const first = (try clipboard.paste(&world, access, null)).?;
    const second = (try clipboard.paste(&world, access, null)).?;
    var children = world.children(first);
    const copied_child = children.next().?;
    try std.testing.expectEqual(copied_child, world.get(first, Link).?.target.entity.?);
    try std.testing.expect(!first.eql(second));
    try std.testing.expect(!world.get(second, Link).?.target.entity.?.eql(copied_child));
}

test "clipboard clears external references when a replaced world can reuse their IDs" {
    const Link = struct { target: eggy.EntityRef(void) = .{} };
    const access = eggy.scene.registryAccess(eggy.components.Registry(&.{Link}, &.{"game"}));
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    var clipboard = Clipboard{ .gpa = gpa };
    defer clipboard.deinit();
    const outside = try world.spawn(.{});
    const root = try world.spawn(.{Link{ .target = .init(outside) }});
    try clipboard.copy(&world, access, root);
    const same_world = (try clipboard.paste(&world, access, null)).?;
    try std.testing.expectEqual(outside, world.get(same_world, Link).?.target.entity.?);
    clipboard.worldChanged();
    const next_world = (try clipboard.paste(&world, access, null)).?;
    try std.testing.expect(world.get(next_world, Link).?.target.entity == null);
}

test "a rejected nested-reference copy preserves the previous clipboard" {
    const Nested = struct { links: [1]eggy.EntityRef(void) = @splat(.{}) };
    const access = eggy.scene.registryAccess(eggy.components.Registry(&.{Nested}, &.{"game"}));
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    var clipboard = Clipboard{ .gpa = gpa };
    defer clipboard.deinit();
    const original = try world.spawn(.{});
    const unsupported = try world.spawn(.{Nested{ .links = .{.init(original)} }});
    try clipboard.copy(&world, access, original);
    try std.testing.expectError(error.NestedEntityReferencesUnsupported, clipboard.copy(&world, access, unsupported));
    try std.testing.expectEqual(original, clipboard.scene.?.sources[0]);
    try std.testing.expect(world.isAlive(original) and world.isAlive(unsupported));
}
