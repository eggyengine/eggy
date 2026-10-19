//! The world's entities as the Hierarchy lists them: in tree order (each followed by its
//! children, but not a scene instance's, which come from its file), with their names and
//! components, narrowed by a filter.
const std = @import("std");
const eggy = @import("eggy");
const ecs = eggy.ecs;

pub const Row = struct {
    entity: ecs.EntityId,
    /// Its `Name`; empty without one.
    name: []const u8,
    depth: usize,
    has_parent: bool,
    has_children: bool = false,
    collapsed: bool = false,
    hidden: bool = false,
    self_hidden: bool = false,
    /// The names of its components, in type order.
    components: []const []const u8,
    /// Whether it is the last of its siblings shown: the tree's guide line ends at it.
    last: bool = true,
    /// For each level above it (`depth` of them), whether that level's guide line carries on
    /// past this row, to a later sibling of its ancestor there.
    lines: []const bool = &.{},
};

/// Every entity of `world` in tree order from `roots` (its top-level entities, in order), named
/// and described through `access` (null: no game library, so neither), into `arena`. With a
/// `filter`, only the entities whose name or a component's name contains it (ignoring case) are
/// listed, with their ancestors to place them.
/// Editor-only: supply live, ordered roots from this world and access from its loaded game.
/// Rows, copied names and guide lines live in `arena`; component-name strings still borrow
/// the game's metadata and must not survive library unload. Allocation failures propagate.
///
/// ```zig
/// // Given arena allocator, world, ordered root ids and optional game scene access:
/// const rows = try collect(arena, &world, roots, access, "camera");
/// ```
pub fn collect(arena: std.mem.Allocator, world: *ecs.World, roots: []const ecs.EntityId, access: ?eggy.scene.Access, filter: []const u8) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    for (roots) |entity| try addSubtree(arena, &rows, world, access, entity, 0);
    const query = std.mem.trim(u8, filter, " ");
    if (query.len == 0) return guides(arena, rows.items);

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
    return guides(arena, kept.items);
}

/// `rows` with their guide lines worked out (`last` and `lines`), from the rows shown.
fn guides(arena: std.mem.Allocator, rows: []Row) ![]const Row {
    // Backwards: `later[d]` says a row at depth `d` comes later, before anything shallower.
    var later: std.ArrayList(bool) = .empty;
    var i = rows.len;
    while (i > 0) {
        i -= 1;
        const row = &rows[i];
        while (later.items.len <= row.depth) try later.append(arena, false);
        row.last = !later.items[row.depth];
        const lines = try arena.alloc(bool, row.depth);
        for (lines, 0..) |*line, level| line.* = later.items[level + 1];
        row.lines = lines;
        later.items[row.depth] = true;
        for (later.items[row.depth + 1 ..]) |*deeper| deeper.* = false;
    }
    return rows;
}

fn addSubtree(arena: std.mem.Allocator, rows: *std.ArrayList(Row), world: *ecs.World, access: ?eggy.scene.Access, entity: ecs.EntityId, depth: usize) !void {
    var name_buffer: [eggy.Name.max_len]u8 = undefined;
    var names: std.ArrayList([]const u8) = .empty;
    var name: []const u8 = "";
    var instance = false;
    if (access) |through| {
        if (through.name(world, entity, &name_buffer)) |text| name = try arena.dupe(u8, text);
        for (through.types(), 0..) |info, component| {
            if (through.has(world, entity, component)) try names.append(arena, info.name);
        }
        if (eggy.scene_instance.typeIndex(through.types())) |component| instance = through.has(world, entity, component);
    }
    var children = world.children(entity);
    const has_children = !instance and children.next() != null;
    try rows.append(arena, .{ .entity = entity, .name = name, .depth = depth, .has_parent = depth > 0, .has_children = has_children, .components = names.items });
    if (instance) return;
    children = world.children(entity);
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
    const roots = [_]ecs.EntityId{ sun, comet };
    const all = try collect(arena.allocator(), &world, &roots, access, "");
    try std.testing.expectEqual(@as(usize, 4), all.len);
    try std.testing.expectEqualStrings("Moon", all[2].name);
    try std.testing.expectEqual(@as(usize, 2), all[2].depth);
    try std.testing.expectEqualStrings("Spin", all[2].components[0]);

    const spinning = try collect(arena.allocator(), &world, &roots, access, "spin");
    try std.testing.expectEqual(@as(usize, 3), spinning.len); // Sun, Earth, Moon
    try std.testing.expectEqualStrings("Moon", spinning[2].name);
    const comets = try collect(arena.allocator(), &world, &roots, access, "COMET");
    try std.testing.expectEqual(@as(usize, 1), comets.len);

    // Earth is the Sun's only child, so its line ends there; the Sun's level carries on past
    // the Moon to the Comet, the last at the top.
    try std.testing.expect(all[1].last);
    try std.testing.expect(!all[0].last);
    try std.testing.expect(all[3].last);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, all[2].lines);
}
