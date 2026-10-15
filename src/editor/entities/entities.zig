//! Entities in the editor: the Hierarchy panel's tree of the world's entities and the
//! Inspector's view of the one selected there, and carrying out what they ask (selecting,
//! adding, deleting, renaming, reparenting, duplicating, and changing components) on the app's
//! world through the game's library.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ecs = eggy.ecs;
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
const tree = @import("tree.zig");
const hierarchy_zig = @import("hierarchy.zig");
const inspector_zig = @import("inspector.zig");
const RootOrder = @import("root_order.zig").RootOrder;
const Dragged = @import("../dragged.zig").Dragged;
const log = std.log.scoped(.entities);

pub const EntityEditor = struct {
    gpa: std.mem.Allocator,
    hierarchy: hierarchy_zig.Hierarchy,
    inspector: inspector_zig.EntityInspector,
    /// The entity the Inspector shows.
    selected: ?ecs.EntityId = null,
    /// The top-level entities' order.
    root_order: RootOrder,

    pub fn init(gpa: std.mem.Allocator) EntityEditor {
        return .{ .gpa = gpa, .hierarchy = .init(gpa), .inspector = .init(gpa), .root_order = .{ .gpa = gpa } };
    }

    pub fn deinit(self: *EntityEditor) void {
        self.hierarchy.deinit();
        self.inspector.deinit();
        self.root_order.deinit();
    }

    /// `world`'s top-level entities in the Hierarchy's order, for capturing the scene in it.
    pub fn roots(self: *EntityEditor, world: *ecs.World) []const ecs.EntityId {
        return self.root_order.of(world);
    }

    /// Draw the Hierarchy page into `context`, and carry out what it asks.
    pub fn buildHierarchy(self: *EntityEditor, context: *ui.Context, app: *eggy.App, game: ?*const HotGame) void {
        self.forgetDead(app);
        const access = if (game) |loaded| loaded.sceneAccess() else null;
        const rows = tree.collect(context.builder().allocator, &app.world, self.roots(&app.world), access, self.hierarchy.filterText()) catch &.{};
        if (self.hierarchy.build(context, rows, self.selected)) |action| self.apply(app, game, action);
    }

    /// The entity being dragged out of the Hierarchy, described for other panels; null while
    /// none is. In `arena`.
    pub fn dragged(self: *const EntityEditor, arena: std.mem.Allocator, app: *eggy.App, game: ?*const HotGame) ?Dragged {
        const drag = self.hierarchy.drag orelse return null;
        if (!drag.moving or !app.world.isAlive(drag.entity)) return null;
        var names: std.ArrayList([]const u8) = .empty;
        if (game) |loaded| for (loaded.component_types, 0..) |info, index| {
            if (loaded.hasComponent(app, drag.entity, index)) names.append(arena, info.name) catch {};
        };
        const name = self.hierarchy.nameOf(drag.entity);
        return .{ .entity = .{
            .entity = drag.entity,
            .name = if (name.len > 0) name else std.fmt.allocPrint(arena, "Entity {d}", .{drag.entity.id}) catch "Entity",
            .components = names.items,
        } };
    }

    /// `dragging` let go over the Inspector page `context` at `at`: set the reference field
    /// there, if it takes it. Returns whether one did.
    pub fn dropOnInspector(self: *EntityEditor, context: *const ui.Context, app: *eggy.App, game: ?*const HotGame, at: ui.Vec2, dragging: Dragged) bool {
        const entity = self.selected orelse return false;
        const loaded = game orelse return false;
        var buffer: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const action = self.inspector.dropAt(context, at, loaded.component_types, dragging, fba.allocator()) orelse return false;
        var text_buffer: [600]u8 = undefined;
        const text = std.fmt.bufPrintZ(&text_buffer, "{s}", .{action.set_field.text}) catch return false;
        return loaded.writeField(app, entity, action.set_field.component, action.set_field.field, text);
    }

    /// Draw the selected entity into the Inspector page `context`, and carry out what it asks;
    /// its reference fields light up for `dragging`. Returns false, drawing nothing, when no
    /// entity is selected.
    /// Components of the plugins keyed in `off` show as disabled, and can't be added.
    pub fn buildInspector(self: *EntityEditor, context: *ui.Context, app: *eggy.App, game: ?*const HotGame, dragging: ?Dragged, off: []const []const u8) bool {
        self.forgetDead(app);
        const entity = self.selected orelse return false;
        const arena = context.builder().allocator;
        const loaded = game orelse {
            context.heading(3, std.fmt.allocPrint(arena, "Entity {d}", .{entity.id}) catch "Entity");
            context.muted("The game's library didn't load, so this entity's components can't be shown.");
            return true;
        };
        var details = collectDetails(arena, app, loaded, entity, off) catch return true;
        details.dragging = dragging;
        if (self.inspector.build(context, details)) |action| switch (action) {
            .rename => |name| loaded.writeName(app, entity, name),
            .set_field => |change| {
                var buffer: [257]u8 = undefined;
                const text = std.fmt.bufPrintZ(&buffer, "{s}", .{change.text}) catch return true;
                // Text that doesn't parse yet is left until it does.
                _ = loaded.writeField(app, entity, change.component, change.field, text);
            },
            .add_component => |component| _ = loaded.addComponent(app, entity, component),
            .remove_component => |component| loaded.removeComponent(app, entity, component),
        };
        return true;
    }

    /// A pointer event over the Hierarchy page, before its UI sees it (see `Hierarchy.pointer`).
    /// Returns whether it was used.
    pub fn hierarchyPointer(self: *EntityEditor, context: *const ui.Context, app: *eggy.App, game: ?*const HotGame, event: ui.input.Event) bool {
        const result = self.hierarchy.pointer(context, event);
        if (result.action) |action| self.apply(app, game, action);
        return result.used;
    }

    /// Rename the selected entity in the Hierarchy (F2).
    pub fn renameSelected(self: *EntityEditor) void {
        const entity = self.selected orelse return;
        self.hierarchy.startRename(entity, self.hierarchy.nameOf(entity));
    }

    /// A key while the Hierarchy page has the keyboard. Returns whether it was used.
    pub fn hierarchyKey(self: *EntityEditor, app: *eggy.App, game: ?*const HotGame, key: @FieldType(ui.input.Event, "key_down")) bool {
        const result = self.hierarchy.key(key, self.selected);
        if (result.action) |action| self.apply(app, game, action);
        return result.used;
    }

    fn apply(self: *EntityEditor, app: *eggy.App, game: ?*const HotGame, action: hierarchy_zig.Action) void {
        const world = &app.world;
        switch (action) {
            .select => |entity| self.selected = entity,
            .spawn => |parent| {
                const entity = world.spawn(.{}) catch |err| return log.err("cannot add an entity: {t}", .{err});
                if (parent) |under| if (world.isAlive(under)) world.setParent(entity, under) catch {};
                self.selected = entity;
                self.hierarchy.startRename(entity, "");
            },
            .delete => |entity| {
                world.despawnRecursive(entity);
                self.selected = null;
            },
            .rename => |change| if (game) |loaded| loaded.writeName(app, change.entity, change.name),
            .move => |change| self.moveEntity(world, change.entity, change.place) catch |err| switch (err) {
                error.InvalidHierarchy => log.warn("an entity can't go under itself or one of its children", .{}),
                else => log.err("cannot move the entity: {t}", .{err}),
            },
            .duplicate => |entity| {
                const loaded = game orelse return;
                var copy = eggy.scene.Scene.capture(self.gpa, world, loaded.sceneAccess(), &.{entity}) catch |err| return log.err("cannot duplicate: {t}", .{err});
                defer copy.deinit();
                const made = copy.instantiate(self.gpa, world, loaded.sceneAccess(), world.getParent(entity)) catch |err| return log.err("cannot duplicate: {t}", .{err});
                defer self.gpa.free(made.entities);
                if (made.entities.len == 0) return;
                // The copy goes right after the original.
                self.moveEntity(world, made.entities[0], .{ .after = entity }) catch {};
                self.selected = made.entities[0];
            },
        }
    }

    /// Move `entity` to `place`: under a parent (last), beside a sibling, or to the end of the
    /// top level.
    fn moveEntity(self: *EntityEditor, world: *ecs.World, entity: ecs.EntityId, place: hierarchy_zig.Place) !void {
        if (!world.isAlive(entity)) return;
        _ = self.roots(world);
        switch (place) {
            .into => |parent| try world.insertChild(parent, entity, std.math.maxInt(usize)),
            .top_level => {
                world.removeParent(entity);
                try self.root_order.place(entity, std.math.maxInt(usize));
            },
            inline .before, .after => |sibling, side| {
                if (!world.isAlive(sibling) or sibling.eql(entity)) return;
                const offset: usize = if (side == .after) 1 else 0;
                if (world.getParent(sibling)) |parent| {
                    // Its place among the siblings once it has left them.
                    var index: usize = 0;
                    var it = world.children(parent);
                    while (it.next()) |child| {
                        if (child.eql(sibling)) break;
                        if (!child.eql(entity)) index += 1;
                    }
                    try world.insertChild(parent, entity, index + offset);
                } else {
                    world.removeParent(entity);
                    if (self.root_order.indexOf(entity)) |at| _ = self.root_order.entities.orderedRemove(at);
                    const index = self.root_order.indexOf(sibling) orelse return;
                    try self.root_order.place(entity, index + offset);
                }
            },
        }
    }

    fn forgetDead(self: *EntityEditor, app: *eggy.App) void {
        if (self.selected) |entity| if (!app.world.isAlive(entity)) {
            self.selected = null;
        };
    }
};

/// What the Inspector shows of `entity`, read through `game`, in `arena`. Components of the
/// plugins keyed in `off` are disabled, and not offered to add.
fn collectDetails(arena: std.mem.Allocator, app: *eggy.App, game: *const HotGame, entity: ecs.EntityId, off: []const []const u8) !inspector_zig.Details {
    var name_buffer: [eggy.Name.max_len]u8 = undefined;
    const name = if (game.readName(app, entity, &name_buffer)) |text| try arena.dupe(u8, text) else "";
    var list: std.ArrayList(inspector_zig.Details.Component) = .empty;
    var addable: std.ArrayList(inspector_zig.Details.Addable) = .empty;
    for (game.component_types, 0..) |info, index| {
        const disabled = isOff(off, info.owner);
        if (!game.hasComponent(app, entity, index)) {
            if (info.addable and !disabled) try addable.append(arena, .{ .index = index, .label = try std.fmt.allocPrint(arena, "{s} ({s})", .{ info.name, info.owner }) });
            continue;
        }
        const values = try arena.alloc(?[]const u8, info.fields.len);
        const shown = try arena.alloc(?[]const u8, info.fields.len);
        for (values, shown, info.fields, 0..) |*value, *label, field_info, field| {
            var buffer: [512]u8 = undefined;
            value.* = if (game.readField(app, entity, index, field, &buffer)) |text| try arena.dupe(u8, text) else null;
            label.* = try referenceLabel(arena, app, game, field_info.kind, value.* orelse "");
        }
        try list.append(arena, .{ .index = index, .info = info, .values = values, .shown = shown, .disabled = disabled });
    }
    return .{ .entity = entity, .name = name, .components = list.items, .addable = addable.items };
}

/// Whether plugin `owner` is among those keyed in `off`.
pub fn isOff(off: []const []const u8, owner: []const u8) bool {
    for (off) |key| if (std.mem.eql(u8, key, owner)) return true;
    return false;
}

/// A reference field's value (`zon`) as people read it: the entity's name, or the file's;
/// empty when unset; null for other kinds of field.
fn referenceLabel(arena: std.mem.Allocator, app: *eggy.App, game: *const HotGame, kind: eggy.components.Kind, zon: []const u8) !?[]const u8 {
    var scratch: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const source = try arena.dupeZ(u8, zon);
    switch (kind) {
        .entity => {
            const target = (std.zon.parse.fromSlice(?ecs.EntityId, fba.allocator(), source, null, .{}) catch return "") orelse return "";
            if (!app.world.isAlive(target)) return try std.fmt.allocPrint(arena, "Entity {d} (gone)", .{target.id});
            var name_buffer: [eggy.Name.max_len]u8 = undefined;
            if (game.readName(app, target, &name_buffer)) |name| if (name.len > 0) return try arena.dupe(u8, name);
            return try std.fmt.allocPrint(arena, "Entity {d}", .{target.id});
        },
        .asset => {
            const path = std.zon.parse.fromSliceAlloc([]const u8, fba.allocator(), source, null, .{}) catch return "";
            return try arena.dupe(u8, path);
        },
        else => return null,
    }
}

test {
    _ = @import("root_order.zig");
    _ = @import("tree.zig");
    _ = @import("hierarchy.zig");
    _ = @import("inspector.zig");
}

test "moves place an entity before or after a sibling, at the top level or under a parent" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    var editor = EntityEditor.init(gpa);
    defer editor.deinit();
    const a = try world.spawn(.{});
    const b = try world.spawn(.{});
    const c = try world.spawn(.{});

    try editor.moveEntity(&world, c, .{ .before = a });
    try std.testing.expectEqualSlices(ecs.EntityId, &.{ c, a, b }, editor.roots(&world));
    try editor.moveEntity(&world, c, .{ .after = b });
    try std.testing.expectEqualSlices(ecs.EntityId, &.{ a, b, c }, editor.roots(&world));

    // Under `a`, then reordered among its children.
    try editor.moveEntity(&world, b, .{ .into = a });
    try editor.moveEntity(&world, c, .{ .into = a });
    try editor.moveEntity(&world, c, .{ .before = b });
    var it = world.children(a);
    try std.testing.expectEqual(c, it.next().?);
    try std.testing.expectEqual(b, it.next().?);
    try std.testing.expectEqualSlices(ecs.EntityId, &.{a}, editor.roots(&world));

    // Beside a top-level entity takes it out of its parent.
    try editor.moveEntity(&world, b, .{ .before = a });
    try std.testing.expectEqualSlices(ecs.EntityId, &.{ b, a }, editor.roots(&world));
}
