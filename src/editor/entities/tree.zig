//! The world's entities as the Hierarchy lists them: in tree order (each followed by its
//! children), with their names and components, narrowed by a filter.
const std = @import("std");
const eggy = @import("eggy");
const ecs = eggy.ecs;

pub const Row = struct {
    entity: ecs.EntityId,
    /// Its `Name`; empty without one.
    name: []const u8,
    depth: usize,
    has_parent: bool,
    /// The names of its components, in type order.
    components: []const []const u8,
};

/// Every entity of `world` in tree order, named and described through `access` (null: no game
/// library, so neither), into `arena`. With a `filter`, only the entities whose name or a
/// component's name contains it (ignoring case) are listed, with their ancestors to place them.
pub fn collect(arena: std.mem.Allocator, world: *ecs.World, access: ?eggy.scene.Access, filter: []const u8) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    for (world.slots.items, 0..) |slot, index| {
        if (!slot.alive) continue;
        const entity = ecs.EntityId.init(@intCast(index), slot.generation);
        if (world.getParent(entity) == null) try addSubtree(arena, &rows, world, access, entity, 0);
    }
    const query = std.mem.trim(u8, filter, " ");
    if (query.len == 0) return rows.items;

    // Keep the matches and every row above one at a lower depth: its ancestors.
    const keep = try arena.alloc(bool, rows.items.len);
    @memset(keep, false);
    for (rows.items, 0..) |row, i| {
        if (!matches(row, query)) continue;
        keep[i] = true;
        var depth = row.depth;
        var j = i;
        while (depth > 0 and j > 0) {
            j -= 1;
            if (rows.items[j].depth < depth) {
                keep[j] = true;
                depth = rows.items[j].depth;
            }
        }
    }
    var kept: std.ArrayList(Row) = .empty;
    for (rows.items, keep) |row, wanted| if (wanted) try kept.append(arena, row);
    return kept.items;
}

fn addSubtree(arena: std.mem.Allocator, rows: *std.ArrayList(Row), world: *ecs.World, access: ?eggy.scene.Access, entity: ecs.EntityId, depth: usize) !void {
    var name_buffer: [eggy.Name.max_len]u8 = undefined;
    var names: std.ArrayList([]const u8) = .empty;
    var name: []const u8 = "";
    if (access) |through| {
        if (through.name(world, entity, &name_buffer)) |text| name = try arena.dupe(u8, text);
        for (through.types(), 0..) |info, component| {
            if (through.has(world, entity, component)) try names.append(arena, info.name);
        }
    }
    try rows.append(arena, .{ .entity = entity, .name = name, .depth = depth, .has_parent = depth > 0, .components = names.items });
    var children = world.children(entity);
    while (children.next()) |child| try addSubtree(arena, rows, world, access, child, depth + 1);
}

fn matches(row: Row, query: []const u8) bool {
    if (std.ascii.indexOfIgnoreCase(row.name, query) != null) return true;
    for (row.components) |name| if (std.ascii.indexOfIgnoreCase(name, query) != null) return true;
    return false;
}

test "rows come in tree order, and a filter keeps matches with their ancestors" {
    const gpa = std.testing.allocator;
    const Spin = struct { speed: f32 = 1 };
    const access = eggy.scene.registryAccess(eggy.components.Registry(&.{Spin}, &.{"game"}));
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const sun = try world.spawn(.{});
    access.setName(&world, sun, "Sun");
    const earth = try world.spawn(.{});
    access.setName(&world, earth, "Earth");
    try world.setParent(earth, sun);
    const moon = try world.spawn(.{Spin{}});
    access.setName(&world, moon, "Moon");
    try world.setParent(moon, earth);
    const comet = try world.spawn(.{});
    access.setName(&world, comet, "Comet");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const all = try collect(arena.allocator(), &world, access, "");
    try std.testing.expectEqual(@as(usize, 4), all.len);
    try std.testing.expectEqualStrings("Moon", all[2].name);
    try std.testing.expectEqual(@as(usize, 2), all[2].depth);
    try std.testing.expectEqualStrings("Spin", all[2].components[0]);

    const spinning = try collect(arena.allocator(), &world, access, "spin");
    try std.testing.expectEqual(@as(usize, 3), spinning.len); // Sun, Earth, Moon
    try std.testing.expectEqualStrings("Moon", spinning[2].name);
    const comets = try collect(arena.allocator(), &world, access, "COMET");
    try std.testing.expectEqual(@as(usize, 1), comets.len);
}
