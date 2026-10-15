//! The Hierarchy panel: the world's entities as a tree (see `tree.zig`), filtered by name or
//! component, to pick one for the Inspector. Each row shows the entity's name, and its components
//! as far as they fit beside it. Rows are dragged onto another to reparent them, or below the tree
//! to move them to the top level; a right-click opens a menu (rename, add a child, duplicate, move
//! to the top level, delete); a double-click or Ctrl+R renames, Delete deletes.
//!
//! The page doesn't change the world itself: `build`, `pointer` and `key` return the `Action` the
//! user took, for the editor to carry out.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ecs = eggy.ecs;
const L = ui.Layout;
const Row = @import("tree.zig").Row;
const page_style = @import("../page_style.zig");

pub const Action = union(enum) {
    select: ecs.EntityId,
    /// A new entity, under `parent` if given.
    spawn: ?ecs.EntityId,
    delete: ecs.EntityId,
    rename: struct { entity: ecs.EntityId, name: []const u8 },
    /// Move `entity` under `parent`, or to the top level when null.
    reparent: struct { entity: ecs.EntityId, parent: ?ecs.EntityId },
    duplicate: ecs.EntityId,
};

const NameEdit = ui.TextEdit(eggy.Name.max_len);
const FilterEdit = ui.TextEdit(64);

/// Row `entity.id` has element id `row_id_base + entity.id`, the same every frame, so presses
/// can be matched to rows by last frame's layout.
const row_id_base: u32 = 0x6E00_0000;
const drop_zone_id: u32 = row_id_base - 2;
const menu_id_base: u32 = row_id_base - 16;
const indent: f32 = 14;
const max_indent_depth = 10;
/// How far a press moves before it is a drag.
const drag_threshold: f32 = 5;
const name_size: f32 = 12;
const components_size: f32 = 11;

const MenuItem = enum(u32) { rename, add_child, duplicate, to_top, delete, add_entity };

pub const Hierarchy = struct {
    filter: FilterEdit = FilterEdit.init("") catch unreachable,
    /// The row being renamed, and its text.
    renaming: ?struct { entity: ecs.EntityId, edit: NameEdit, started: bool = false } = null,
    /// The right-click menu: where, and for which row (none: the empty space below the rows).
    menu: ?struct { at: ui.Vec2, entity: ?ecs.EntityId, has_parent: bool } = null,
    /// A press on a row, which becomes a drag once it moves.
    drag: ?struct { entity: ecs.EntityId, from: ui.Vec2, moving: bool = false } = null,
    /// The rows last built, to match presses to.
    rows: std.ArrayList(Row) = .empty,
    rows_arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) Hierarchy {
        return .{ .rows_arena = .init(gpa) };
    }

    pub fn deinit(self: *Hierarchy) void {
        self.rows_arena.deinit();
    }

    /// The filter typed in, for `tree.collect`.
    pub fn filterText(self: *const Hierarchy) []const u8 {
        return self.filter.text();
    }

    /// Draw the page into `context`: `rows` (from `tree.collect`, with this filter), `selected`
    /// lit. Returns what the user did this frame, if anything.
    pub fn build(self: *Hierarchy, context: *ui.Context, rows: []const Row, selected: ?ecs.EntityId) ?Action {
        var action: ?Action = null;
        self.keepRows(rows);

        // The filter, and a button to add an entity at the top level.
        context.begin(.row);
        _ = context.textInput("##filter", &self.filter, "Filter by name or component");
        page_style.restyle(context, .{ .grow = 1 });
        if (context.buttonVariant("Add", .outline)) action = .{ .spawn = null };
        context.end();
        page_style.restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center });

        if (rows.len == 0) {
            context.muted(if (self.filter.text().len > 0) "No entity matches the filter." else "No entities yet. Add one, or spawn them from your game's code.");
            page_style.smallText(context, 13);
        }

        // The rows, then (while dragging) the place to drop for the top level.
        context.begin(.column);
        for (rows) |row| if (self.rowElement(context, row, selected)) |row_action| {
            action = row_action;
        };
        if (self.drag) |drag| if (drag.moving) {
            const zone = context.builder().node(drop_zone_id, .{ .height = 30, .padding = .{ .left = 8 }, .align_items = .center, .direction = .row }, .{ .surface = .track }, &.{
                context.builder().node(0, .{}, .{ .text = .{ .value = "Drop here to move to the top level", .size = 11, .tone = .muted } }, &.{}) catch return action,
            }) catch return action;
            context.element(zone);
        };
        context.end();
        page_style.restyle(context, .{ .gap = 1 });

        if (self.menuElement(context)) |menu_action| action = menu_action;
        if (action) |chosen| if (chosen == .rename) {
            // Typed names arrive as they are typed; the row stays in rename mode.
        };
        return action;
    }

    /// Route a pointer event over the page, before the page's own UI sees it: right-clicks open
    /// the menu, double-clicks rename, and presses become drags that drop onto rows. `context`
    /// is the page's, with last frame's layout. Returns whether the event was used, and the
    /// action it led to.
    pub fn pointer(self: *Hierarchy, context: *const ui.Context, event: ui.input.Event) struct { used: bool, action: ?Action = null } {
        switch (event) {
            .pointer_down => |down| {
                const row = self.rowAt(context, down.position);
                // A press outside an open menu closes it (the menu's own items are buttons).
                if (self.menu != null and !self.onMenu(context, down.position)) self.menu = null;
                switch (down.button) {
                    .right => {
                        self.menu = .{ .at = down.position, .entity = if (row) |r| r.entity else null, .has_parent = if (row) |r| r.has_parent else false };
                        return .{ .used = true, .action = if (row) |r| Action{ .select = r.entity } else null };
                    },
                    .left => {
                        const pressed = row orelse return .{ .used = false };
                        if (down.clicks >= 2) {
                            self.startRename(pressed.entity, pressed.name);
                            return .{ .used = true };
                        }
                        self.drag = .{ .entity = pressed.entity, .from = down.position };
                    },
                    .middle => {},
                }
            },
            .pointer_move => |at| if (self.drag) |*drag| {
                if (!drag.moving and @abs(at.x - drag.from.x) + @abs(at.y - drag.from.y) > drag_threshold) drag.moving = true;
                return .{ .used = drag.moving };
            },
            .pointer_up => |up| if (up.button == .left) if (self.drag) |drag| {
                self.drag = null;
                if (!drag.moving) return .{ .used = false };
                // Onto a row: under it. Anywhere else: to the top level.
                const target: ?ecs.EntityId = if (self.rowAt(context, up.position)) |row| row.entity else null;
                if (target) |onto| if (onto.eql(drag.entity)) return .{ .used = true };
                return .{ .used = true, .action = .{ .reparent = .{ .entity = drag.entity, .parent = target } } };
            },
            else => {},
        }
        return .{ .used = false };
    }

    /// A key while the page has the keyboard: Ctrl+R renames `selected`, Delete deletes it, Escape
    /// closes the menu or stops renaming or dragging. Returns whether it was used, and the action.
    pub fn key(self: *Hierarchy, key_down: @FieldType(ui.input.Event, "key_down"), selected: ?ecs.EntityId) struct { used: bool, action: ?Action = null } {
        switch (key_down.key) {
            .escape => {
                const any = self.menu != null or self.renaming != null or self.drag != null;
                self.menu = null;
                self.renaming = null;
                self.drag = null;
                return .{ .used = any };
            },
            .enter => if (self.renaming != null) {
                self.renaming = null;
                return .{ .used = true };
            },
            // ponytail: Weeoui has no F2 key yet; Ctrl+R renames until it does.
            .r => if (key_down.modifiers.control) if (selected) |entity| if (self.renaming == null) {
                const name = for (self.rows.items) |row| {
                    if (row.entity.eql(entity)) break row.name;
                } else "";
                self.startRename(entity, name);
                return .{ .used = true };
            },
            .delete => if (selected) |entity| if (self.renaming == null) return .{ .used = true, .action = .{ .delete = entity } },
            else => {},
        }
        return .{ .used = false };
    }

    /// Rename `entity`, whose name is `name`: its row becomes a text field.
    pub fn startRename(self: *Hierarchy, entity: ecs.EntityId, name: []const u8) void {
        self.renaming = .{ .entity = entity, .edit = NameEdit.init(name) catch NameEdit.init("") catch unreachable };
        self.menu = null;
    }

    /// `row`'s element: its name and components, or a text field while it is being renamed.
    fn rowElement(self: *Hierarchy, context: *ui.Context, row: Row, selected: ?ecs.EntityId) ?Action {
        const arena = context.builder().allocator;
        const b = context.builder();
        const id = row_id_base + row.entity.id;
        const left = indent * @as(f32, @floatFromInt(@min(row.depth, max_indent_depth)));

        if (self.renaming) |*renaming| if (renaming.entity.eql(row.entity)) {
            context.begin(.row);
            const changed = context.textInput("##rename", &renaming.edit, "Name");
            const input = context.last_added;
            context.end();
            page_style.restyle(context, .{ .direction = .row, .padding = .{ .left = left } });
            // Focus the field once, then stop renaming when it loses focus.
            if (input) |field| {
                if (!renaming.started) {
                    context.focus = field.id;
                    renaming.started = true;
                } else if (context.focus != field.id) self.renaming = null;
            }
            return if (changed) .{ .rename = .{ .entity = row.entity, .name = arena.dupe(u8, renaming.edit.text()) catch return null } } else null;
        };

        const chosen = if (selected) |entity| entity.eql(row.entity) else false;
        const dragging_onto = if (self.drag) |drag| drag.moving and !drag.entity.eql(row.entity) and context.last_bounds.get(id) != null and context.last_bounds.get(id).?.rect.contains(context.pointer.x, context.pointer.y) else false;

        // The name comes first; the components fill what room is left.
        const width = @max(0, context.viewport.w - 32 - left);
        const shown_name = fitText(arena, context.font, if (row.name.len > 0) row.name else (std.fmt.allocPrint(arena, "Entity {d}", .{row.entity.id}) catch "Entity"), name_size, width - 16);
        const room = width - 16 - context.font.measure(shown_name, name_size) - 12;
        const summary = summarize(arena, context.font, row.components, room);

        const item = b.node(id, .{ .height = 26, .grow = 1 }, .{ .menu_item = .{ .label = shown_name, .shortcut = summary, .hot = chosen or dragging_onto, .size = .sm } }, &.{}) catch return null;
        item.cursor = .pointer;
        item.accessibility = .{ .role = .menu_item, .label = shown_name };
        const holder = b.node(0, .{ .direction = .row, .padding = .{ .left = left } }, .none, &.{item}) catch return null;
        context.element(holder);
        if (context.activated(id) and !(self.drag != null and self.drag.?.moving)) return .{ .select = row.entity };
        return null;
    }

    /// The right-click menu, if open, and what was picked from it.
    fn menuElement(self: *Hierarchy, context: *ui.Context) ?Action {
        const menu = self.menu orelse return null;
        var choices: std.ArrayList(ui.widgets.Choice) = .empty;
        const arena = context.builder().allocator;
        if (menu.entity != null) {
            choices.appendSlice(arena, &.{
                .{ .id = menuId(.rename), .label = "Rename" },
                .{ .id = menuId(.add_child), .label = "Add child" },
                .{ .id = menuId(.duplicate), .label = "Duplicate" },
            }) catch return null;
            if (menu.has_parent) choices.append(arena, .{ .id = menuId(.to_top), .label = "Move to top level" }) catch return null;
            choices.append(arena, .{ .id = menuId(.delete), .label = "Delete" }) catch return null;
        } else choices.append(arena, .{ .id = menuId(.add_entity), .label = "Add entity" }) catch return null;

        // Kept inside the page: it opens left of or above the pointer near an edge.
        const width: f32 = 200;
        const height = 8 + 32 * @as(f32, @floatFromInt(choices.items.len));
        const at = ui.Vec2{
            .x = @max(context.viewport.x, @min(menu.at.x, context.viewport.x + context.viewport.w - width)),
            .y = @max(context.viewport.y, @min(menu.at.y, context.viewport.y + context.viewport.h - height)),
        };
        const popup = (ui.widgets.contextMenu(context.builder(), at, choices.items, 0) catch return null) orelse return null;
        popup.style.width = width;
        context.element(popup);

        for (choices.items) |choice| if (context.activated(choice.id)) {
            self.menu = null;
            const entity = menu.entity;
            return switch (@as(MenuItem, @enumFromInt(choice.id - menu_id_base))) {
                .rename => blk: {
                    const name = for (self.rows.items) |row| {
                        if (row.entity.eql(entity.?)) break row.name;
                    } else "";
                    self.startRename(entity.?, name);
                    break :blk null;
                },
                .add_child => .{ .spawn = entity },
                .duplicate => .{ .duplicate = entity.? },
                .to_top => .{ .reparent = .{ .entity = entity.?, .parent = null } },
                .delete => .{ .delete = entity.? },
                .add_entity => .{ .spawn = null },
            };
        };
        return null;
    }

    fn menuId(item: MenuItem) u32 {
        return menu_id_base + @intFromEnum(item);
    }

    /// The row under `at` in last frame's layout.
    fn rowAt(self: *const Hierarchy, context: *const ui.Context, at: ui.Vec2) ?Row {
        for (self.rows.items) |row| {
            const target = context.last_bounds.get(row_id_base + row.entity.id) orelse continue;
            if (target.rect.contains(at.x, at.y)) return row;
        }
        return null;
    }

    fn onMenu(self: *const Hierarchy, context: *const ui.Context, at: ui.Vec2) bool {
        _ = self;
        inline for (std.meta.fields(MenuItem)) |item| {
            if (context.last_bounds.get(menu_id_base + item.value)) |target| if (target.rect.contains(at.x, at.y)) return true;
        }
        return false;
    }

    /// Keep a copy of `rows` for matching presses before the next build.
    fn keepRows(self: *Hierarchy, rows: []const Row) void {
        if (rows.ptr == self.rows.items.ptr) return;
        _ = self.rows_arena.reset(.retain_capacity);
        self.rows = .empty;
        const arena = self.rows_arena.allocator();
        for (rows) |row| self.rows.append(arena, .{ .entity = row.entity, .name = arena.dupe(u8, row.name) catch "", .depth = row.depth, .has_parent = row.has_parent, .components = &.{} }) catch return;
    }
};

/// `text`, cut with "..." to fit `width` at `size`. In `arena`.
fn fitText(arena: std.mem.Allocator, font: *const ui.Font, text: []const u8, size: f32, width: f32) []const u8 {
    if (font.measure(text, size) <= width) return text;
    var end = text.len;
    while (end > 0) {
        end -= 1;
        while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
        const cut = std.fmt.allocPrint(arena, "{s}...", .{text[0..end]}) catch return "";
        if (font.measure(cut, size) <= width) return cut;
    }
    return "";
}

/// As many of `names` as fit `width`, then "+N" for the rest; nothing if not even that fits.
fn summarize(arena: std.mem.Allocator, font: *const ui.Font, names: []const []const u8, width: f32) []const u8 {
    if (names.len == 0 or width <= 0) return "";
    var shown = names.len;
    while (true) : (shown -= 1) {
        var text: std.ArrayList(u8) = .empty;
        for (names[0..shown], 0..) |name, i| {
            if (i > 0) text.appendSlice(arena, ", ") catch return "";
            text.appendSlice(arena, name) catch return "";
        }
        if (shown < names.len) text.print(arena, "{s}+{d}", .{ if (shown > 0) " " else "", names.len - shown }) catch return "";
        if (font.measure(text.items, components_size) <= width) return text.items;
        if (shown == 0) return "";
    }
}

const ui_checks = @import("../ui_checks.zig");

fn buildPage(context: *ui.Context, hierarchy: *Hierarchy, rows: []const Row, width: f32) !void {
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = width, .h = 600 };
    context.newFrame(viewport);
    _ = hierarchy.build(context, rows, rows[0].entity);
    _ = try context.render();
    try ui_checks.expectFits(context.last_root.?, context.font, viewport);
}

test "long names and many components fit a narrow Hierarchy, the name first" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var hierarchy = Hierarchy.init(std.testing.allocator);
    defer hierarchy.deinit();
    const many = [_][]const u8{ "Transform", "MeshRenderer", "RigidBody", "Collider", "AudioSource", "Health", "Inventory" };
    const rows = [_]Row{
        .{ .entity = .init(0, 0), .name = "A planet with a very long name indeed, longer than any panel", .depth = 0, .has_parent = false, .components = &many },
        .{ .entity = .init(1, 0), .name = "Moon", .depth = 1, .has_parent = true, .components = &many },
        .{ .entity = .init(2, 0), .name = "", .depth = 12, .has_parent = true, .components = &.{"Orbit"} },
    };
    for ([_]f32{ 180, 260, 420, 900 }) |width| try buildPage(&context, &hierarchy, &rows, width);

    // At a comfortable width the name is whole and some components show.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const summary = summarize(arena.allocator(), context.font, &many, 200);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Transform") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "+") != null);
    try std.testing.expectEqualStrings("", summarize(arena.allocator(), context.font, &many, 5));
}

test "the right-click menu stays inside the page" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var hierarchy = Hierarchy.init(std.testing.allocator);
    defer hierarchy.deinit();
    const rows = [_]Row{.{ .entity = .init(0, 0), .name = "Sun", .depth = 0, .has_parent = false, .components = &.{} }};
    hierarchy.menu = .{ .at = .{ .x = 250, .y = 590 }, .entity = rows[0].entity, .has_parent = false };
    try buildPage(&context, &hierarchy, &rows, 260);
}
