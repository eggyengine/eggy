//! The Hierarchy panel: the world's entities as a tree (see `tree.zig`), with guide lines joining
//! children to their parent, filtered by name or component, to pick one for the Inspector. Each
//! row shows the entity's name, and its components as far as they fit beside it.
//!
//! Dragging a row moves the entity: dropped on the top or bottom quarter of another row it goes
//! before or after that row, as its sibling (a line shows where); on the middle it becomes that
//! row's child; in the space below the tree it moves to the end of the top level. While dragging,
//! the target lights up and a chip with the entity's name follows the pointer; anywhere else (or onto its own
//! children) letting go does nothing, and Escape cancels. A right-click opens a menu (rename, add
//! a child, duplicate, move to the top level, delete); a double-click on a name renames (both
//! clicks on its text, in the same spot), as does Ctrl+R, and Delete deletes.
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
    /// Move `entity` to `place`.
    move: struct { entity: ecs.EntityId, place: Place },
    duplicate: ecs.EntityId,
    copy: ecs.EntityId,
    paste: ?ecs.EntityId,
    extract: ecs.EntityId,
    toggle_collapse: ecs.EntityId,
    toggle_hidden: ecs.EntityId,
};

const NameEdit = ui.TextEdit(eggy.Name.max_len);
const FilterEdit = ui.TextEdit(64);

/// Row `entity.id` has element id `row_id_base + entity.id`, the same every frame, so presses
/// can be matched to rows by last frame's layout.
const row_id_base: u32 = 0x6E00_0000;
const top_level_id: u32 = row_id_base - 2;
const menu_id_base: u32 = row_id_base - 32;
const row_height: f32 = 24;
/// How far each level steps in; less when the tree is deep for the panel.
const indent: f32 = 16;
/// How far a press moves before it is a drag.
const drag_threshold: f32 = 5;
/// How far apart a double-click's presses can be, in points, and still rename.
const same_spot: f32 = 2;
const name_size: f32 = 12;
const components_size: f32 = 11;

const MenuItem = enum(u32) { rename, add_child, duplicate, copy, paste, extract, collapse, visibility, to_top, delete, add_entity };

/// Where an entity moves to.
pub const Place = union(enum) {
    /// Under this entity, after its children.
    into: ecs.EntityId,
    /// Beside this entity, as its sibling: just before it, or just after it.
    before: ecs.EntityId,
    after: ecs.EntityId,
    /// At the end of the top level.
    top_level,
};

/// Where a drag would drop if let go now.
const Target = union(enum) {
    /// Nowhere: letting go cancels.
    none,
    place: Place,
    /// Onto itself or one of its children, which can't be.
    blocked,
};

pub const Hierarchy = struct {
    can_paste: bool = false,
    filter: FilterEdit = FilterEdit.init("") catch unreachable,
    /// The row being renamed, and its text.
    renaming: ?struct { entity: ecs.EntityId, edit: NameEdit, started: bool = false } = null,
    /// The right-click menu: where, and for which row (none: the empty space below the rows).
    menu: ?struct { at: ui.Vec2, entity: ?ecs.EntityId, has_parent: bool, has_children: bool = false, collapsed: bool = false, self_hidden: bool = false } = null,
    /// A press on a row, which becomes a drag once it moves, and where it would drop.
    drag: ?struct { entity: ecs.EntityId, from: ui.Vec2, moving: bool = false, target: Target = .none } = null,
    /// The rows last built, to match presses to.
    rows: std.ArrayList(Row) = .empty,
    rows_arena: std.heap.ArenaAllocator,
    /// Where each row's name was drawn in the last build, for double-clicks to rename.
    names: std.ArrayList(NameSpan) = .empty,
    /// The last press on a name: the second of a double-click must land in the same spot.
    name_press: ?struct { entity: ecs.EntityId, at: ui.Vec2 } = null,

    /// A row's name: how far right of the row it starts, and how wide it is.
    const NameSpan = struct { entity: ecs.EntityId, left: f32, width: f32 };

    /// Create editor hierarchy state, allocating rows later with `gpa`; pair with `deinit`.
    ///
    /// ```zig
    /// var hierarchy = Hierarchy.init(gpa); // Existing allocator.
    /// defer hierarchy.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator) Hierarchy {
        return .{ .rows_arena = .init(gpa) };
    }

    /// Release copied editor rows/names once; invalidate borrowed row and drag-label text.
    ///
    /// ```zig
    /// var hierarchy = Hierarchy.init(gpa); // Existing allocator.
    /// defer hierarchy.deinit();
    /// ```
    pub fn deinit(self: *Hierarchy) void {
        self.names.deinit(self.rows_arena.child_allocator);
        self.rows_arena.deinit();
    }

    /// The filter typed in, for `tree.collect`.
    /// Editor-only: the returned text borrows the edit buffer until input changes.
    ///
    /// ```zig
    /// const query = hierarchy.filterText(); // Existing Hierarchy.
    /// ```
    pub fn filterText(self: *const Hierarchy) []const u8 {
        return self.filter.text();
    }

    /// Draw the page into `context`: `rows` (from `tree.collect`, with this filter), `selected`
    /// lit. Returns what the user did this frame, if anything.
    /// Editor-only: call during UI construction; copies rows for subsequent pointer routing.
    /// It never changes the world. Action rename text lives in the UI frame arena; dispatch
    /// before resetting it. Allocation failures can produce incomplete UI or no action.
    ///
    /// ```zig
    /// // Given hierarchy, building context, collected rows and optional selection:
    /// const action = hierarchy.build(context, rows, selected);
    /// ```
    pub fn build(self: *Hierarchy, context: *ui.Context, rows: []const Row, selected: ?ecs.EntityId) ?Action {
        var action: ?Action = null;
        self.keepRows(rows);
        self.names.clearRetainingCapacity();
        const b = context.builder();

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

        // The rows, each drawn with its guide lines.
        const step = self.indentFor(context, rows);
        context.begin(.column);
        for (rows) |row| if (self.rowElement(context, row, selected, step)) |row_action| {
            action = row_action;
        };
        context.end();
        page_style.restyle(context, .{ .gap = 0 });
        page_style.passThrough(context);

        // While dragging: the space below the tree is the top level.
        if (self.drag) |drag| if (drag.moving) {
            const over_top = drag.target == .place and drag.target.place == .top_level;
            const zone = b.node(top_level_id, .{ .height = 32, .padding = .{ .left = 10, .right = 10 }, .align_items = .center, .direction = .row }, .{ .surface = if (over_top) .card else .track }, &.{
                b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = "Drop here to move to the top level", .size = 11, .tone = if (over_top) .foreground else .muted, .wrap = true } }, &.{}) catch return action,
            }) catch return action;
            context.element(zone);
        };

        if (self.menuElement(context)) |menu_action| action = menu_action;
        return action;
    }

    /// Route a pointer event over the page, before the page's own UI sees it: right-clicks open
    /// the menu, double-clicks rename, and presses become drags. `context` is the page's, with
    /// last frame's layout. Returns whether the event was used, and the action it led to.
    /// Editor-only: event positions use that context's UI coordinate space. Mutates drag/menu
    /// state but not the ECS world; the host must apply returned select/move actions.
    ///
    /// ```zig
    /// // Given hierarchy, its last-layout context and a UI event:
    /// const handled = hierarchy.pointer(context, event);
    /// ```
    pub fn pointer(self: *Hierarchy, context: *const ui.Context, event: ui.input.Event) struct { used: bool, action: ?Action = null } {
        switch (event) {
            .pointer_down => |down| {
                if (self.menu != null and self.onMenu(context, down.position)) return .{ .used = false };
                const row = self.rowAt(context, down.position);
                // A press outside an open menu closes it (the menu's own items are buttons).
                if (self.menu != null and !self.onMenu(context, down.position)) self.menu = null;
                switch (down.button) {
                    .right => {
                        self.menu = .{
                            .at = down.position,
                            .entity = if (row) |r| r.entity else null,
                            .has_parent = if (row) |r| r.has_parent else false,
                            .has_children = if (row) |r| r.has_children else false,
                            .collapsed = if (row) |r| r.collapsed else false,
                            .self_hidden = if (row) |r| r.self_hidden else false,
                        };
                        return .{ .used = true, .action = if (row) |r| Action{ .select = r.entity } else null };
                    },
                    .left => {
                        const pressed = row orelse return .{ .used = false };
                        const bounds = context.last_bounds.get(row_id_base + pressed.entity.id).?.rect;
                        if (down.position.x >= bounds.x + bounds.w - 26) {
                            return .{ .used = true, .action = .{ .toggle_hidden = pressed.entity } };
                        }
                        if (pressed.has_children) for (self.names.items) |span| {
                            if (!span.entity.eql(pressed.entity)) continue;
                            const left = bounds.x + span.left - 22;
                            if (down.position.x >= left and down.position.x < left + 18)
                                return .{ .used = true, .action = .{ .toggle_collapse = pressed.entity } };
                        };
                        // A rename takes both clicks on the name's text, in the same spot.
                        const on_name = self.onName(context, pressed.entity, down.position);
                        const first = self.name_press;
                        self.name_press = if (on_name) .{ .entity = pressed.entity, .at = down.position } else null;
                        if (down.clicks >= 2 and on_name) if (first) |earlier| if (earlier.entity.eql(pressed.entity) and distance(earlier.at, down.position) <= same_spot) {
                            self.name_press = null;
                            self.startRename(pressed.entity, pressed.name);
                            return .{ .used = true };
                        };
                        self.drag = .{ .entity = pressed.entity, .from = down.position };
                    },
                    .middle => {},
                }
            },
            .pointer_move => |at| if (self.drag) |*drag| {
                if (!drag.moving and @abs(at.x - drag.from.x) + @abs(at.y - drag.from.y) > drag_threshold) drag.moving = true;
                if (!drag.moving) return .{ .used = false };
                drag.target = self.targetAt(context, drag.entity, at);
                return .{ .used = true };
            },
            .pointer_up => |up| if (up.button == .left) if (self.drag) |drag| {
                self.drag = null;
                if (!drag.moving) return .{ .used = false };
                const place = switch (self.targetAt(context, drag.entity, up.position)) {
                    .place => |place| place,
                    .none, .blocked => return .{ .used = true },
                };
                return .{ .used = true, .action = .{ .move = .{ .entity = drag.entity, .place = place } } };
            },
            else => {},
        }
        return .{ .used = false };
    }

    /// A key while the page has the keyboard: Ctrl+R renames `selected`, Delete deletes it,
    /// Escape closes the menu or stops renaming or dragging. Returns whether it was used, and
    /// the action.
    /// Editor-only: the host applies returned actions; Enter merely ends an ongoing live
    /// rename, while Escape clears transient interactions without changing the world.
    ///
    /// ```zig
    /// // Given hierarchy, key_down payload and optional selected id:
    /// const handled = hierarchy.key(key_down, selected);
    /// ```
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
                self.startRename(entity, self.nameOf(entity));
                return .{ .used = true };
            },
            .c => if (key_down.modifiers.control and self.renaming == null) if (selected) |entity| {
                return .{ .used = true, .action = .{ .copy = entity } };
            },
            .v => if (key_down.modifiers.control and self.renaming == null and self.can_paste) {
                return .{ .used = true, .action = .{ .paste = selected } };
            },
            .delete => if (selected) |entity| if (self.renaming == null) return .{ .used = true, .action = .{ .delete = entity } },
            else => {},
        }
        return .{ .used = false };
    }

    /// Rename `entity`, whose name is `name`: its row becomes a text field.
    /// Editor-only: copies `name`, falling back to empty when it exceeds the edit capacity;
    /// closes the menu but does not immediately write a Name component.
    ///
    /// ```zig
    /// // Given hierarchy and an entity shown in it:
    /// hierarchy.startRename(entity, hierarchy.nameOf(entity));
    /// ```
    pub fn startRename(self: *Hierarchy, entity: ecs.EntityId, name: []const u8) void {
        self.renaming = .{ .entity = entity, .edit = NameEdit.init(name) catch NameEdit.init("") catch unreachable };
        self.menu = null;
    }

    /// How far each level steps in: `indent`, less when the deepest row would leave its name
    /// less than two thirds of the panel.
    fn indentFor(_: *const Hierarchy, context: *const ui.Context, rows: []const Row) f32 {
        var deepest: usize = 0;
        for (rows) |row| deepest = @max(deepest, row.depth);
        if (deepest == 0) return indent;
        const room = context.contentWidth() / 3;
        return @min(indent, room / @as(f32, @floatFromInt(deepest)));
    }

    /// `row`'s element: guides, name and components, or a text field while it is renamed.
    fn rowElement(self: *Hierarchy, context: *ui.Context, row: Row, selected: ?ecs.EntityId, step: f32) ?Action {
        const arena = context.builder().allocator;
        const b = context.builder();
        const id = row_id_base + row.entity.id;
        const left = step * @as(f32, @floatFromInt(row.depth));

        if (self.renaming) |*renaming| if (renaming.entity.eql(row.entity)) {
            context.begin(.row);
            const changed = context.textInput("##rename", &renaming.edit, "Name");
            // Only as wide as the name, so a press beside it lands on the panel, not the field.
            page_style.fitFieldToText(context, renaming.edit.text(), context.contentWidth() - left - 4);
            const input = context.last_added;
            context.end();
            page_style.restyle(context, .{ .direction = .row, .padding = .{ .left = left + 4 } });
            // Focus the field once, then stop renaming when it loses focus.
            if (input) |field| {
                if (!renaming.started) {
                    context.focus = field.id;
                    renaming.started = true;
                } else if (context.focus != field.id) self.renaming = null;
            }
            return if (changed) .{ .rename = .{ .entity = row.entity, .name = arena.dupe(u8, renaming.edit.text()) catch return null } } else null;
        };

        // The name comes first; the components fill what room is left.
        const width = context.contentWidth();
        const text_left = left + 24;
        const name = page_style.fitText(arena, context.font, if (row.name.len > 0) row.name else (std.fmt.allocPrint(arena, "Entity {d}", .{row.entity.id}) catch "Entity"), name_size, width - text_left - 30);
        const name_width = context.font.measure(name, name_size);
        const room = width - text_left - name_width - 42;
        self.names.append(self.rows_arena.child_allocator, .{ .entity = row.entity, .left = text_left, .width = name_width }) catch {};
        const paint = arena.create(RowPaint) catch return null;
        paint.* = .{
            .id = id,
            .name = name,
            .unnamed = row.name.len == 0,
            .summary = summarize(arena, context.font, row.components, room),
            .depth = row.depth,
            .step = step,
            .last = row.last,
            .lines = row.lines,
            .selected = if (selected) |entity| entity.eql(row.entity) else false,
            .drop = if (self.drag) |drag| if (drag.moving) dropOn(drag.target, row.entity) else .none else .none,
            .dragged = if (self.drag) |drag| drag.moving and drag.entity.eql(row.entity) else false,
            .has_children = row.has_children,
            .collapsed = row.collapsed,
            .hidden = row.hidden,
            .self_hidden = row.self_hidden,
        };
        const element = b.node(id, .{ .height = row_height }, .{ .custom = .{ .context = paint, .draw = RowPaint.draw } }, &.{}) catch return null;
        element.cursor = .pointer;
        element.accessibility = .{ .role = .menu_item, .label = name };
        context.element(element);
        if (context.activated(id) and !(self.drag != null and self.drag.?.moving)) return .{ .select = row.entity };
        return null;
    }

    /// The chip that follows the pointer while dragging: the entity's name, or why letting go
    /// here won't move it. Null while nothing is dragged. In `arena`.
    /// Editor-only: existing names borrow copied rows until the next build; fallback names
    /// live in `arena`, and blocked/error captions are static.
    ///
    /// ```zig
    /// // Given hierarchy, a frame arena allocator and building context:
    /// if (hierarchy.dragLabel(arena)) |label| context.text(label);
    /// ```
    pub fn dragLabel(self: *const Hierarchy, arena: std.mem.Allocator) ?[]const u8 {
        const drag = self.drag orelse return null;
        if (!drag.moving) return null;
        if (drag.target == .blocked) return "Can't go inside itself";
        const name = self.nameOf(drag.entity);
        return if (name.len > 0) name else std.fmt.allocPrint(arena, "Entity {d}", .{drag.entity.id}) catch "Entity";
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
                .{ .id = menuId(.copy), .label = "Copy tree" },
            }) catch return null;
            if (self.can_paste) choices.append(arena, .{ .id = menuId(.paste), .label = "Paste tree" }) catch return null;
            choices.append(arena, .{ .id = menuId(.extract), .label = "Extract tree to scene" }) catch return null;
            if (menu.has_children) choices.append(arena, .{ .id = menuId(.collapse), .label = if (menu.collapsed) "Expand children" else "Collapse children" }) catch return null;
            choices.append(arena, .{ .id = menuId(.visibility), .label = if (menu.self_hidden) "Show in editor" else "Hide in editor" }) catch return null;
            if (menu.has_parent) choices.append(arena, .{ .id = menuId(.to_top), .label = "Move to top level" }) catch return null;
            choices.append(arena, .{ .id = menuId(.delete), .label = "Delete" }) catch return null;
        } else {
            choices.append(arena, .{ .id = menuId(.add_entity), .label = "Add entity" }) catch return null;
            if (self.can_paste) choices.append(arena, .{ .id = menuId(.paste), .label = "Paste tree" }) catch return null;
        }

        // Kept inside the page: it opens left of or above the pointer near an edge.
        const width: f32 = @min(200, context.viewport.w);
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
                    self.startRename(entity.?, self.nameOf(entity.?));
                    break :blk null;
                },
                .add_child => .{ .spawn = entity },
                .duplicate => .{ .duplicate = entity.? },
                .copy => .{ .copy = entity.? },
                .paste => .{ .paste = entity },
                .extract => .{ .extract = entity.? },
                .collapse => .{ .toggle_collapse = entity.? },
                .visibility => .{ .toggle_hidden = entity.? },
                .to_top => .{ .move = .{ .entity = entity.?, .place = .top_level } },
                .delete => .{ .delete = entity.? },
                .add_entity => .{ .spawn = null },
            };
        };
        return null;
    }

    fn menuId(item: MenuItem) u32 {
        return menu_id_base + @intFromEnum(item);
    }

    /// Where a drag of `dragged` would drop with the pointer at `at`: beside the row there (its
    /// top or bottom quarter) or into it (the middle), unless that row is the dragged one or
    /// below it; the top level below the tree; else nowhere.
    fn targetAt(self: *const Hierarchy, context: *const ui.Context, dragged: ecs.EntityId, at: ui.Vec2) Target {
        if (self.rowAt(context, at)) |row| {
            if (row.entity.eql(dragged)) return .none;
            if (self.isWithin(row.entity, dragged)) return .blocked;
            const bounds = context.last_bounds.get(row_id_base + row.entity.id).?.rect;
            const along = (at.y - bounds.y) / bounds.h;
            return .{ .place = if (along < 0.25) .{ .before = row.entity } else if (along > 0.75) .{ .after = row.entity } else .{ .into = row.entity } };
        }
        if (context.last_bounds.get(top_level_id)) |zone| if (zone.rect.contains(at.x, at.y)) return .{ .place = .top_level };
        // Below the last row, inside the page, counts as the top level too.
        const last = if (self.rows.items.len > 0) context.last_bounds.get(row_id_base + self.rows.items[self.rows.items.len - 1].entity.id) else null;
        if (last) |row| if (at.y > row.rect.y + row.rect.h and context.viewport.contains(at.x, at.y)) return .{ .place = .top_level };
        return .none;
    }

    /// Whether `entity` is `ancestor` or below it, by the rows' order and depths.
    fn isWithin(self: *const Hierarchy, entity: ecs.EntityId, ancestor: ecs.EntityId) bool {
        const rows = self.rows.items;
        const start = for (rows, 0..) |row, i| {
            if (row.entity.eql(ancestor)) break i;
        } else return false;
        if (rows[start].entity.eql(entity)) return true;
        for (rows[start + 1 ..]) |row| {
            if (row.depth <= rows[start].depth) return false;
            if (row.entity.eql(entity)) return true;
        }
        return false;
    }

    /// `entity`'s name as last shown; empty when it has none.
    /// Editor-only: also empty for an unlisted entity; text borrows rows until the next build.
    ///
    /// ```zig
    /// const name = hierarchy.nameOf(entity); // Existing hierarchy and entity id.
    /// ```
    pub fn nameOf(self: *const Hierarchy, entity: ecs.EntityId) []const u8 {
        for (self.rows.items) |row| if (row.entity.eql(entity)) return row.name;
        return "";
    }

    /// The row under `at` in last frame's layout.
    /// Whether `at` is on `entity`'s name as last drawn.
    fn onName(self: *const Hierarchy, context: *const ui.Context, entity: ecs.EntityId, at: ui.Vec2) bool {
        const row = context.last_bounds.get(row_id_base + entity.id) orelse return false;
        for (self.names.items) |span| if (span.entity.eql(entity)) {
            return row.rect.contains(at.x, at.y) and at.x >= row.rect.x + span.left and at.x <= row.rect.x + span.left + span.width;
        };
        return false;
    }

    /// The entity whose row is under `at` in last frame's layout.
    /// Editor-only: `at` is in the context's UI coordinates; null means no retained row hit.
    ///
    /// ```zig
    /// // Given hierarchy, its last-layout context and pointer position:
    /// const entity = hierarchy.entityAt(context, at);
    /// ```
    pub fn entityAt(self: *const Hierarchy, context: *const ui.Context, at: ui.Vec2) ?ecs.EntityId {
        return if (self.rowAt(context, at)) |row| row.entity else null;
    }

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
        for (rows) |row| {
            var kept = row;
            kept.name = arena.dupe(u8, row.name) catch "";
            kept.components = &.{};
            kept.lines = &.{};
            self.rows.append(arena, kept) catch return;
        }
    }
};

fn distance(a: ui.Vec2, b: ui.Vec2) f32 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

/// What a drag shows on a row it would drop on: an outline (into it) or a line above or below.
const Drop = enum { none, into, before, after };

fn dropOn(target: Target, entity: ecs.EntityId) Drop {
    if (target != .place) return .none;
    return switch (target.place) {
        .into => |other| if (other.eql(entity)) .into else .none,
        .before => |other| if (other.eql(entity)) .before else .none,
        .after => |other| if (other.eql(entity)) .after else .none,
        .top_level => .none,
    };
}

/// How a row is drawn: guide lines, highlight, name, and components.
const RowPaint = struct {
    id: u32,
    name: []const u8,
    unnamed: bool,
    summary: []const u8,
    depth: usize,
    step: f32,
    last: bool,
    lines: []const bool,
    selected: bool,
    drop: Drop,
    dragged: bool,
    has_children: bool,
    collapsed: bool,
    hidden: bool,
    self_hidden: bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const RowPaint = @ptrCast(@alignCast(context));
        const t = c.theme;
        const left = r.x + self.step * @as(f32, @floatFromInt(self.depth));

        // The highlight starts where the row's own content does, right of the guides.
        const body = ui.Rect{ .x = left + 2, .y = r.y + 1, .w = @max(0, r.x + r.w - left - 2), .h = r.h - 2 };
        if (self.selected) {
            try c.roundRect(body, t.accent, t.radiusSm());
        } else if (c.hot_id == self.id) try c.roundRectAlpha(body, t.accent, t.radiusSm(), 0.5);
        switch (self.drop) {
            .none => {},
            .into => try c.roundRectStroke(body, t.primary, t.radiusSm(), 1.5),
            .before => try c.rect(.{ .x = left, .y = r.y, .w = body.w, .h = 2 }, t.primary),
            .after => try c.rect(.{ .x = left, .y = r.y + r.h - 2, .w = body.w, .h = 2 }, t.primary),
        }

        // Guides: a line down each open level above, and an elbow into this row.
        const guide = t.border;
        const mid_y = r.y + r.h / 2;
        for (0..self.depth) |level| {
            const x = r.x + self.step * @as(f32, @floatFromInt(level)) + self.step / 2;
            if (level + 1 < self.depth) {
                if (self.lines[level]) try c.rect(.{ .x = x, .y = r.y, .w = 1, .h = r.h }, guide);
            } else {
                try c.rect(.{ .x = x, .y = r.y, .w = 1, .h = if (self.last) r.h / 2 else r.h }, guide);
                try c.rect(.{ .x = x, .y = mid_y, .w = @max(0, left - x + 2), .h = 1 }, guide);
            }
        }

        // The name, dimmed while it is being dragged or has none, and the components right.
        const text_left = left + 24;
        const name_color = if (self.dragged or self.unnamed or self.hidden) t.muted_foreground else if (self.selected) t.accent_foreground else t.foreground;
        if (self.has_children) try c.icon(.{ .x = left + 4, .y = mid_y - 6, .w = 12, .h = 12 }, if (self.collapsed) .chevron_right else .chevron_down, name_color);
        try drawEye(c, .{ .x = r.x + r.w - 22, .y = mid_y - 5, .w = 16, .h = 10 }, self.hidden, if (self.self_hidden) t.muted_foreground else name_color);
        try c.textIn(.{ .x = text_left, .y = r.y, .w = @max(0, r.x + r.w - text_left - 30), .h = r.h }, self.name, name_size, name_color, .start);
        if (self.summary.len > 0) {
            const width = c.font.measure(self.summary, components_size);
            try c.textIn(.{ .x = r.x + r.w - 30 - width, .y = r.y, .w = width, .h = r.h }, self.summary, components_size, t.muted_foreground, .end);
        }
    }
};

fn drawEye(c: *ui.Canvas, r: ui.Rect, hidden: bool, color: ui.Color) !void {
    try c.roundRectStroke(r, color, 5, 1);
    try c.roundRect(.{ .x = r.x + 6, .y = r.y + 3, .w = 4, .h = 4 }, color, 2);
    if (hidden) {
        const rgba: [4]f32 = .{ color[0], color[1], color[2], 1 };
        try c.triangle(.{ .{ r.x, r.y - 1 }, .{ r.x + 2, r.y - 1 }, .{ r.x + r.w, r.y + r.h + 1 } }, @splat(rgba));
        try c.triangle(.{ .{ r.x, r.y - 1 }, .{ r.x + r.w, r.y + r.h + 1 }, .{ r.x + r.w - 2, r.y + r.h + 1 } }, @splat(rgba));
    }
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
    // Each row's own text fits beside its guides.
    for (rows) |row| {
        const element = context.last_root.?.find(row_id_base + row.entity.id) orelse continue;
        const paint: *const RowPaint = @ptrCast(@alignCast(element.paint_kind.custom.context));
        const text_left = paint.step * @as(f32, @floatFromInt(paint.depth)) + 24;
        const used = text_left + context.font.measure(paint.name, name_size) + 30 + (if (paint.summary.len > 0) context.font.measure(paint.summary, components_size) + 12 else 0);
        if (used > element.bounds.w + 0.5) {
            std.debug.print("row {s} needs {d:.1} of {d:.1}\n", .{ paint.name, used, element.bounds.w });
            return error.TextOverflows;
        }
    }
}

test "long names, deep trees and many components fit a narrow Hierarchy, the name first" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var hierarchy = Hierarchy.init(std.testing.allocator);
    defer hierarchy.deinit();
    const many = [_][]const u8{ "Transform", "MeshRenderer", "RigidBody", "Collider", "AudioSource", "Health", "Inventory" };
    const rows = [_]Row{
        .{ .entity = .init(0, 0), .name = "A planet with a very long name indeed, longer than any panel", .depth = 0, .has_parent = false, .components = &many, .last = true },
        .{ .entity = .init(1, 0), .name = "Moon", .depth = 1, .has_parent = true, .components = &many, .lines = &.{false} },
        .{ .entity = .init(2, 0), .name = "", .depth = 12, .has_parent = true, .components = &.{"Orbit"}, .lines = &(.{true} ** 12) },
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

test "the right-click menu and the drag label stay inside the page" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var hierarchy = Hierarchy.init(std.testing.allocator);
    defer hierarchy.deinit();
    const rows = [_]Row{.{ .entity = .init(0, 0), .name = "Sun", .depth = 0, .has_parent = false, .components = &.{} }};
    hierarchy.menu = .{ .at = .{ .x = 250, .y = 590 }, .entity = rows[0].entity, .has_parent = false };
    try buildPage(&context, &hierarchy, &rows, 260);
    hierarchy.menu = null;
    hierarchy.drag = .{ .entity = rows[0].entity, .from = .{ .x = 0, .y = 0 }, .moving = true, .target = .{ .place = .top_level } };
    context.pointer = .{ .x = 250, .y = 100 };
    try buildPage(&context, &hierarchy, &rows, 260);
}

test "clipboard shortcuts leave renaming alone" {
    var hierarchy = Hierarchy.init(std.testing.allocator);
    defer hierarchy.deinit();
    const entity = ecs.EntityId.init(3, 2);
    const copy = hierarchy.key(.{ .key = .c, .modifiers = .{ .control = true }, .repeat = false }, entity);
    try std.testing.expect(copy.action.?.copy.eql(entity));
    hierarchy.can_paste = true;
    const paste = hierarchy.key(.{ .key = .v, .modifiers = .{ .control = true }, .repeat = false }, entity);
    try std.testing.expect(paste.action.?.paste.?.eql(entity));
    hierarchy.startRename(entity, "Name");
    try std.testing.expect(!hierarchy.key(.{ .key = .c, .modifiers = .{ .control = true }, .repeat = false }, entity).used);
    try std.testing.expect(!hierarchy.key(.{ .key = .v, .modifiers = .{ .control = true }, .repeat = false }, entity).used);
}

test "fold and eye hits are independent of selecting or dragging a row" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var hierarchy = Hierarchy.init(std.testing.allocator);
    defer hierarchy.deinit();
    const entity = ecs.EntityId.init(0, 0);
    const rows = [_]Row{.{ .entity = entity, .name = "Root", .depth = 0, .has_parent = false, .has_children = true, .components = &.{} }};
    try buildPage(&context, &hierarchy, &rows, 260);
    const bounds = context.last_bounds.get(row_id_base).?.rect;
    const folded = hierarchy.pointer(&context, .{ .pointer_down = .{
        .button = .left,
        .position = .{ .x = bounds.x + 8, .y = bounds.y + bounds.h / 2 },
        .clicks = 1,
    } });
    try std.testing.expect(folded.used);
    try std.testing.expect(folded.action.?.toggle_collapse.eql(entity));
    const hidden = hierarchy.pointer(&context, .{ .pointer_down = .{
        .button = .left,
        .position = .{ .x = bounds.x + bounds.w - 10, .y = bounds.y + bounds.h / 2 },
        .clicks = 1,
    } });
    try std.testing.expect(hidden.used);
    try std.testing.expect(hidden.action.?.toggle_hidden.eql(entity));
    try std.testing.expect(hierarchy.drag == null);
}

test "popup choices take precedence over the row controls behind them" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var hierarchy = Hierarchy.init(std.testing.allocator);
    defer hierarchy.deinit();
    const entity = ecs.EntityId.init(0, 0);
    const rows = [_]Row{.{ .entity = entity, .name = "Root", .depth = 0, .has_parent = false, .has_children = true, .components = &.{} }};
    try buildPage(&context, &hierarchy, &rows, 260);
    const bounds = context.last_bounds.get(row_id_base).?.rect;
    hierarchy.menu = .{ .at = .{ .x = 260, .y = bounds.y }, .entity = entity, .has_parent = false };
    try buildPage(&context, &hierarchy, &rows, 260);
    const choice = context.last_bounds.get(Hierarchy.menuId(.rename)).?.rect;
    const at = ui.Vec2{ .x = bounds.x + bounds.w - 10, .y = bounds.y + bounds.h / 2 };
    try std.testing.expect(choice.contains(at.x, at.y));
    const result = hierarchy.pointer(&context, .{ .pointer_down = .{ .position = at, .button = .left, .clicks = 1 } });
    try std.testing.expect(!result.used);
    try std.testing.expect(result.action == null);
    try std.testing.expect(hierarchy.drag == null);
}

test "a drag can't drop an entity into itself or its children" {
    var hierarchy = Hierarchy.init(std.testing.allocator);
    defer hierarchy.deinit();
    const rows = [_]Row{
        .{ .entity = .init(0, 0), .name = "Sun", .depth = 0, .has_parent = false, .components = &.{} },
        .{ .entity = .init(1, 0), .name = "Earth", .depth = 1, .has_parent = true, .components = &.{} },
        .{ .entity = .init(2, 0), .name = "Moon", .depth = 2, .has_parent = true, .components = &.{} },
        .{ .entity = .init(3, 0), .name = "Comet", .depth = 0, .has_parent = false, .components = &.{} },
    };
    hierarchy.keepRows(&rows);
    try std.testing.expect(hierarchy.isWithin(rows[2].entity, rows[1].entity));
    try std.testing.expect(hierarchy.isWithin(rows[1].entity, rows[1].entity));
    try std.testing.expect(!hierarchy.isWithin(rows[3].entity, rows[0].entity));
    try std.testing.expect(!hierarchy.isWithin(rows[0].entity, rows[1].entity));
}

test "a row's top and bottom quarters drop beside it, the middle into it" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var hierarchy = Hierarchy.init(std.testing.allocator);
    defer hierarchy.deinit();
    const rows = [_]Row{
        .{ .entity = .init(0, 0), .name = "Sun", .depth = 0, .has_parent = false, .components = &.{} },
        .{ .entity = .init(1, 0), .name = "Comet", .depth = 0, .has_parent = false, .components = &.{} },
    };
    try buildPage(&context, &hierarchy, &rows, 300);
    const sun = context.last_bounds.get(row_id_base + 0).?.rect;
    const dragged = rows[1].entity;
    const at = struct {
        fn y(rect: ui.Rect, along: f32) ui.Vec2 {
            return .{ .x = rect.x + 20, .y = rect.y + rect.h * along };
        }
    }.y;
    try std.testing.expectEqual(rows[0].entity, hierarchy.targetAt(&context, dragged, at(sun, 0.1)).place.before);
    try std.testing.expectEqual(rows[0].entity, hierarchy.targetAt(&context, dragged, at(sun, 0.5)).place.into);
    try std.testing.expectEqual(rows[0].entity, hierarchy.targetAt(&context, dragged, at(sun, 0.9)).place.after);
    // Onto itself: nowhere.
    try std.testing.expect(hierarchy.targetAt(&context, rows[0].entity, at(sun, 0.5)) == .none);
}

test "a double-click renames only with both clicks on the name, in the same spot" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var hierarchy = Hierarchy.init(std.testing.allocator);
    defer hierarchy.deinit();
    const rows = [_]Row{.{ .entity = .init(0, 0), .name = "Sun", .depth = 0, .has_parent = false, .components = &.{} }};
    try buildPage(&context, &hierarchy, &rows, 300);
    const row = context.last_bounds.get(row_id_base + 0).?.rect;
    const on_name = ui.Vec2{ .x = row.x + 28, .y = row.y + row.h / 2 };
    const beside_name = ui.Vec2{ .x = row.x + row.w - 40, .y = on_name.y };
    const click = struct {
        fn f(h: *Hierarchy, c: *const ui.Context, at: ui.Vec2, clicks: u8) void {
            _ = h.pointer(c, .{ .pointer_down = .{ .position = at, .button = .left, .clicks = clicks } });
            _ = h.pointer(c, .{ .pointer_up = .{ .position = at, .button = .left } });
        }
    }.f;

    // Beside the name, on the row: no rename.
    click(&hierarchy, &context, beside_name, 1);
    click(&hierarchy, &context, beside_name, 2);
    try std.testing.expect(hierarchy.renaming == null);
    // On the name, but the second click elsewhere on it: no rename.
    click(&hierarchy, &context, on_name, 1);
    click(&hierarchy, &context, .{ .x = on_name.x + 6, .y = on_name.y }, 2);
    try std.testing.expect(hierarchy.renaming == null);
    // Both on the name, in the same spot: rename.
    click(&hierarchy, &context, on_name, 1);
    click(&hierarchy, &context, on_name, 2);
    try std.testing.expect(hierarchy.renaming != null);
}

test "the only row takes a click, as any row does" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var hierarchy = Hierarchy.init(std.testing.allocator);
    defer hierarchy.deinit();
    const rows = [_]Row{.{ .entity = .init(0, 0), .name = "Sun", .depth = 0, .has_parent = false, .components = &.{} }};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 300, .h = 600 };
    context.newFrame(viewport);
    _ = hierarchy.build(&context, &rows, null);
    _ = try context.render();
    const at = context.last_bounds.get(row_id_base).?.rect.center();
    context.handle(.{ .pointer_move = at });
    context.handle(.{ .pointer_down = .{ .position = at, .button = .left, .clicks = 1 } });
    context.handle(.{ .pointer_up = .{ .position = at, .button = .left } });
    context.newFrame(viewport);
    try std.testing.expectEqual(Action{ .select = rows[0].entity }, hierarchy.build(&context, &rows, null).?);
    _ = try context.render();
}
