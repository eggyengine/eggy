//! An editor-owned entity-tree clipboard, independent of the loaded game library.
const std = @import("std");
const eggy = @import("eggy");
const ecs = eggy.ecs;

pub const Clipboard = struct {
    gpa: std.mem.Allocator,
    scene: ?eggy.scene.Scene = null,

    pub fn deinit(self: *Clipboard) void {
        if (self.scene) |*scene| scene.deinit();
        self.scene = null;
    }

    /// Replace the clipboard only after capturing the complete tree successfully.
    pub fn copy(self: *Clipboard, world: *ecs.World, access: eggy.scene.Access, entity: ecs.EntityId) !void {
        if (!world.isAlive(entity)) return error.DeadEntity;
        const captured = try eggy.scene.Scene.capture(self.gpa, world, access, &.{entity});
        self.deinit();
        self.scene = captured;
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
