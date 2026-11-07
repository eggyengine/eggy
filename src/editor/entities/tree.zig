//! The world's entities as the Hierarchy lists them: in tree order (each followed by its
//! children, a scene instance's marked as made from its file), with their names and components,
//! narrowed by a filter. The scene's root comes first, named after the scene, the rest under it.
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
    /// Made by a scene instance above it from its file: it can be tuned for that instance
    /// (its fields are saved as the instance's changes), but not renamed or moved.
    from_instance: bool = false,
    /// The scene's root (`eggy.SceneRoot`): its settings are tuned, but it isn't renamed, moved,
    /// copied or deleted.
    scene_root: bool = false,
    /// Whether it is the last of its siblings shown: the tree's guide line ends at it.
    last: bool = true,
    /// For each level above it (`depth` of them), whether that level's guide line carries on
    /// past this row, to a later sibling of its ancestor there.
    lines: []const bool = &.{},
};

/// Every entity of `world` in tree order from `roots` (its top-level entities, in order), named
/// and described through `access` (null: no game library, so neither), into `arena`. With a
/// `filter`, only the entities whose name or a component's name contains it (ignoring case) are
/// listed, with their ancestors to place them. The scene's root, if any, is listed first as
/// `scene_name` (null: its own name), and every other top-level entity a level under it.
/// Editor-only: supply live, ordered roots from this world and access from its loaded game.
/// Rows, copied names and guide lines live in `arena`; component-name strings still borrow
/// the game's metadata and must not survive library unload. Allocation failures propagate.
///
/// ```zig
/// // Given arena allocator, world, ordered root ids and optional game scene access:
/// const rows = try collect(arena, &world, roots, access, "main", "camera");
/// ```
pub fn collect(arena: std.mem.Allocator, world: *ecs.World, roots: []const ecs.EntityId, access: ?eggy.scene.Access, scene_name: ?[]const u8, filter: []const u8) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    const scene_root = if (access) |through| eggy.scene_root.find(world, through) else null;
    if (scene_root) |root| {
        try addSubtree(arena, &rows, world, access, root, 0, false);
        const row = &rows.items[0];
        row.scene_root = true;
        if (scene_name) |name| row.name = name;
        row.has_children = row.has_children or roots.len > 1;
    }
    const depth: usize = @intFromBool(scene_root != null);
    for (roots) |entity| {
        if (scene_root) |root| if (root.eql(entity)) continue;
        try addSubtree(arena, &rows, world, access, entity, depth, false);
    }
    return narrow(arena, rows.items, filter);
}

/// `rows` (in tree order, from any source) narrowed by `filter` as `collect` does, with their
/// guide lines worked out. Rows and guide lines live in `arena`; `rows` may be changed.
pub fn narrow(arena: std.mem.Allocator, rows: []Row, filter: []const u8) ![]const Row {
    const query = std.mem.trim(u8, filter, " ");
    if (query.len == 0) return guides(arena, rows);

    // Keep the matches and every row above one at a lower depth: its ancestors.
    const keep = try arena.alloc(bool, rows.len);
    @memset(keep, false);
    for (rows, 0..) |row, i| {
        if (!matches(row, query)) continue;
        keep[i] = true;
        var depth = row.depth;
        var j = i;
        while (depth > 0 and j > 0) {
            j -= 1;
            if (rows[j].depth < depth) {
                keep[j] = true;
                depth = rows[j].depth;
            }
        }
    }
    var kept: std.ArrayList(Row) = .empty;
    for (rows, keep) |row, wanted| if (wanted) try kept.append(arena, row);
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

fn addSubtree(arena: std.mem.Allocator, rows: *std.ArrayList(Row), world: *ecs.World, access: ?eggy.scene.Access, entity: ecs.EntityId, depth: usize, from_instance: bool) !void {
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
    // An instanced scene's own root holds only that scene's settings: its children stand in for it.
    if (from_instance) if (access) |through| if (eggy.scene_root.typeIndex(through.types())) |component| if (through.has(world, entity, component)) {
        var lifted = world.children(entity);
        while (lifted.next()) |child| try addSubtree(arena, rows, world, access, child, depth, true);
        return;
    };
    var children = world.children(entity);
    const has_children = children.next() != null;
    try rows.append(arena, .{ .entity = entity, .name = name, .depth = depth, .has_parent = world.getParent(entity) != null, .has_children = has_children, .components = names.items, .from_instance = from_instance });
    children = world.children(entity);
    while (children.next()) |child| try addSubtree(arena, rows, world, access, child, depth + 1, from_instance or instance);
}

fn matches(row: Row, query: []const u8) bool {
    if (std.ascii.findIgnoreCase(row.name, query) != null) return true;
    for (row.components) |name| if (std.ascii.findIgnoreCase(name, query) != null) return true;
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
    const all = try collect(arena.allocator(), &world, &roots, access, null, "");
    try std.testing.expectEqual(@as(usize, 4), all.len);
    try std.testing.expectEqualStrings("Moon", all[2].name);
    try std.testing.expectEqual(@as(usize, 2), all[2].depth);
    try std.testing.expectEqualStrings("Spin", all[2].components[0]);

    const spinning = try collect(arena.allocator(), &world, &roots, access, null, "spin");
    try std.testing.expectEqual(@as(usize, 3), spinning.len); // Sun, Earth, Moon
    try std.testing.expectEqualStrings("Moon", spinning[2].name);
    const comets = try collect(arena.allocator(), &world, &roots, access, null, "COMET");
    try std.testing.expectEqual(@as(usize, 1), comets.len);

    // Earth is the Sun's only child, so its line ends there; the Sun's level carries on past
    // the Moon to the Comet, the last at the top.
    try std.testing.expect(all[1].last);
    try std.testing.expect(!all[0].last);
    try std.testing.expect(all[3].last);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, all[2].lines);
}

test "a scene instance's entities are listed under it, marked as made from its file, without its scene's root" {
    const gpa = std.testing.allocator;
    const access = eggy.scene.registryAccess(eggy.components.Registry(&.{ eggy.Transform, eggy.SceneInstance, eggy.physics.PhysicsSettings, eggy.SceneRoot }, &.{ "eggy", "eggy", "eggy", "eggy" }));
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const player_entity = try world.spawn(.{ eggy.Transform{}, eggy.SceneInstance{} });
    const player = try world.spawn(.{});
    try world.setParent(player, player_entity);
    const hat = try world.spawn(.{});
    try world.setParent(hat, player);
    // The instanced scene's own root isn't listed.
    const instanced_root = try world.spawn(.{eggy.SceneRoot{}});
    try world.setParent(instanced_root, player_entity);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rows = try collect(arena.allocator(), &world, &.{player_entity}, access, null, "");
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expect(rows[0].has_children and !rows[0].from_instance);
    try std.testing.expect(rows[1].from_instance and rows[2].from_instance);
}

test "the scene root comes first under the scene's name, the other top-level entities under it" {
    const gpa = std.testing.allocator;
    const access = eggy.scene.registryAccess(eggy.components.Registry(&.{ eggy.physics.PhysicsSettings, eggy.SceneRoot }, &.{ "eggy", "eggy" }));
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const crate = try world.spawn(.{});
    access.setName(&world, crate, "Crate");
    const lid = try world.spawn(.{});
    try world.setParent(lid, crate);
    const root = (try eggy.scene_root.ensure(&world, access, .three)).?;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rows = try collect(arena.allocator(), &world, &.{ crate, root }, access, "level_1", "");
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expect(rows[0].entity.eql(root) and rows[0].scene_root and rows[0].has_children);
    try std.testing.expectEqualStrings("level_1", rows[0].name);
    try std.testing.expectEqual(@as(usize, 1), rows[1].depth);
    try std.testing.expect(!rows[1].has_parent and rows[2].has_parent);
    try std.testing.expectEqual(@as(usize, 2), rows[2].depth);
}
