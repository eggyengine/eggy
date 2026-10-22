//! The UI Properties panel: the selected node's settings drawn as the Inspector draws a
//! component's fields (`entities/field_editor.zig`), in cards for the node, what it shows, its
//! layout and its look; with the root selected, the scene's size and theme follow. Image, font
//! and UI scene fields are slots that take a file dragged from Assets.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ui_scene = eggy.assets.ui_scene;
const Node = ui_scene.Node;
const page_style = @import("../page_style.zig");
const field_editor = @import("../entities/field_editor.zig");
const FieldEditor = field_editor.FieldEditor;
const Dragged = @import("../dragged.zig").Dragged;
const ProjectAssets = @import("../assets/project_assets.zig").ProjectAssets;
const Fields = @import("fields.zig").Fields;
const Document = @import("document.zig").Document;

/// The cards, in the order shown. A card's number keeps its fields' controls apart.
const Card = enum(u8) { node, widget, layout, look, scene, theme };

/// As the Inspector shares its width between labels and controls.
const control_share: f32 = 0.6;
const min_control_width: f32 = 80;
const max_control_width: f32 = 360;

const kind_labels = [_][]const u8{ "Panel", "Text", "Image", "Button", "Progress bar", "UI scene", "Plugin widget" };

/// What the panel draws with, borrowed for one build.
pub const Request = struct {
    widgets: []const eggy.plugins.UiWidget,
    assets: ?*ProjectAssets,
    dragging: ?Dragged,
};

pub const Properties = struct {
    gpa: std.mem.Allocator,
    values: FieldEditor,
    texts: Fields,
    folded: std.EnumSet(Card) = .initEmpty(),
    /// The node shown last, by paint order: typing and dragging stop when another is selected.
    shown: ?u32 = null,
    /// A file dropped on a slot, set on the next build: the slot's card and field, and the
    /// field's new ZON, owned.
    dropped: ?struct { card: usize, field: usize, text: []u8 } = null,

    pub fn init(gpa: std.mem.Allocator) Properties {
        return .{ .gpa = gpa, .values = .init(gpa), .texts = .{ .gpa = gpa } };
    }

    pub fn deinit(self: *Properties) void {
        self.forgetDrop();
        self.values.deinit();
        self.texts.deinit();
    }

    /// Whether a number is being dragged or a colour picked: one edit, once let go.
    pub fn scrubbing(self: *const Properties) bool {
        return self.values.scrubbing();
    }

    /// `dragged` let go at `at`: put it in the slot there, if the slot takes it. Returns whether
    /// it did; the field changes on the next build.
    pub fn dropAt(self: *Properties, context: *const ui.Context, at: ui.Vec2, dragged: Dragged) bool {
        const slot = self.values.slotAt(context, at) orelse return false;
        if (!dragged.fits(slot.target)) return false;
        var buffer: [1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        const text = slot.text(fixed.allocator(), dragged) catch return false;
        self.forgetDrop();
        self.dropped = .{ .card = slot.component, .field = slot.field, .text = self.gpa.dupe(u8, text) catch return false };
        return true;
    }

    /// Draw the selected node's cards (and the scene's, for the root); returns whether
    /// `document` changed.
    pub fn build(self: *Properties, context: *ui.Context, document: *Document, request: Request) bool {
        defer self.forgetDrop();
        self.values.newFrame();
        const root = &document.scene().root;
        const index = eggy.ui_scenes.layout.indexOf(root, document.selection()) orelse 0;
        if (self.shown != index) self.values.reset();
        self.shown = index;
        const control = std.math.clamp(context.contentWidth() * control_share, min_control_width, max_control_width);
        const node = document.selectedNode();
        var changed = false;

        // Its name, whether it shows, and what kind of node it is.
        if (self.beginCard(context, .node, "Node", "Code finds it by its name")) {
            field_editor.labelledRow(context, "Name", 0);
            if (self.texts.text(context, "##ui node name", node.name, "Unnamed")) |typed| {
                node.name = document.arena().dupe(u8, typed) catch node.name;
                changed = true;
            }
            field_editor.endRow(context, control);
            field_editor.labelledRow(context, "Visible", 0);
            changed = context.toggle("##ui node visible", &node.visible) or changed;
            field_editor.endRow(context, control);
            field_editor.labelledRow(context, "Shows", 0);
            var kind: usize = @intFromEnum(std.meta.activeTag(node.widget));
            if (context.select("##ui node kind", &kind_labels, &kind)) {
                node.widget = switch (kind) {
                    0 => .panel,
                    1 => .{ .text = .{} },
                    2 => .{ .image = .{} },
                    3 => .{ .button = .{} },
                    4 => .{ .progress = .{} },
                    5 => .{ .scene = .{} },
                    else => .{ .plugin = .{} },
                };
                changed = true;
            }
            page_style.restyle(context, .{ .width = control });
            field_editor.endRow(context, control);
        }
        endCard(context);

        // What it shows, unless it is a plain panel.
        if (node.widget != .panel) {
            if (self.beginCard(context, .widget, kind_labels[@intFromEnum(std.meta.activeTag(node.widget))], "")) {
                changed = switch (node.widget) {
                    .panel => false,
                    .text => |*text| self.fieldsOf(context, ui_scene.Text, .{}, text, .widget, document, request, control),
                    .image => |*image| self.fieldsOf(context, ui_scene.Image, .{ .assets = &.{.{ "image", .image }} }, image, .widget, document, request, control),
                    .button => |*button| self.fieldsOf(context, ui_scene.Button, .{}, button, .widget, document, request, control),
                    .progress => |*progress| self.fieldsOf(context, ui_scene.Progress, .{}, progress, .widget, document, request, control),
                    .scene => |*instance| self.fieldsOf(context, ui_scene.Instance, .{ .assets = &.{.{ "scene", .ui }} }, instance, .widget, document, request, control),
                    .plugin => |*plugin| self.pluginWidget(context, plugin, document, request.widgets, control),
                } or changed;
            }
            endCard(context);
        }

        // Its size and place, pinned with the anchor grid.
        if (self.beginCard(context, .layout, "Layout", "")) {
            field_editor.labelledRow(context, "Pin to", 0);
            changed = anchorGrid(context, &node.layout) or changed;
            field_editor.endRow(context, control);
            changed = self.fieldsOf(context, ui_scene.Layout, .{}, &node.layout, .layout, document, request, control) or changed;
        }
        endCard(context);

        if (self.beginCard(context, .look, "Look", "")) {
            changed = self.fieldsOf(context, ui_scene.Look, .{ .assets = &.{.{ "image", .image }} }, &node.look, .look, document, request, control) or changed;
        }
        endCard(context);

        // The scene's own settings, with its root.
        if (document.selection().len == 0) {
            const scene = document.scene();
            if (self.beginCard(context, .scene, "Scene", "Its size, and how it fits the screen")) {
                changed = self.fieldsOf(context, ui_scene.UiScene, .{ .skip = &.{ "format_version", "theme", "root" } }, scene, .scene, document, request, control) or changed;
            }
            endCard(context);
            if (self.beginCard(context, .theme, "Theme", "Eggy's dark or light, with your own colours and font")) {
                changed = self.fieldsOf(context, ui_scene.Theme, .{ .assets = &.{.{ "font", .any }}, .colours = true }, &scene.theme, .theme, document, request, control) or changed;
            }
            endCard(context);
        }
        return changed;
    }

    /// A card's header, folding it when pressed; returns whether its contents show. Pair with
    /// `endCard` whatever it returns.
    fn beginCard(self: *Properties, context: *ui.Context, card: Card, title: []const u8, note: []const u8) bool {
        const b = context.builder();
        const folded = self.folded.contains(card);
        context.begin(.card);
        const fold_id = context.idFor(std.fmt.allocPrint(b.allocator, "ui card {t}", .{card}) catch "ui card");
        if (context.activated(fold_id)) self.folded.toggle(card);
        const text = b.node(0, .{ .grow = 1, .gap = 1 }, .none, &.{
            b.node(0, .{}, .{ .text = .{ .value = title, .size = 14 } }, &.{}) catch return !folded,
            b.node(0, .{}, .{ .text = .{ .value = note, .size = 11, .tone = .muted, .wrap = true } }, &.{}) catch return !folded,
        }) catch return !folded;
        if (note.len == 0) text.children = text.children[0..1];
        const header = b.node(fold_id, .{ .direction = .row, .gap = 8, .align_items = .center, .grow = 1 }, .none, &.{
            b.node(0, .{ .width = 14, .height = 14 }, .{ .icon = if (folded) .chevron_right else .chevron_down }, &.{}) catch return !folded,
            text,
        }) catch return !folded;
        header.cursor = .pointer;
        header.accessibility = .{ .role = .button, .label = title, .expanded = !folded };
        context.element(header);
        return !folded;
    }

    /// Every field of `value` (a `T`) as a row: strings as text fields, the rest with the
    /// Inspector's controls. Returns whether one changed; new values go into the document's arena.
    fn fieldsOf(self: *Properties, context: *ui.Context, comptime T: type, comptime options: ViewOptions, value: *T, comptime card: Card, document: *Document, request: Request, control: f32) bool {
        const infos = comptime eggy.components.Registry(&.{View(T, options)}, &.{"ui"}).infos[0].fields;
        const frame = context.builder().allocator;
        var changed = false;
        inline for (std.meta.fields(T), 0..) |field, i| {
            const parts = infos[i].parts;
            if (comptime skipped(options, field.name)) {
                // Drawn elsewhere, or not for people to change.
            } else if (field.type == []const u8 and parts[0].kind != .asset) {
                field_editor.labelledRow(context, field_editor.displayName(frame, field.name), 0);
                if (self.texts.text(context, std.fmt.comptimePrint("##ui {t} {s}", .{ card, field.name }), @field(value.*, field.name), "")) |typed| {
                    @field(value.*, field.name) = document.arena().dupe(u8, typed) catch @field(value.*, field.name);
                    changed = true;
                }
                field_editor.endRow(context, control);
            } else blk: {
                var zon: std.Io.Writer.Allocating = .init(frame);
                std.zon.stringify.serialize(@field(value.*, field.name), .{ .whitespace = false }, &zon.writer) catch break :blk;
                const shown: ?[]const u8 = if (parts[0].kind != .asset) null else if (request.assets) |assets| assets.label(frame, keyOf(@field(value.*, field.name))) else keyOf(@field(value.*, field.name));
                var typed = self.values.fieldRows(context, .{
                    .component = @intFromEnum(card),
                    .field = i,
                    .label = field_editor.displayName(frame, field.name),
                    .parts = parts,
                    .text = zon.written(),
                    .shown = shown,
                    .control_width = control,
                    .dragging = request.dragging,
                    .assets = request.assets,
                });
                if (self.dropped) |drop| if (drop.card == @intFromEnum(card) and drop.field == i) {
                    typed = drop.text;
                };
                // A value that doesn't read as the field's type is left as it was.
                const text = typed orelse break :blk;
                const source = frame.dupeZ(u8, text) catch break :blk;
                @field(value.*, field.name) = std.zon.parse.fromSliceAlloc(field.type, document.arena(), source, null, .{}) catch break :blk;
                changed = true;
            }
        }
        return changed;
    }

    /// A plugin widget: which of the game's widgets, and the value it reads.
    fn pluginWidget(self: *Properties, context: *ui.Context, plugin: *ui_scene.PluginWidget, document: *Document, widgets: []const eggy.plugins.UiWidget, control: f32) bool {
        const frame = context.builder().allocator;
        var changed = false;
        var labels: std.ArrayList([]const u8) = .empty;
        labels.append(frame, "None") catch return false;
        var chosen: usize = 0;
        for (widgets, 1..) |declared, i| {
            labels.append(frame, declared.title) catch break;
            if (std.mem.eql(u8, declared.key, plugin.widget)) chosen = i;
        }
        if (chosen == 0 and plugin.widget.len > 0) {
            labels.append(frame, std.fmt.allocPrint(frame, "Missing ({s})", .{plugin.widget}) catch plugin.widget) catch {};
            chosen = labels.items.len - 1;
        }
        field_editor.labelledRow(context, "Widget", 0);
        if (context.select("##ui plugin widget", labels.items, &chosen) and chosen <= widgets.len) {
            plugin.widget = if (chosen == 0) "" else document.arena().dupe(u8, widgets[chosen - 1].key) catch plugin.widget;
            changed = true;
        }
        page_style.restyle(context, .{ .width = control });
        field_editor.endRow(context, control);
        field_editor.labelledRow(context, "Value", 0);
        if (self.texts.text(context, "##ui plugin value", plugin.value, "Read by the widget")) |typed| {
            plugin.value = document.arena().dupe(u8, typed) catch plugin.value;
            changed = true;
        }
        field_editor.endRow(context, control);
        if (widgets.len == 0) {
            context.muted("Plugins add widgets with `ui_widgets`.");
            page_style.smallText(context, 12);
        }
        return changed;
    }

    fn forgetDrop(self: *Properties) void {
        if (self.dropped) |drop| self.gpa.free(drop.text);
        self.dropped = null;
    }
};

fn endCard(context: *ui.Context) void {
    context.end();
    page_style.restyle(context, .{ .gap = 8, .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 } });
}

/// How `View` changes a type for the Inspector's controls.
const ViewOptions = struct {
    /// Fields holding an asset key, and the kind of file each takes: drawn as drop slots.
    assets: []const struct { []const u8, eggy.assets.Kind } = &.{},
    /// Fields not drawn here.
    skip: []const []const u8 = &.{},
    /// Whether optional `[4]f32` fields are colours (a theme's), which their names don't say.
    colours: bool = false,
};

/// `T` as the Inspector's controls should read it, field for field in the same order: asset keys
/// as references, colours named as colours, skipped fields as nothing.
fn View(comptime T: type, comptime options: ViewOptions) type {
    const fields = std.meta.fields(T);
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    for (fields, &names, &types) |field, *name, *Type| {
        name.* = if (options.colours and field.type == ?[4]f32) field.name ++ "_color" else field.name;
        Type.* = if (skipped(options, field.name)) void else field.type;
        for (options.assets) |asset| if (std.mem.eql(u8, asset[0], field.name)) {
            Type.* = eggy.AssetRef(asset[1]);
        };
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn skipped(comptime options: ViewOptions, comptime name: []const u8) bool {
    for (options.skip) |skip| if (std.mem.eql(u8, skip, name)) return true;
    return false;
}

/// An asset field's key: the field itself, a string.
fn keyOf(value: anytype) []const u8 {
    return if (@TypeOf(value) == []const u8) value else "";
}

/// The 3x3 points of the parent a node can be pinned to.
const anchor_points = [9][2]f32{ .{ 0, 0 }, .{ 0.5, 0 }, .{ 1, 0 }, .{ 0, 0.5 }, .{ 0.5, 0.5 }, .{ 1, 0.5 }, .{ 0, 1 }, .{ 0.5, 1 }, .{ 1, 1 } };

/// Nine squares standing for the parent's corners, edges and middle: pressing one pins the node
/// there (its own same point at the parent's), the lit one is where it is pinned. Returns whether
/// it changed.
fn anchorGrid(context: *ui.Context, layout: *ui_scene.Layout) bool {
    const b = context.builder();
    var changed = false;
    var rows: [3]*ui.Layout.Element = undefined;
    for (&rows, 0..) |*row, r| {
        var cells: [3]*ui.Layout.Element = undefined;
        for (&cells, 0..) |*cell, c| {
            const point = anchor_points[r * 3 + c];
            const id = context.idFor(std.fmt.allocPrint(b.allocator, "ui anchor {d}", .{r * 3 + c}) catch return changed);
            if (context.activated(id)) {
                layout.anchor = .{ .at = point, .pivot = point };
                changed = true;
            }
            const on = if (layout.anchor) |anchor| std.meta.eql(anchor.at, point) and std.meta.eql(anchor.pivot, point) else false;
            const paint = b.allocator.create(AnchorCell) catch return changed;
            paint.* = .{ .id = id, .on = on };
            cell.* = b.node(id, .{ .width = 14, .height = 14 }, .{ .custom = .{ .context = paint, .draw = AnchorCell.draw } }, &.{}) catch return changed;
            cell.*.cursor = .pointer;
            cell.*.accessibility = .{ .role = .button, .label = "Pin to this point" };
        }
        row.* = b.node(0, .{ .direction = .row, .gap = 3 }, .none, b.allocator.dupe(*ui.Layout.Element, &cells) catch return changed) catch return changed;
    }
    context.element(b.node(0, .{ .gap = 3 }, .none, b.allocator.dupe(*ui.Layout.Element, &rows) catch return changed) catch return changed);
    return changed;
}

const AnchorCell = struct {
    id: u32,
    on: bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const AnchorCell = @ptrCast(@alignCast(context));
        const t = c.theme;
        if (self.on) return c.roundRect(r, t.primary, 3);
        if (c.hot_id == self.id) return c.roundRect(r, t.accent, 3);
        try c.roundRectAlpha(r, t.muted_foreground, 3, 0.35);
    }
};

test "a view turns asset keys into references and names a theme's colours, field for field" {
    const ThemeView = View(ui_scene.Theme, .{ .assets = &.{.{ "font", .any }}, .colours = true });
    const infos = eggy.components.Registry(&.{ThemeView}, &.{"ui"}).infos[0].fields;
    try std.testing.expectEqual(std.meta.fields(ui_scene.Theme).len, infos.len);
    try std.testing.expectEqualStrings("background_color", infos[1].name);
    // An optional colour's inner value is still a colour.
    try std.testing.expectEqual(eggy.components.PartKind.color, infos[1].parts[1].kind);
    try std.testing.expectEqual(eggy.components.PartKind.asset, infos[infos.len - 1].parts[0].kind);
}
