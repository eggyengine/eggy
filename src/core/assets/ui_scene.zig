//! UI scenes (`.ui.zon`): a tree of UI nodes (panels, text, images, buttons, progress bars,
//! other UI scenes and plugin widgets) laid out in rows and columns or pinned to a point of their
//! parent, styled by a theme each node's colors can refer to. Entities show one on the screen
//! (`UiScreen`, a HUD) or in the world (`UiBillboard`); the editor's UI Designer edits them.
//!
//! A scene parsed with `parse` owns its memory in an arena; the editor edits a copy (`clone`)
//! and writes it back with `write`, so an undo step is the file's text before and after.
//!
//!     .{
//!         .format_version = 1,
//!         .design_size = .{ 1280, 720 },
//!         .root = .{ .name = "HUD", .layout = .{ .width = .fill, .height = .fill }, .children = .{
//!             .{ .name = "score", .widget = .{ .text = .{ .value = "Score: 0" } },
//!                 .layout = .{ .anchor = .{ .at = .{ 1, 0 }, .pivot = .{ 1, 0 }, .offset = .{ -16, 16 } } } },
//!         } },
//!     }
const std = @import("std");

/// The `.ui.zon` layout this build reads and writes; a file of another version is refused.
pub const format_version: u32 = 1;

/// The suffix every UI scene's file name ends with.
pub const extension = ".ui.zon";

/// A color of the scene's theme, which a node's colors can name so the theme restyles them.
pub const ThemeColor = enum {
    background,
    foreground,
    card,
    card_foreground,
    primary,
    primary_foreground,
    secondary,
    secondary_foreground,
    muted,
    muted_foreground,
    accent,
    accent_foreground,
    destructive,
    border,
};

/// A color: none (nothing drawn), one of the theme's, or red, green, blue and alpha (0 to 1, sRGB).
pub const Color = union(enum) {
    none,
    theme: ThemeColor,
    color: [4]f32,
};

/// How big a node is along one axis, in design pixels: its content's size (`auto`), a fixed
/// size, a share of its parent's content box, or what is left of it (`fill`; in a row or column,
/// the leftover is split between the children that fill).
pub const Size = union(enum) {
    auto,
    px: f32,
    percent: f32,
    fill,
};

pub const Insets = struct { left: f32 = 0, top: f32 = 0, right: f32 = 0, bottom: f32 = 0 };

/// Where a node's children sit across its row or column.
pub const Align = enum { start, center, end, stretch };
/// Where a node's children sit along its row or column, when none fills.
pub const Justify = enum { start, center, end, space_between };

/// A node pinned to a point of its parent's content box instead of taking a place in its row or
/// column: its `pivot` (0 left or top, 1 right or bottom) sits at `at`, moved by `offset` pixels.
pub const Anchor = struct {
    at: [2]f32 = .{ 0, 0 },
    pivot: [2]f32 = .{ 0, 0 },
    offset: [2]f32 = .{ 0, 0 },
};

pub const Layout = struct {
    width: Size = .auto,
    height: Size = .auto,
    /// Pinned to a point of the parent; null takes a place in the parent's row or column.
    anchor: ?Anchor = null,
    /// How the children are laid out.
    direction: enum { column, row } = .column,
    gap: f32 = 0,
    padding: Insets = .{},
    align_items: Align = .start,
    justify: Justify = .start,
};

/// How a node's box is painted, under its widget and children.
pub const Look = struct {
    background: Color = .none,
    /// An image (asset key) over the background, stretched across the box; with `slice`, a
    /// nine-slice: those insets (in the image's pixels) keep their size at the corners and edges.
    image: []const u8 = "",
    slice: Insets = .{},
    border: Color = .none,
    border_width: f32 = 0,
    radius: f32 = 0,
    /// 0 is see-through, 1 opaque; it multiplies the children's too.
    opacity: f32 = 1,
    /// Whether children are cut off at the box's edges.
    clip: bool = false,
};

pub const TextAlign = enum { start, center, end };

pub const Text = struct {
    value: []const u8 = "Text",
    size: f32 = 16,
    color: Color = .{ .theme = .foreground },
    alignment: TextAlign = .start,
    /// Break onto more lines to fit the node's width.
    wrap: bool = false,
};

pub const Fit = enum {
    /// All of the image, keeping its shape.
    contain,
    /// The whole box, keeping its shape; what doesn't fit is cut off.
    cover,
    /// The whole box, stretched.
    stretch,
};

pub const Image = struct {
    /// The image file's asset key; a GIF plays.
    image: []const u8 = "",
    fit: Fit = .contain,
};

/// A button: the node's look is its normal look (the theme's primary color when it has no
/// background or image of its own); `hover` and `pressed` replace the background while the
/// pointer is over or pressing it (`none`: lightened or darkened).
pub const Button = struct {
    label: []const u8 = "Button",
    size: f32 = 16,
    text_color: Color = .{ .theme = .primary_foreground },
    hover: Color = .none,
    pressed: Color = .none,
};

pub const Progress = struct {
    /// How full, 0 to 1.
    value: f32 = 0.5,
    fill: Color = .{ .theme = .primary },
    track: Color = .{ .theme = .muted },
    direction: enum { left_to_right, right_to_left, bottom_to_top, top_to_bottom } = .left_to_right,
};

/// Another UI scene drawn in the node's box, as a reusable part (a health bar, an inventory slot).
pub const Instance = struct {
    /// The `.ui.zon`'s asset key.
    scene: []const u8 = "",
};

/// A widget a plugin draws (its `ui_widgets`), by `"<plugin key>/<widget key>"`.
pub const PluginWidget = struct {
    widget: []const u8 = "",
    /// Text the plugin reads however it likes: settings, a value to show.
    value: []const u8 = "",
};

/// What a node shows in its box.
pub const Widget = union(enum) {
    /// Nothing but its look: a container for its children.
    panel,
    text: Text,
    image: Image,
    button: Button,
    progress: Progress,
    scene: Instance,
    plugin: PluginWidget,
};

pub const Node = struct {
    /// What code finds it by (`app.uiScenes().setText(entity, "score", ...)`); several nodes can
    /// share a name.
    name: []const u8 = "",
    widget: Widget = .panel,
    layout: Layout = .{},
    look: Look = .{},
    visible: bool = true,
    children: []Node = &.{},
};

/// The scene's colors and shapes: a base theme (Eggy's dark or light) with any of its colors,
/// its corner radius and text size replaced, and a font.
pub const Theme = struct {
    base: enum { dark, light } = .dark,
    background: ?[4]f32 = null,
    foreground: ?[4]f32 = null,
    card: ?[4]f32 = null,
    card_foreground: ?[4]f32 = null,
    primary: ?[4]f32 = null,
    primary_foreground: ?[4]f32 = null,
    secondary: ?[4]f32 = null,
    secondary_foreground: ?[4]f32 = null,
    muted: ?[4]f32 = null,
    muted_foreground: ?[4]f32 = null,
    accent: ?[4]f32 = null,
    accent_foreground: ?[4]f32 = null,
    destructive: ?[4]f32 = null,
    border: ?[4]f32 = null,
    radius: ?f32 = null,
    /// A TTF or OTF file's asset key; empty for Eggy's font.
    font: []const u8 = "",

    /// The color `token` names, if the scene replaced it.
    pub fn override(self: Theme, token: ThemeColor) ?[4]f32 {
        return switch (token) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }
};

/// How a screen-space scene is scaled from its `design_size` to the screen. It is laid out in the
/// screen's size divided by the scale, so pinned nodes still reach the screen's edges.
pub const Scaling = enum {
    /// One design pixel is one screen point.
    none,
    /// The design fits inside the screen.
    fit,
    /// The design covers the screen.
    fill,
    /// The design's width matches the screen's.
    width,
    /// The design's height matches the screen's.
    height,

    /// How many screen points a design pixel takes for a `screen`-sized screen.
    pub fn scale(self: Scaling, design: [2]f32, screen: [2]f32) f32 {
        const wide = screen[0] / design[0];
        const tall = screen[1] / design[1];
        return switch (self) {
            .none => 1,
            .fit => @min(wide, tall),
            .fill => @max(wide, tall),
            .width => wide,
            .height => tall,
        };
    }
};

pub const UiScene = struct {
    format_version: u32 = format_version,
    /// The size it is designed at, in design pixels: a screen's, or a billboard's face.
    design_size: [2]f32 = .{ 1280, 720 },
    scaling: Scaling = .height,
    theme: Theme = .{},
    root: Node = .{ .name = "Root", .layout = .{ .width = .fill, .height = .fill } },

    pub const Error = error{ InvalidUiScene, UnsupportedVersion };

    /// Whether every number is usable: finite, sizes and widths not negative, opacity and
    /// progress within 0 to 1, a positive design size.
    pub fn validate(self: UiScene) Error!void {
        if (self.format_version != format_version) return error.UnsupportedVersion;
        for (self.design_size) |side| if (!std.math.isFinite(side) or side <= 0) return error.InvalidUiScene;
        if (self.theme.radius) |radius| if (!std.math.isFinite(radius) or radius < 0) return error.InvalidUiScene;
        try validateNode(self.root, 0);
    }

    /// A copy owning its memory in `arena`, for editing in place.
    pub fn clone(self: UiScene, arena: std.mem.Allocator) !UiScene {
        var copy = self;
        copy.theme.font = try arena.dupe(u8, self.theme.font);
        copy.root = try cloneNode(arena, self.root);
        return copy;
    }

    /// `self` as `.ui.zon` text, leaving out what is at its default.
    pub fn write(self: UiScene, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.zon.stringify.serializeArbitraryDepth(self, .{ .emit_default_optional_fields = false }, writer);
        try writer.writeByte('\n');
    }
};

/// How deep nodes may nest; deeper is refused as a malformed file.
pub const max_depth = 32;

fn validateNode(node: Node, depth: usize) UiScene.Error!void {
    if (depth >= max_depth) return error.InvalidUiScene;
    inline for (.{ node.layout.width, node.layout.height }) |size| switch (size) {
        .px, .percent => |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidUiScene,
        .auto, .fill => {},
    };
    if (node.layout.anchor) |anchor| for (anchor.at ++ anchor.pivot ++ anchor.offset) |value| {
        if (!std.math.isFinite(value)) return error.InvalidUiScene;
    };
    const padding = node.layout.padding;
    for ([_]f32{ node.layout.gap, padding.left, padding.top, padding.right, padding.bottom, node.look.border_width, node.look.radius, node.look.slice.left, node.look.slice.top, node.look.slice.right, node.look.slice.bottom }) |value| {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidUiScene;
    }
    if (!std.math.isFinite(node.look.opacity) or node.look.opacity < 0 or node.look.opacity > 1) return error.InvalidUiScene;
    try validateColor(node.look.background);
    try validateColor(node.look.border);
    switch (node.widget) {
        .text => |text| {
            if (!std.math.isFinite(text.size) or text.size <= 0) return error.InvalidUiScene;
            try validateColor(text.color);
        },
        .button => |button| {
            if (!std.math.isFinite(button.size) or button.size <= 0) return error.InvalidUiScene;
            inline for (.{ button.text_color, button.hover, button.pressed }) |color| try validateColor(color);
        },
        .progress => |progress| {
            if (!std.math.isFinite(progress.value) or progress.value < 0 or progress.value > 1) return error.InvalidUiScene;
            try validateColor(progress.fill);
            try validateColor(progress.track);
        },
        .panel, .image, .scene, .plugin => {},
    }
    for (node.children) |child| try validateNode(child, depth + 1);
}

fn validateColor(color: Color) UiScene.Error!void {
    if (color == .color) for (color.color) |channel| {
        if (!std.math.isFinite(channel) or channel < 0 or channel > 1) return error.InvalidUiScene;
    };
}

fn cloneNode(arena: std.mem.Allocator, node: Node) std.mem.Allocator.Error!Node {
    var copy = node;
    copy.name = try arena.dupe(u8, node.name);
    copy.look.image = try arena.dupe(u8, node.look.image);
    copy.widget = switch (node.widget) {
        .panel => .panel,
        .text => |text| .{ .text = blk: {
            var value = text;
            value.value = try arena.dupe(u8, text.value);
            break :blk value;
        } },
        .image => |image| .{ .image = .{ .image = try arena.dupe(u8, image.image), .fit = image.fit } },
        .button => |button| .{ .button = blk: {
            var value = button;
            value.label = try arena.dupe(u8, button.label);
            break :blk value;
        } },
        .progress => |progress| .{ .progress = progress },
        .scene => |instance| .{ .scene = .{ .scene = try arena.dupe(u8, instance.scene) } },
        .plugin => |widget| .{ .plugin = .{ .widget = try arena.dupe(u8, widget.widget), .value = try arena.dupe(u8, widget.value) } },
    };
    copy.children = try arena.alloc(Node, node.children.len);
    for (copy.children, node.children) |*to, from| to.* = try cloneNode(arena, from);
    return copy;
}

/// A node's place in its scene: the index of each child taken from the root down (empty for
/// the root).
pub const Path = []const u16;

/// The node at `path` in the tree under `root`, if there is one.
pub fn nodeAt(root: *Node, path: Path) ?*Node {
    var node = root;
    for (path) |index| {
        if (index >= node.children.len) return null;
        node = &node.children[index];
    }
    return node;
}

/// Put `child` among `parent`'s children at `index` (clamped to the end), allocating the new
/// list in `arena`.
pub fn insertChild(arena: std.mem.Allocator, parent: *Node, index: usize, child: Node) !void {
    const at = @min(index, parent.children.len);
    const children = try arena.alloc(Node, parent.children.len + 1);
    @memcpy(children[0..at], parent.children[0..at]);
    children[at] = child;
    @memcpy(children[at + 1 ..], parent.children[at..]);
    parent.children = children;
}

/// Take `parent`'s child at `index` out, returning it. The old list stays in the arena.
pub fn removeChild(arena: std.mem.Allocator, parent: *Node, index: usize) !Node {
    const removed = parent.children[index];
    const children = try arena.alloc(Node, parent.children.len - 1);
    @memcpy(children[0..index], parent.children[0..index]);
    @memcpy(children[index..], parent.children[index + 1 ..]);
    parent.children = children;
    return removed;
}

/// `source` (a `.ui.zon`) parsed and checked; free it with `Parsed.deinit`.
/// Requires sentinel-terminated input; ZON syntax/type errors and `UiScene.Error`s propagate.
///
/// ```zig
/// var parsed = try ui_scene.parse(gpa, source);
/// defer parsed.deinit();
/// const root = parsed.scene.root;
/// ```
pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const scene = try std.zon.parse.fromSliceAlloc(UiScene, arena.allocator(), source, null, .{});
    try scene.validate();
    return .{ .arena = arena, .scene = scene };
}

/// A scene and the arena holding its strings and nodes.
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    scene: UiScene,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

/// A new UI scene's text: a full-screen root with a heading pinned to its top left.
pub const template =
    \\.{
    \\    .format_version = 1,
    \\    .root = .{
    \\        .name = "Root",
    \\        .layout = .{ .width = .fill, .height = .fill },
    \\        .children = .{
    \\            .{
    \\                .name = "title",
    \\                .widget = .{ .text = .{ .value = "Hello", .size = 32 } },
    \\                .layout = .{ .anchor = .{ .offset = .{ 32, 32 } } },
    \\            },
    \\        },
    \\    },
    \\}
    \\
;

test "the template parses, and a scene writes and reads back the same" {
    const gpa = std.testing.allocator;
    var parsed = try parse(gpa, template);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("title", parsed.scene.root.children[0].name);
    try std.testing.expectEqual(@as(f32, 32), parsed.scene.root.children[0].widget.text.size);

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try parsed.scene.write(&text.writer);
    const source = try gpa.dupeZ(u8, text.written());
    defer gpa.free(source);
    var again = try parse(gpa, source);
    defer again.deinit();
    try std.testing.expectEqualStrings("Hello", again.scene.root.children[0].widget.text.value);
    // Defaults aren't written.
    try std.testing.expect(std.mem.indexOf(u8, text.written(), ".opacity") == null);
}

test "bad numbers and other versions are refused" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedVersion, parse(gpa, ".{ .format_version = 2 }"));
    try std.testing.expectError(error.InvalidUiScene, parse(gpa, ".{ .design_size = .{ 0, 720 } }"));
    try std.testing.expectError(error.InvalidUiScene, parse(gpa, ".{ .root = .{ .look = .{ .opacity = 2 } } }"));
    try std.testing.expectError(error.InvalidUiScene, parse(gpa, ".{ .root = .{ .layout = .{ .width = .{ .px = -1 } } } }"));
}

test "nodes are found by path, inserted and removed in a clone" {
    const gpa = std.testing.allocator;
    var parsed = try parse(gpa, template);
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var copy = try parsed.scene.clone(arena.allocator());
    try insertChild(arena.allocator(), &copy.root, 0, .{ .name = "bar", .widget = .{ .progress = .{} } });
    try std.testing.expectEqualStrings("bar", nodeAt(&copy.root, &.{0}).?.name);
    try std.testing.expectEqualStrings("title", nodeAt(&copy.root, &.{1}).?.name);
    try std.testing.expect(nodeAt(&copy.root, &.{2}) == null);
    const taken = try removeChild(arena.allocator(), &copy.root, 1);
    try std.testing.expectEqualStrings("title", taken.name);
    try std.testing.expectEqual(@as(usize, 1), copy.root.children.len);
    // The original is untouched.
    try std.testing.expectEqual(@as(usize, 1), parsed.scene.root.children.len);
    try std.testing.expectEqualStrings("title", parsed.scene.root.children[0].name);
}

test "scaling fits, fills or matches one side of the screen" {
    const design = [2]f32{ 1280, 720 };
    try std.testing.expectEqual(@as(f32, 0.5), Scaling.fit.scale(design, .{ 640, 720 }));
    try std.testing.expectEqual(@as(f32, 1), Scaling.fill.scale(design, .{ 640, 720 }));
    try std.testing.expectEqual(@as(f32, 2), Scaling.height.scale(design, .{ 640, 1440 }));
    try std.testing.expectEqual(@as(f32, 1), Scaling.none.scale(design, .{ 1, 1 }));
}
