//! Entities in the editor: the Hierarchy panel's tree of the world's entities and the
//! Inspector's view of the one selected there, and carrying out what they ask (selecting,
//! adding, deleting, renaming, reparenting, duplicating, and changing components) on the app's
//! world through the game's library. A model or scene file dropped into the world becomes an
//! entity of its own, and each scene instance's entities are kept made (`eggy.SceneInstances`).
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
pub const SceneInstances = eggy.SceneInstances;
const log = std.log.scoped(.entities);

pub const EntityEditor = struct {
    gpa: std.mem.Allocator,
    hierarchy: hierarchy_zig.Hierarchy,
    inspector: inspector_zig.EntityInspector,
    /// The entity the Inspector shows.
    selected: ?ecs.EntityId = null,
    /// The top-level entities' order.
    root_order: RootOrder,

    /// Create editor-only hierarchy, inspector and root-order state using `gpa`.
    /// Does not create a world; pair with `deinit`.
    ///
    /// ```zig
    /// var entities = EntityEditor.init(gpa); // Existing allocator.
    /// defer entities.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator) EntityEditor {
        return .{ .gpa = gpa, .hierarchy = .init(gpa), .inspector = .init(gpa), .root_order = .{ .gpa = gpa } };
    }

    /// Release editor UI/order storage once, without despawning entities or unloading the game.
    /// Stop building/routing panel events before calling.
    ///
    /// ```zig
    /// var entities = EntityEditor.init(gpa); // Existing allocator.
    /// defer entities.deinit();
    /// ```
    pub fn deinit(self: *EntityEditor) void {
        self.hierarchy.deinit();
        self.inspector.deinit();
        self.root_order.deinit();
    }

    /// `world`'s top-level entities in the Hierarchy's order, for capturing the scene in it.
    /// Editor-only: reconciles dead/new/reparented roots; the slice borrows mutable root-order
    /// storage until its next change. Allocation failure may return only the collected prefix.
    ///
    /// ```zig
    /// const roots = entities.roots(&app.world); // Existing EntityEditor and App pointer.
    /// ```
    pub fn roots(self: *EntityEditor, world: *ecs.World) []const ecs.EntityId {
        return self.root_order.of(world);
    }

    /// Draw the Hierarchy page into `context`, and carry out what it asks.
    /// Editor-only: call during UI construction with the App owning this game's world.
    /// May select/spawn/despawn/reparent/rename entities immediately; collection failures show
    /// an empty tree, and mutation failures are logged or ignored rather than propagated.
    ///
    /// ```zig
    /// // Given entities, building context, App pointer and optional loaded HotGame pointer:
    /// entities.buildHierarchy(context, app, game);
    /// ```
    pub fn buildHierarchy(self: *EntityEditor, context: *ui.Context, app: *eggy.App, game: ?*const HotGame) void {
        self.forgetDead(app);
        const access = if (game) |loaded| loaded.sceneAccess() else null;
        const rows = tree.collect(context.builder().allocator, &app.world, self.roots(&app.world), access, self.hierarchy.filterText()) catch &.{};
        if (self.hierarchy.build(context, rows, self.selected)) |action| self.apply(app, game, action);
    }

    /// The entity being dragged out of the Hierarchy, described for other panels; null while
    /// none is. In `arena`.
    /// Editor-only: the world must still contain the dragged entity. Generated fallback names
    /// and component lists live in `arena`; existing names borrow hierarchy rows and component
    /// names borrow the game library. Consume before rebuilding/unloading; allocation failures
    /// may omit component names.
    ///
    /// ```zig
    /// // Given entities, frame arena allocator, App and optional HotGame pointers:
    /// const drag = entities.dragged(arena, app, game);
    /// ```
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
    /// Editor-only: use the Inspector's last-layout UI coordinates before rebuilding it.
    /// Writes the selected entity's field synchronously through the game ABI; false includes
    /// missing selection/library, incompatible slots, oversized ZON and rejected writes.
    ///
    /// ```zig
    /// // Given entities, Inspector context, App/game pointers, UI position and Dragged:
    /// const applied = entities.dropOnInspector(context, app, game, at, dragging);
    /// ```
    pub fn dropOnInspector(self: *EntityEditor, context: *const ui.Context, app: *eggy.App, game: ?*const HotGame, at: ui.Vec2, dragging: Dragged) bool {
        const entity = self.selected orelse return false;
        const loaded = game orelse return false;
        var buffer: [8192]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const action = self.inspector.dropAt(context, at, dragging, fba.allocator()) orelse return false;
        const text = fba.allocator().dupeZ(u8, action.set_field.text) catch return false;
        return loaded.writeField(app, entity, action.set_field.component, action.set_field.field, text);
    }

    /// Draw the selected entity into the Inspector page `context`, and carry out what it asks;
    /// its reference fields light up for `dragging`. Returns false, drawing nothing, when no
    /// entity is selected.
    /// Components of the plugins keyed in `off` show as disabled, and can't be added.
    /// Editor-only: call during UI construction with game metadata still loaded. Applies field,
    /// name and component edits immediately; missing library shows an explanatory view.
    /// Collection/allocation failures do not propagate, and true means an entity was selected,
    /// not that an edit succeeded.
    ///
    /// ```zig
    /// // Given entities, building context and App/optional HotGame pointers:
    /// const shown = entities.buildInspector(context, app, game, null, &.{});
    /// ```
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
                const text = arena.dupeZ(u8, change.text) catch return true;
                // Text that doesn't parse yet is left until it does.
                _ = loaded.writeField(app, entity, change.component, change.field, text);
            },
            .add_component => |component| _ = loaded.addComponent(app, entity, component),
            .remove_component => |component| if (neededBy(arena, app, loaded, entity, component).len > 0) {
                log.warn("{s} can't be removed while another component needs it", .{loaded.component_types[component].name});
            } else loaded.removeComponent(app, entity, component),
        };
        return true;
    }

    /// A pointer event over the Hierarchy page, before its UI sees it (see `Hierarchy.pointer`).
    /// Returns whether it was used.
    /// Editor-only: use the page's last layout and UI-space event positions; any resulting
    /// selection/world mutation is applied synchronously before returning.
    ///
    /// ```zig
    /// const used = entities.hierarchyPointer(context, app, game, event);
    /// // Existing EntityEditor, last-layout context, App/game pointers and UI event.
    /// ```
    pub fn hierarchyPointer(self: *EntityEditor, context: *const ui.Context, app: *eggy.App, game: ?*const HotGame, event: ui.input.Event) bool {
        const result = self.hierarchy.pointer(context, event);
        if (result.action) |action| self.apply(app, game, action);
        return result.used;
    }

    /// Rename the selected entity in the Hierarchy (F2).
    /// Editor-only: begins a copied text edit without immediately changing the world;
    /// no selection is a no-op.
    ///
    /// ```zig
    /// entities.renameSelected(); // Existing EntityEditor with Hierarchy keyboard focus.
    /// ```
    pub fn renameSelected(self: *EntityEditor) void {
        const entity = self.selected orelse return;
        self.hierarchy.startRename(entity, self.hierarchy.nameOf(entity));
    }

    /// A key while the Hierarchy page has the keyboard. Returns whether it was used.
    /// Editor-only: pass a UI key-down payload; applies returned actions to the App's world,
    /// while rename/menu/drag cancellation only updates panel state.
    ///
    /// ```zig
    /// // Given entities, App/optional HotGame pointers and key-down payload:
    /// const used = entities.hierarchyKey(app, game, key_down);
    /// ```
    pub fn hierarchyKey(self: *EntityEditor, app: *eggy.App, game: ?*const HotGame, key: @FieldType(ui.input.Event, "key_down")) bool {
        const result = self.hierarchy.key(key, self.selected);
        if (result.action) |action| self.apply(app, game, action);
        return result.used;
    }

    /// Delete the selected entity and its children, as the Hierarchy's Delete does.
    /// Editor-only: clears selection; the library is not required for recursive despawning.
    /// No selection is a no-op; the surrounding editor owns any undo snapshot.
    ///
    /// ```zig
    /// entities.deleteSelected(app, game); // Existing EntityEditor and App/game pointers.
    /// ```
    pub fn deleteSelected(self: *EntityEditor, app: *eggy.App, game: ?*const HotGame) void {
        const entity = self.selected orelse return;
        self.apply(app, game, .{ .delete = entity });
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

    /// A new entity for the model or scene file at `path` (relative to the project), named
    /// after it, at `position` within `parent` (none: the top level), and selected: a model as
    /// its `Mesh`, a scene as its `SceneInstance`. Returns false, making nothing, for another
    /// kind of file or without the game's library.
    /// Editor-only: `position` is in the requested parent's local scene units. A live parent
    /// is attempted; invalid/unavailable parenting falls back to a root. Component/write
    /// failures are not transactional: true does not guarantee every field write succeeded,
    /// and a late failure can leave a partially configured entity.
    ///
    /// ```zig
    /// // Given entities and App/optional HotGame pointers:
    /// const made = entities.spawnFrom(app, game, "resources/ship.glb", .{ 0, 0, 0 }, null);
    /// ```
    pub fn spawnFrom(self: *EntityEditor, app: *eggy.App, game: ?*const HotGame, path: []const u8, position: [3]f32, parent: ?ecs.EntityId) bool {
        const loaded = game orelse return false;
        const kind = eggy.assets.Kind.of(path);
        const component = loaded.builtinComponent(switch (kind) {
            .model => "Mesh",
            .scene => "SceneInstance",
            else => return false,
        }) orelse return false;
        const transform = loaded.builtinComponent("Transform") orelse return false;

        const entity = app.world.spawn(.{}) catch |err| {
            log.err("cannot add an entity for {s}: {t}", .{ path, err });
            return false;
        };
        if (parent) |under| if (app.world.isAlive(under)) app.world.setParent(entity, under) catch {};
        const base = std.fs.path.basename(path);
        const suffix = if (kind == .scene) ".scene.zon" else std.fs.path.extension(base);
        loaded.writeName(app, entity, base[0 .. base.len - suffix.len]);

        // Its file (a model as the Mesh's shape), then where it goes; adding it adds Transform.
        var buffer: [eggy.refs.max_path_len + 32]u8 = undefined;
        const field_text = if (kind == .model)
            std.fmt.bufPrintZ(&buffer, ".{{ .model = \"{f}\" }}", .{std.zig.fmtString(path)})
        else
            std.fmt.bufPrintZ(&buffer, "\"{f}\"", .{std.zig.fmtString(path)});
        const field = for (loaded.component_types[component].fields, 0..) |info, i| {
            if (std.mem.eql(u8, info.name, if (kind == .model) "shape" else "scene")) break i;
        } else 0;
        _ = loaded.addComponent(app, entity, component);
        _ = loaded.writeField(app, entity, component, field, field_text catch return false);
        const position_text = std.fmt.bufPrintZ(&buffer, ".{{ {d}, {d}, {d} }}", .{ position[0], position[1], position[2] }) catch unreachable;
        _ = loaded.writeField(app, entity, transform, 0, position_text);
        self.selected = entity;
        return true;
    }

    /// Paint `entity`'s `Mesh` with the image at `path` (relative to the project), and select
    /// it. Returns false, changing nothing, when it has no `Mesh` or there's no game library.
    /// Editor-only: writes the texture reference through the game's field ABI; an oversized
    /// path or rejected write also returns false. Selection changes only after success.
    ///
    /// ```zig
    /// // Given entities, App/game pointers and a live entity with Mesh:
    /// const painted = entities.paint(app, game, entity, "resources/ship.png");
    /// ```
    pub fn paint(self: *EntityEditor, app: *eggy.App, game: ?*const HotGame, entity: ecs.EntityId, path: []const u8) bool {
        const loaded = game orelse return false;
        const component = loaded.builtinComponent("Mesh") orelse return false;
        if (!loaded.hasComponent(app, entity, component)) return false;
        const field = for (loaded.component_types[component].fields, 0..) |info, i| {
            if (std.mem.eql(u8, info.name, "texture")) break i;
        } else return false;
        var buffer: [eggy.refs.max_path_len + 8]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buffer, "\"{f}\"", .{std.zig.fmtString(path)}) catch return false;
        if (!loaded.writeField(app, entity, component, field, text)) return false;
        self.selected = entity;
        return true;
    }

    /// Where the selected entity is among the world's entities in scene order (as
    /// `Scene.capture` lists them), so `reselect` can find it once the world is made anew from
    /// a scene; null with nothing selected, or no game library.
    /// Editor-only: snapshot before replacing the world; allocation/capture failure or an
    /// entity omitted from the saved scene also returns null. All temporary scene data is freed.
    ///
    /// ```zig
    /// const place = entities.selectionPlace(app, game); // Before restoring the same scene order.
    /// ```
    pub fn selectionPlace(self: *EntityEditor, app: *eggy.App, game: ?*const HotGame) ?usize {
        const entity = self.selected orelse return null;
        const loaded = game orelse return null;
        var scene = eggy.scene.Scene.capture(self.gpa, &app.world, loaded.sceneAccess(), self.roots(&app.world)) catch return null;
        defer scene.deinit();
        for (scene.sources, 0..) |source, at| if (source.eql(entity)) return at;
        return null;
    }

    /// Select the entity at `place` (from `selectionPlace`) in the world as it is now.
    /// Editor-only: requires the same scene traversal order as the snapshot to recover the
    /// intended entity. Clears selection first; missing game, null/out-of-range place or capture
    /// failure leaves it clear. Temporary capture allocations are released before returning.
    ///
    /// ```zig
    /// // Given entities, App/game pointers and a saved selectionPlace after world restoration:
    /// entities.reselect(app, game, place);
    /// ```
    pub fn reselect(self: *EntityEditor, app: *eggy.App, game: ?*const HotGame, place: ?usize) void {
        self.selected = null;
        const at = place orelse return;
        const loaded = game orelse return;
        var scene = eggy.scene.Scene.capture(self.gpa, &app.world, loaded.sceneAccess(), self.roots(&app.world)) catch return;
        defer scene.deinit();
        if (at < scene.sources.len) self.selected = scene.sources[at];
    }

    /// Drop the selection once its entity is gone.
    /// Editor-only: checks the App's world including entity generation; does not alter the world.
    ///
    /// ```zig
    /// entities.forgetDead(app); // Existing EntityEditor after world mutation.
    /// ```
    pub fn forgetDead(self: *EntityEditor, app: *eggy.App) void {
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
            var buffer: [4096]u8 = undefined;
            value.* = if (game.readField(app, entity, index, field, &buffer)) |text| try arena.dupe(u8, text) else null;
            label.* = try referenceLabel(arena, app, game, field_info.kind, value.* orelse "");
        }
        var needs: std.ArrayList([]const u8) = .empty;
        for (info.dependencies) |dependency| if (dependency < game.component_types.len) try needs.append(arena, game.component_types[dependency].name);
        try list.append(arena, .{
            .index = index,
            .info = info,
            .values = values,
            .shown = shown,
            .disabled = disabled,
            .needs = try std.mem.join(arena, ", ", needs.items),
            .needed_by = neededBy(arena, app, game, entity, index),
        });
    }
    return .{ .entity = entity, .name = name, .components = list.items, .addable = addable.items };
}

/// The names of `entity`'s components that depend on component `component`, joined with commas,
/// in `arena`; empty when none does.
fn neededBy(arena: std.mem.Allocator, app: *eggy.App, game: *const HotGame, entity: ecs.EntityId, component: usize) []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (game.component_types, 0..) |info, index| {
        if (std.mem.indexOfScalar(usize, info.dependencies, component) == null) continue;
        if (game.hasComponent(app, entity, index)) names.append(arena, info.name) catch return "";
    }
    return std.mem.join(arena, ", ", names.items) catch "";
}

/// Whether plugin `owner` is among those keyed in `off`.
/// Editor-only: compares complete plugin keys exactly without allocation or ownership transfer.
///
/// ```zig
/// const disabled = isOff(&.{"game"}, "game"); // true
/// ```
pub fn isOff(off: []const []const u8, owner: []const u8) bool {
    for (off) |key| if (std.mem.eql(u8, key, owner)) return true;
    return false;
}

/// A reference field's value (`zon`) as people read it: the entity's name, or the file's;
/// empty when unset; null for other kinds of field.
fn referenceLabel(arena: std.mem.Allocator, app: *eggy.App, game: *const HotGame, kind: eggy.components.Kind, zon: []const u8) !?[]const u8 {
    // Parsing builds a syntax tree, so it takes the arena rather than a small fixed buffer.
    const source = try arena.dupeZ(u8, zon);
    switch (kind) {
        .entity => {
            const target = (std.zon.parse.fromSlice(?ecs.EntityId, arena, source, null, .{}) catch return "") orelse return "";
            if (!app.world.isAlive(target)) return try std.fmt.allocPrint(arena, "Entity {d} (gone)", .{target.id});
            var name_buffer: [eggy.Name.max_len]u8 = undefined;
            if (game.readName(app, target, &name_buffer)) |name| if (name.len > 0) return try arena.dupe(u8, name);
            return try std.fmt.allocPrint(arena, "Entity {d}", .{target.id});
        },
        .asset => return std.zon.parse.fromSliceAlloc([]const u8, arena, source, null, .{}) catch "",
        else => return null,
    }
}

test {
    _ = @import("root_order.zig");
    _ = @import("tree.zig");
    _ = @import("hierarchy.zig");
    _ = @import("inspector.zig");
    _ = @import("field_editor.zig");
    _ = @import("field_value.zig");
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
