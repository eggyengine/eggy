//! Editor-only hierarchy folds and inherited visibility, never serialized into game scenes.
const std = @import("std");
const eggy = @import("eggy");
const ecs = eggy.ecs;
const Row = @import("tree.zig").Row;

pub const ViewState = struct {
    gpa: std.mem.Allocator,
    collapsed: std.AutoHashMapUnmanaged(ecs.EntityId, void) = .empty,
    hidden: std.AutoHashMapUnmanaged(ecs.EntityId, void) = .empty,

    pub fn deinit(self: *ViewState) void {
        self.collapsed.deinit(self.gpa);
        self.hidden.deinit(self.gpa);
    }

    /// Forget view state whenever a new world is installed, even if IDs are reused.
    pub fn reset(self: *ViewState) void {
        self.collapsed.clearRetainingCapacity();
        self.hidden.clearRetainingCapacity();
    }

    pub fn prune(self: *ViewState, world: *ecs.World) void {
        inline for (.{ &self.collapsed, &self.hidden }) |map| {
            var it = map.keyIterator();
            while (it.next()) |entity| if (!world.isAlive(entity.*)) {
                _ = map.remove(entity.*);
            };
        }
    }

    pub fn toggleCollapse(self: *ViewState, entity: ecs.EntityId) !void {
        if (!self.collapsed.remove(entity)) try self.collapsed.put(self.gpa, entity, {});
    }

    pub fn setHidden(self: *ViewState, entity: ecs.EntityId, hidden: bool) !void {
        if (hidden) try self.hidden.put(self.gpa, entity, {}) else _ = self.hidden.remove(entity);
    }

    /// A hidden parent hides its whole subtree, including generated scene-instance children.
    pub fn isHidden(self: *const ViewState, world: *ecs.World, entity: ecs.EntityId) bool {
        var current: ?ecs.EntityId = entity;
        while (current) |at| {
            if (self.hidden.contains(at)) return true;
            current = world.getParent(at);
        }
        return false;
    }

    /// Search temporarily opens folds; it does not change the saved collapse state.
    pub fn rows(self: *const ViewState, arena: std.mem.Allocator, world: *ecs.World, all: []const Row, searching: bool) ![]const Row {
        var shown: std.ArrayList(Row) = .empty;
        var skip_below: ?usize = null;
        for (all) |original| {
            if (skip_below) |depth| {
                if (original.depth > depth) continue;
                skip_below = null;
            }
            var row = original;
            row.collapsed = !searching and self.collapsed.contains(row.entity);
            row.self_hidden = self.hidden.contains(row.entity);
            row.hidden = self.isHidden(world, row.entity);
            try shown.append(arena, row);
            if (row.collapsed) skip_below = row.depth;
        }
        return shown.items;
    }

    /// Compact the gathered meshes in place so hidden entities cannot be drawn or picked.
    pub fn visibleMeshes(self: *const ViewState, world: *ecs.World, meshes: []eggy.mesh.Drawable) []eggy.mesh.Drawable {
        var count: usize = 0;
        for (meshes) |mesh| {
            if (!world.isAlive(mesh.entity()) or self.isHidden(world, mesh.entity())) continue;
            meshes[count] = mesh;
            count += 1;
        }
        return meshes[0..count];
    }
};

test "folds do not hide meshes, visibility inherits, and dead generations are pruned" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    var state = ViewState{ .gpa = gpa };
    defer state.deinit();
    const parent = try world.spawn(.{});
    const child = try world.spawn(.{});
    try world.setParent(child, parent);
    const all = [_]Row{
        .{ .entity = parent, .name = "Root", .depth = 0, .has_parent = false, .has_children = true, .components = &.{} },
        .{ .entity = child, .name = "Child", .depth = 1, .has_parent = true, .components = &.{} },
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try state.toggleCollapse(parent);
    try std.testing.expectEqual(@as(usize, 1), (try state.rows(arena.allocator(), &world, &all, false)).len);
    try std.testing.expectEqual(@as(usize, 2), (try state.rows(arena.allocator(), &world, &all, true)).len);
    try std.testing.expect(!state.isHidden(&world, child));
    var meshes = [_]eggy.mesh.Drawable{.{
        .model = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } },
        .color = .{ 1, 1, 1, 1 },
        .shape = .cube,
        .entity_id = child.id,
        .entity_generation = child.generation,
    }};
    try std.testing.expectEqual(@as(usize, 1), state.visibleMeshes(&world, &meshes).len);
    try state.setHidden(parent, true);
    try std.testing.expect(state.isHidden(&world, child));
    try std.testing.expectEqual(@as(usize, 0), state.visibleMeshes(&world, &meshes).len);
    try state.setHidden(child, true);
    try state.setHidden(parent, false);
    try std.testing.expect(state.isHidden(&world, child));
    world.despawnRecursive(parent);
    state.prune(&world);
    try std.testing.expectEqual(@as(usize, 0), state.hidden.count());
    try std.testing.expectEqual(@as(usize, 0), state.collapsed.count());
    const replacement = try world.spawn(.{});
    try std.testing.expect(!state.isHidden(&world, replacement));
    try state.setHidden(replacement, true);
    state.reset();
    try std.testing.expect(!state.isHidden(&world, replacement));
}
