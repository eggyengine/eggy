//! The Hierarchy panel: the app's ECS world as a tree of entities (children under their parent),
//! each with the components it has, to pick one for the Inspector. Add Entity spawns an empty one;
//! Delete despawns the selected one and its children.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ecs = eggy.ecs;
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
const page_style = @import("../page_style.zig");

/// The deepest the tree indents; deeper entities line up with it.
const max_depth = 12;
const indent: f32 = 14;

/// Draw the page into `context`: `app`'s entities, `selected.*` lit, a press selecting another.
/// `game` names their components; without it only the entities show.
pub fn build(context: *ui.Context, app: *eggy.App, game: ?*const HotGame, selected: *?ecs.EntityId) void {
    const world = &app.world;
    if (selected.*) |entity| if (!world.isAlive(entity)) {
        selected.* = null;
    };

    // What to do: add an entity, or delete the selected one.
    context.begin(.row);
    if (context.buttonVariant("Add entity", .outline)) {
        const parent = selected.*;
        if (world.spawn(.{})) |entity| {
            if (parent) |under| world.setParent(entity, under) catch {};
            selected.* = entity;
        } else |err| std.log.err("cannot add an entity: {t}", .{err});
    }
    if (selected.*) |entity| if (context.buttonVariant("Delete", .ghost)) {
        world.despawnRecursive(entity);
        selected.* = null;
    };
    context.end();
    page_style.restyle(context, .{ .direction = .row, .gap = 8 });

    if (world.entityCount() == 0) {
        context.muted("No entities yet. Add one here, or spawn them from your game's code.");
        page_style.smallText(context, 13);
        return;
    }

    // The tree: entities without a parent, each followed by its children.
    context.begin(.column);
    for (world.slots.items, 0..) |slot, index| {
        if (!slot.alive) continue;
        const entity = ecs.EntityId.init(@intCast(index), slot.generation);
        if (world.getParent(entity) == null) row(context, app, game, selected, entity, 0);
    }
    context.end();
    page_style.restyle(context, .{ .gap = 1 });
}

/// `entity`'s row at `depth`, then its children's.
fn row(context: *ui.Context, app: *eggy.App, game: ?*const HotGame, selected: *?ecs.EntityId, entity: ecs.EntityId, depth: usize) void {
    const arena = context.builder().allocator;
    const id = context.idFor(std.fmt.allocPrint(arena, "entity {d}", .{entity.id}) catch return);
    if (context.activated(id)) selected.* = entity;
    const is_selected = if (selected.*) |chosen| chosen.eql(entity) else false;

    // Its name, and on the right the components it has.
    const label = std.fmt.allocPrint(arena, "Entity {d}", .{entity.id}) catch return;
    const item = context.builder().node(id, .{ .height = 26, .grow = 1 }, .{ .menu_item = .{ .label = label, .shortcut = componentList(arena, app, game, entity), .hot = is_selected, .size = .sm } }, &.{}) catch return;
    item.cursor = .pointer;
    item.accessibility = .{ .role = .menu_item, .label = label };
    const indented = context.builder().node(0, .{ .direction = .row, .padding = .{ .left = indent * @as(f32, @floatFromInt(@min(depth, max_depth))) } }, .none, &.{item}) catch return;
    context.element(indented);

    var children = app.world.children(entity);
    while (children.next()) |child| row(context, app, game, selected, child, depth + 1);
}

/// The names of `entity`'s components, comma-separated, in `arena`.
fn componentList(arena: std.mem.Allocator, app: *eggy.App, game: ?*const HotGame, entity: ecs.EntityId) []const u8 {
    const loaded = game orelse return "";
    var names: std.ArrayList(u8) = .empty;
    for (loaded.component_types, 0..) |info, index| {
        if (!loaded.hasComponent(app, entity, index)) continue;
        if (names.items.len > 0) names.appendSlice(arena, ", ") catch return names.items;
        names.appendSlice(arena, info.name) catch return names.items;
    }
    return names.items;
}
