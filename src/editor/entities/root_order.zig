//! The order of the world's top-level entities, as the Hierarchy shows them and scenes save
//! them. Children keep their order in the world itself; entities with no parent have none there,
//! so the editor keeps it: new ones go last, gone ones drop out, and moves place them.
const std = @import("std");
const eggy = @import("eggy");
const ecs = eggy.ecs;

pub const RootOrder = struct {
    gpa: std.mem.Allocator,
    entities: std.ArrayList(ecs.EntityId) = .empty,

    pub fn deinit(self: *RootOrder) void {
        self.entities.deinit(self.gpa);
    }

    /// The top-level entities of `world` in order: those kept that are still alive and at the top
    /// level, then any new ones in id order (a scene loaded into an empty world, in its order).
    pub fn of(self: *RootOrder, world: *ecs.World) []const ecs.EntityId {
        // Drop the gone and the moved under a parent.
        var kept: usize = 0;
        for (self.entities.items) |entity| {
            if (!world.isAlive(entity) or world.getParent(entity) != null) continue;
            self.entities.items[kept] = entity;
            kept += 1;
        }
        self.entities.shrinkRetainingCapacity(kept);

        // Append the new.
        for (world.slots.items, 0..) |slot, index| {
            if (!slot.alive) continue;
            const entity = ecs.EntityId.init(@intCast(index), slot.generation);
            if (world.getParent(entity) != null or self.indexOf(entity) != null) continue;
            self.entities.append(self.gpa, entity) catch return self.entities.items;
        }
        return self.entities.items;
    }

    /// Put top-level `entity` at `index` (clamped: `maxInt(usize)` puts it last).
    pub fn place(self: *RootOrder, entity: ecs.EntityId, index: usize) !void {
        if (self.indexOf(entity)) |at| _ = self.entities.orderedRemove(at);
        try self.entities.insert(self.gpa, @min(index, self.entities.items.len), entity);
    }

    /// Where `entity` is in the order; null if it isn't at the top level.
    pub fn indexOf(self: *const RootOrder, entity: ecs.EntityId) ?usize {
        for (self.entities.items, 0..) |kept, index| if (kept.eql(entity)) return index;
        return null;
    }
};

test "new top-level entities go last, and placed ones stay put" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    var order = RootOrder{ .gpa = gpa };
    defer order.deinit();

    const a = try world.spawn(.{});
    const b = try world.spawn(.{});
    try std.testing.expectEqualSlices(ecs.EntityId, &.{ a, b }, order.of(&world));
    try order.place(b, 0);
    const c = try world.spawn(.{});
    try std.testing.expectEqualSlices(ecs.EntityId, &.{ b, a, c }, order.of(&world));

    // Gone, or moved under a parent: out of the order.
    world.despawn(b);
    try world.setParent(c, a);
    try std.testing.expectEqualSlices(ecs.EntityId, &.{a}, order.of(&world));
}
