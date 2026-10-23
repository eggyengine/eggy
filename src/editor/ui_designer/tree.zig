//! The UI Tree panel: the open UI scene's nodes on the Hierarchy's page (`entities/hierarchy.zig`),
//! each node standing in as an entity numbered by its paint order, the root first. Dragging a row
//! moves the node; Add (or a right-click's Add child) opens a menu of node kinds; the rest of the
//! right-click menu renames, duplicates, copies and pastes, hides and deletes.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ecs = eggy.ecs;
const ui_scene = eggy.assets.ui_scene;
const Node = ui_scene.Node;
const layout = eggy.ui_scenes.layout;
const hierarchy_zig = @import("../entities/hierarchy.zig");
const Hierarchy = hierarchy_zig.Hierarchy;
const entity_tree = @import("../entities/tree.zig");
const Row = entity_tree.Row;
const Document = @import("document.zig").Document;

/// The kinds of node Add makes, before the plugins' widgets, each with its Nerd Font icon
/// (Material Design, as components' icons are).
const palette = [_]struct { icon: []const u8, label: []const u8, node: Node }{
    .{ .icon = "\u{f14fc}", .label = "Panel", .node = .{ .name = "panel", .layout = .{ .width = .{ .px = 200 }, .height = .{ .px = 120 }, .padding = .{ .left = 12, .top = 12, .right = 12, .bottom = 12 }, .gap = 8 }, .look = .{ .background = .{ .theme = .card }, .radius = 8 } } },
    .{ .icon = "\u{f0284}", .label = "Text", .node = .{ .name = "text", .widget = .{ .text = .{} } } },
    .{ .icon = "\u{f0976}", .label = "Image", .node = .{ .name = "image", .widget = .{ .image = .{} }, .layout = .{ .width = .{ .px = 64 }, .height = .{ .px = 64 } } } },
    .{ .icon = "\u{f12a8}", .label = "Button", .node = .{ .name = "button", .widget = .{ .button = .{} }, .layout = .{ .padding = .{ .left = 16, .top = 8, .right = 16, .bottom = 8 } } } },
    .{ .icon = "\u{f1a03}", .label = "Progress bar", .node = .{ .name = "bar", .widget = .{ .progress = .{} }, .layout = .{ .width = .{ .px = 200 }, .height = .{ .px = 12 } } } },
    .{ .icon = "\u{f0a1d}", .label = "UI scene", .node = .{ .name = "part", .widget = .{ .scene = .{} }, .layout = .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } } } },
};

/// The kinds menu's items have ids from here, palette first, then the plugins' widgets.
const kind_id_base: u32 = 0x6D00_0000;

pub const Tree = struct {
    gpa: std.mem.Allocator,
    hierarchy: Hierarchy,
    /// Folded nodes, by paint-order index.
    // ponytail: folds are kept by paint order, so adding a node above a folded one moves the fold; key them by path if that bothers anyone.
    folded: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The node kinds menu, open after Add: the node the new one goes under, and where it opened.
    adding: ?struct { parent: u32, at: ui.Vec2 } = null,
    /// The node Copy took, with its children, in `copied_arena`.
    copied: ?Node = null,
    copied_arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) Tree {
        var hierarchy = Hierarchy.init(gpa);
        hierarchy.subject = .ui_nodes;
        return .{ .gpa = gpa, .hierarchy = hierarchy, .copied_arena = .init(gpa) };
    }

    pub fn deinit(self: *Tree) void {
        self.hierarchy.deinit();
        self.folded.deinit(self.gpa);
        self.copied_arena.deinit();
    }

    /// Draw the tree and the kinds menu; returns whether `document` changed.
    pub fn build(self: *Tree, context: *ui.Context, document: *Document, widgets: []const eggy.plugins.UiWidget) bool {
        const arena = context.builder().allocator;
        const rows = rowsOf(arena, document, &self.folded, self.hierarchy.filterText()) catch &.{};
        self.hierarchy.can_paste = self.copied != null;
        const selected = ecs.EntityId.init(layout.indexOf(&document.scene().root, document.selection()) orelse 0, 0);
        var changed = false;
        if (self.hierarchy.build(context, rows, selected)) |action| changed = self.apply(document, action, context.pointer);
        return self.kindsMenu(context, document, widgets) or changed;
    }

    /// A pointer event over the panel, before its UI sees it (see `Hierarchy.pointer`). Returns
    /// whether it was used and whether `document` changed.
    pub fn pointer(self: *Tree, context: *const ui.Context, document: *Document, event: ui.input.Event) struct { used: bool, changed: bool = false } {
        // A press anywhere but on the kinds menu closes it.
        if (event == .pointer_down) if (self.adding != null and !onKindsMenu(context, event.pointer_down.position)) {
            self.adding = null;
        };
        const result = self.hierarchy.pointer(context, event);
        const action = result.action orelse return .{ .used = result.used };
        return .{ .used = result.used, .changed = self.apply(document, action, context.pointer) };
    }

    /// A key while the panel has the keyboard (see `Hierarchy.key`).
    pub fn key(self: *Tree, document: *Document, key_down: @FieldType(ui.input.Event, "key_down"), typing: bool) struct { used: bool, changed: bool = false } {
        if (key_down.key == .escape and self.adding != null) {
            self.adding = null;
            return .{ .used = true };
        }
        if (typing and key_down.key != .escape and key_down.key != .enter) return .{ .used = false };
        const selected = ecs.EntityId.init(layout.indexOf(&document.scene().root, document.selection()) orelse 0, 0);
        const result = self.hierarchy.key(key_down, selected);
        const action = result.action orelse return .{ .used = result.used };
        return .{ .used = result.used, .changed = self.apply(document, action, .{ .x = 0, .y = 0 }) };
    }

    /// Carry out `action` on `document`; `at` is where a kinds menu opens. Returns whether the
    /// document changed.
    fn apply(self: *Tree, document: *Document, action: hierarchy_zig.Action, at: ui.Vec2) bool {
        var path_buffer: [ui_scene.max_depth]u16 = undefined;
        const root = &document.scene().root;
        switch (action) {
            .select => |node| if (layout.pathOf(root, node.id, &path_buffer)) |path| document.select(path),
            .spawn => |parent| self.adding = .{ .parent = if (parent) |node| node.id else layout.indexOf(root, document.selection()) orelse 0, .at = at },
            .toggle_collapse => |node| if (self.folded.contains(node.id)) {
                _ = self.folded.remove(node.id);
            } else self.folded.put(self.gpa, node.id, {}) catch {},
            .copy => |node| {
                const path = layout.pathOf(root, node.id, &path_buffer) orelse return false;
                _ = self.copied_arena.reset(.retain_capacity);
                const scene = (ui_scene.UiScene{ .root = ui_scene.nodeAt(root, path).?.* }).clone(self.copied_arena.allocator()) catch return false;
                self.copied = scene.root;
            },
            .extract => {},
            else => {
                const edited = self.edit(document, action) catch |err| {
                    std.log.err("cannot change the UI scene's tree: {t}", .{err});
                    return false;
                };
                return edited;
            },
        }
        return false;
    }

    /// The actions that change the document.
    fn edit(self: *Tree, document: *Document, action: hierarchy_zig.Action) !bool {
        var path_buffer: [ui_scene.max_depth]u16 = undefined;
        const root = &document.scene().root;
        switch (action) {
            .rename => |renamed| {
                const node = ui_scene.nodeAt(root, layout.pathOf(root, renamed.entity.id, &path_buffer) orelse return false).?;
                node.name = try document.arena().dupe(u8, renamed.name);
            },
            .toggle_hidden => |entity| {
                const node = ui_scene.nodeAt(root, layout.pathOf(root, entity.id, &path_buffer) orelse return false).?;
                node.visible = !node.visible;
            },
            .delete => |entity| {
                document.select(layout.pathOf(root, entity.id, &path_buffer) orelse return false);
                try document.deleteSelected();
            },
            .duplicate => |entity| {
                document.select(layout.pathOf(root, entity.id, &path_buffer) orelse return false);
                try document.duplicateSelected();
            },
            .paste => |parent| {
                const copied = self.copied orelse return false;
                if (parent) |node| document.select(layout.pathOf(root, node.id, &path_buffer) orelse return false);
                try document.addChild(try copyInto(document.arena(), copied));
            },
            .move => |move| {
                document.select(layout.pathOf(root, move.entity.id, &path_buffer) orelse return false);
                var target_buffer: [ui_scene.max_depth]u16 = undefined;
                switch (move.place) {
                    .into => |parent| {
                        const path = layout.pathOf(root, parent.id, &target_buffer) orelse return false;
                        try document.moveSelected(path, ui_scene.nodeAt(root, path).?.children.len);
                    },
                    // Beside the root is inside it, at that end.
                    .before, .after => |sibling| {
                        const path = layout.pathOf(root, sibling.id, &target_buffer) orelse return false;
                        if (path.len == 0) {
                            try document.moveSelected(&.{}, if (move.place == .before) 0 else root.children.len);
                        } else {
                            const index = path[path.len - 1] + @intFromBool(move.place == .after);
                            try document.moveSelected(path[0 .. path.len - 1], index);
                        }
                    },
                    .top_level => try document.moveSelected(&.{}, root.children.len),
                }
            },
            .select, .spawn, .toggle_collapse, .copy, .extract => return false,
        }
        return true;
    }

    /// The menu of node kinds Add opened, if open; returns whether a node was added.
    fn kindsMenu(self: *Tree, context: *ui.Context, document: *Document, widgets: []const eggy.plugins.UiWidget) bool {
        const adding = self.adding orelse return false;
        const arena = context.builder().allocator;
        var choices: std.ArrayList(ui.widgets.Choice) = .empty;
        // Each row its icon then its name; plugin widgets take the puzzle piece components without an icon have.
        for (palette, 0..) |entry, i| choices.append(arena, .{ .id = kind_id_base + @as(u32, @intCast(i)), .label = iconLabel(arena, entry.icon, entry.label) }) catch return false;
        for (widgets, palette.len..) |widget, i| choices.append(arena, .{ .id = kind_id_base + @as(u32, @intCast(i)), .label = iconLabel(arena, eggy.components.default_icon, widget.title) }) catch break;

        // Kept inside the page, as the Hierarchy's menu is.
        const width: f32 = @min(200, context.viewport.w);
        const height = 8 + 32 * @as(f32, @floatFromInt(choices.items.len));
        const at = ui.Vec2{
            .x = @max(context.viewport.x, @min(adding.at.x, context.viewport.x + context.viewport.w - width)),
            .y = @max(context.viewport.y, @min(adding.at.y, context.viewport.y + context.viewport.h - height)),
        };
        const popup = (ui.widgets.contextMenu(context.builder(), at, choices.items, 0) catch return false) orelse return false;
        popup.style.width = width;
        context.element(popup);

        for (choices.items, 0..) |choice, i| if (context.activated(choice.id)) {
            self.adding = null;
            const node: Node = if (i < palette.len) palette[i].node else .{
                .name = "widget",
                .widget = .{ .plugin = .{ .widget = widgets[i - palette.len].key } },
                .layout = .{ .width = .{ .px = 128 }, .height = .{ .px = 128 } },
            };
            var path_buffer: [ui_scene.max_depth]u16 = undefined;
            document.select(layout.pathOf(&document.scene().root, adding.parent, &path_buffer) orelse &.{});
            document.addChild(node) catch |err| {
                std.log.err("cannot add a node: {t}", .{err});
                return false;
            };
            return true;
        };
        return false;
    }
};

/// `label` after `icon`, for a menu row (allocated in `arena`; the bare label if that fails).
fn iconLabel(arena: std.mem.Allocator, icon: []const u8, label: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}  {s}", .{ icon, label }) catch label;
}

/// Whether `at` is on one of the kinds menu's items, by last frame's layout.
fn onKindsMenu(context: *const ui.Context, at: ui.Vec2) bool {
    var it = context.last_bounds.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* < kind_id_base or entry.key_ptr.* >= kind_id_base + 1024) continue;
        if (entry.value_ptr.rect.contains(at.x, at.y)) return true;
    }
    return false;
}

/// What a node shows, as the tree names its kind.
fn kindLabel(node: *const Node) []const u8 {
    return switch (node.widget) {
        .panel => "Panel",
        .text => "Text",
        .image => "Image",
        .button => "Button",
        .progress => "Progress bar",
        .scene => "UI scene",
        .plugin => "Widget",
    };
}

/// The scene's nodes as the Hierarchy's rows, folds closed unless `filter` searches, narrowed
/// by it. In `arena`.
fn rowsOf(arena: std.mem.Allocator, document: *Document, folded: *const std.AutoHashMapUnmanaged(u32, void), filter: []const u8) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    var index: u32 = 0;
    const searching = std.mem.trim(u8, filter, " ").len > 0;
    try addRows(arena, &rows, &document.scene().root, &index, 0, false, if (searching) null else folded);
    return entity_tree.narrow(arena, rows.items, filter);
}

fn addRows(arena: std.mem.Allocator, rows: *std.ArrayList(Row), node: *const Node, index: *u32, depth: usize, parent_hidden: bool, folded: ?*const std.AutoHashMapUnmanaged(u32, void)) !void {
    const own = index.*;
    index.* += 1;
    const kind = try arena.dupe([]const u8, &.{kindLabel(node)});
    const closed = node.children.len > 0 and folded != null and folded.?.contains(own);
    const hidden = parent_hidden or !node.visible;
    try rows.append(arena, .{
        .entity = .init(own, 0),
        .name = if (node.name.len > 0) node.name else kind[0],
        .depth = depth,
        // Only the root's descendants can move "into the root".
        .has_parent = depth >= 2,
        .has_children = node.children.len > 0,
        .collapsed = closed,
        .hidden = hidden,
        .self_hidden = !node.visible,
        .components = kind,
    });
    for (node.children) |*child| {
        if (closed) {
            index.* += layout.countNodes(child);
        } else try addRows(arena, rows, child, index, depth + 1, hidden, folded);
    }
}

/// `node` and its children copied into `arena`.
fn copyInto(arena: std.mem.Allocator, node: Node) !Node {
    return (try (ui_scene.UiScene{ .root = node }).clone(arena)).root;
}

test "a scene's nodes become rows in paint order, folds skipping their children's numbers" {
    const gpa = std.testing.allocator;
    var document = try Document.init(gpa, "hud.ui.zon", "", ui_scene.template);
    defer document.deinit();
    try document.addChild(.{ .name = "card", .children = &.{} });
    try document.addChild(.{ .name = "", .widget = .{ .button = .{} } });
    document.select(&.{});
    try document.addChild(.{ .name = "after" });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var folded: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer folded.deinit(gpa);
    const all = try rowsOf(arena.allocator(), &document, &folded, "");
    try std.testing.expectEqual(@as(usize, 5), all.len);
    try std.testing.expectEqualStrings("Button", all[3].name);
    try std.testing.expectEqual(@as(usize, 2), all[3].depth);

    // Folding the card hides its button but keeps "after" numbered 4.
    try folded.put(gpa, 2, {});
    const shown = try rowsOf(arena.allocator(), &document, &folded, "");
    try std.testing.expectEqual(@as(usize, 4), shown.len);
    try std.testing.expectEqual(@as(u32, 4), shown[3].entity.id);
    // A search opens folds.
    const found = try rowsOf(arena.allocator(), &document, &folded, "button");
    try std.testing.expectEqualStrings("Button", found[found.len - 1].name);
}

test "dropping a row beside the root puts the node inside it" {
    const gpa = std.testing.allocator;
    var document = try Document.init(gpa, "hud.ui.zon", "", ui_scene.template);
    defer document.deinit();
    try document.addChild(.{ .name = "late" });
    var tree = Tree.init(gpa);
    defer tree.deinit();
    // "late" (paint order 2) goes before the root: first among the root's children.
    try std.testing.expect(tree.apply(&document, .{ .move = .{ .entity = .init(2, 0), .place = .{ .before = .init(0, 0) } } }, .{ .x = 0, .y = 0 }));
    try std.testing.expectEqualStrings("late", document.scene().root.children[0].name);
}

test "every kind in the Add menu has an icon the symbols font draws" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    try context.font.setSymbolsFont(@embedFile("symbols_font"));
    const strike = context.font.strike(14);
    const missing = strike.glyph('?');
    var icons: [palette.len + 1][]const u8 = undefined;
    for (palette, icons[0..palette.len]) |entry, *icon| icon.* = entry.icon;
    icons[palette.len] = eggy.components.default_icon;
    for (icons) |icon| {
        var i: usize = 0;
        const glyph = context.font.next(strike, icon, &i);
        try std.testing.expect(!std.meta.eql(glyph, missing) and glyph.w > 0);
    }
}
