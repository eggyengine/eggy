//! Where each node of a UI scene goes: its box in a viewport, measured from its text, images and
//! children, placed in its parent's row or column or pinned to a point of its parent. The result
//! is a flat list in paint order (each node before its children), which `paint.zig` draws and
//! the host hit-tests.
const std = @import("std");
const ui = @import("weeoui");
const ui_scene = @import("eggy_assets").ui_scene;
const UiScene = ui_scene.UiScene;
const Node = ui_scene.Node;
const Size = ui_scene.Size;

/// What code changed about the nodes of one name (`eggy.UiScenes`): null keeps the file's.
pub const Override = struct {
    text: ?[]const u8 = null,
    visible: ?bool = null,
    /// A progress bar's value.
    value: ?f32 = null,
    /// An image's or a node's look's image, as an asset key.
    image: ?[]const u8 = null,
};

/// What layout needs beyond the scene, borrowed for one call.
pub const Sources = struct {
    font: *const ui.Font,
    context: *anyopaque,
    /// The UI scene with asset `key`, for a nested scene; null when it can't be had.
    scene: *const fn (context: *anyopaque, key: []const u8) ?*const UiScene,
    /// An image's size in pixels, for a node sized by its image; null when it isn't loaded.
    image_size: *const fn (context: *anyopaque, key: []const u8) ?[2]f32,
    /// What code changed about the nodes named `name`, if anything.
    override: *const fn (context: *anyopaque, name: []const u8) ?*const Override,

    /// Sources with no nested scenes, images or overrides, for tests and plain previews.
    pub fn plain(font: *const ui.Font) Sources {
        const none = struct {
            fn scene(_: *anyopaque, _: []const u8) ?*const UiScene {
                return null;
            }
            fn imageSize(_: *anyopaque, _: []const u8) ?[2]f32 {
                return null;
            }
            fn override(_: *anyopaque, _: []const u8) ?*const Override {
                return null;
            }
        };
        return .{ .font = font, .context = undefined, .scene = none.scene, .image_size = none.imageSize, .override = none.override };
    }
};

/// A node and the box it got, in the viewport's units.
pub const Placed = struct {
    node: *const Node,
    rect: ui.Rect,
    /// The index just past this node's descendants in the list.
    end: u32,
    /// The scene the node belongs to (a nested scene's own, for its nodes), whose theme paints it.
    scene: *const UiScene,
    /// The node's place in the outermost scene, counting from the root (0) in paint order; null
    /// for the nodes of a nested scene.
    index: ?u32,
    override: ?*const Override,
};

/// How many scenes may nest inside one another; a scene that would go deeper (or contain
/// itself) draws as an empty box.
pub const max_nesting = 4;

/// Lay `scene` out in `viewport`, `scale` viewport units to a design pixel: the root is laid
/// out in the viewport's size divided by `scale`, then every box is scaled and moved into it.
/// The list lives in `arena`. Hidden nodes (and their children) are left out.
///
/// ```zig
/// const placed = try layout.place(arena, &scene, .plain(font), viewport, 1);
/// for (placed) |item| std.log.info("{s} at {d}", .{ item.node.name, item.rect.x });
/// ```
pub fn place(arena: std.mem.Allocator, scene: *const UiScene, sources: Sources, viewport: ui.Rect, scale: f32) ![]Placed {
    var engine = Engine{ .arena = arena, .sources = sources };
    const area = ui.Rect{ .x = 0, .y = 0, .w = viewport.w / scale, .h = viewport.h / scale };
    try engine.placeRoot(scene, area, 0);
    for (engine.out.items) |*item| item.rect = .{
        .x = viewport.x + item.rect.x * scale,
        .y = viewport.y + item.rect.y * scale,
        .w = item.rect.w * scale,
        .h = item.rect.h * scale,
    };
    return engine.out.items;
}

const Engine = struct {
    arena: std.mem.Allocator,
    sources: Sources,
    out: std.ArrayList(Placed) = .empty,
    /// The nested scenes being laid out, outermost first, to refuse a scene inside itself.
    nesting: [max_nesting]*const UiScene = undefined,
    depth: usize = 0,

    /// The root of `scene` in `area`: its own size and anchor apply, as a child of the area would.
    /// `index` is the root's paint-order index in the outermost scene, null inside a nested one.
    fn placeRoot(self: *Engine, scene: *const UiScene, area: ui.Rect, index: ?u32) std.mem.Allocator.Error!void {
        if (self.depth == max_nesting) return;
        for (self.nesting[0..self.depth]) |outer| if (outer == scene) return;
        self.nesting[self.depth] = scene;
        self.depth += 1;
        defer self.depth -= 1;
        const root = &scene.root;
        if (!self.visible(root)) return;
        var size = self.outerSize(root, .{ area.w, area.h });
        if (root.layout.width == .fill) size[0] = area.w;
        if (root.layout.height == .fill) size[1] = area.h;
        try self.placeNode(scene, root, pinned(root.layout.anchor orelse .{}, area, size), index);
    }

    /// Put `node` at `rect`, then its children inside it, in the order they are declared.
    fn placeNode(self: *Engine, scene: *const UiScene, node: *const Node, rect: ui.Rect, index: ?u32) std.mem.Allocator.Error!void {
        const at = self.out.items.len;
        try self.out.append(self.arena, .{ .node = node, .rect = rect, .end = 0, .scene = scene, .index = index, .override = self.overrideOf(node) });
        const content = contentBox(node, rect);

        // A nested scene fills the content box; its nodes don't count in the outer scene.
        if (node.widget == .scene) if (self.sources.scene(self.sources.context, node.widget.scene.scene)) |nested| {
            try self.placeRoot(nested, content, null);
        };

        const rects = try self.childRects(node, content);
        var child_index: ?u32 = if (index) |own| own + 1 else null;
        for (node.children, rects) |*child, child_rect| {
            if (child_rect) |shown| try self.placeNode(scene, child, shown, child_index);
            if (child_index) |*next| next.* += countNodes(child);
        }
        self.out.items[at].end = @intCast(self.out.items.len);
    }

    /// Where each of `node`'s children goes in `content`: those in the row or column one after
    /// another, those pinned at their anchor; null for hidden ones.
    fn childRects(self: *Engine, node: *const Node, content: ui.Rect) ![]?ui.Rect {
        const rects = try self.arena.alloc(?ui.Rect, node.children.len);
        const row = node.layout.direction == .row;
        const main_avail = if (row) content.w else content.h;
        const cross_avail = if (row) content.h else content.w;

        // Each child's size; those that fill along the run wait for what's left.
        const sizes = try self.arena.alloc([2]f32, node.children.len);
        var used: f32 = 0;
        var fills: f32 = 0;
        var shown: usize = 0;
        for (node.children, sizes, rects) |*child, *size, *rect| {
            rect.* = null;
            if (!self.visible(child)) continue;
            size.* = self.outerSize(child, .{ content.w, content.h });
            if (child.layout.anchor) |anchor| {
                if (child.layout.width == .fill) size[0] = content.w;
                if (child.layout.height == .fill) size[1] = content.h;
                rect.* = pinned(anchor, content, size.*);
                continue;
            }
            shown += 1;
            const stretch = node.layout.align_items == .stretch and crossSize(child, row) == .auto;
            if (stretch or crossSize(child, row) == .fill) size[if (row) 1 else 0] = cross_avail;
            if (mainSize(child, row) == .fill) fills += 1 else used += size[if (row) 0 else 1];
        }
        if (shown == 0) return rects;
        const gaps = node.layout.gap * @as(f32, @floatFromInt(shown - 1));
        const left = @max(0, main_avail - used - gaps);

        // Where the run starts and how far apart its children are, when none fills.
        var cursor: f32 = 0;
        var between = node.layout.gap;
        if (fills == 0) switch (node.layout.justify) {
            .start => {},
            .center => cursor = left / 2,
            .end => cursor = left,
            .space_between => if (shown > 1) {
                between += left / @as(f32, @floatFromInt(shown - 1));
            },
        };
        for (node.children, sizes, rects) |*child, *size, *rect| {
            if (child.layout.anchor != null or !self.visible(child)) continue;
            if (mainSize(child, row) == .fill) size[if (row) 0 else 1] = left / fills;
            const main = if (row) size[0] else size[1];
            const cross = if (row) size[1] else size[0];
            const offset = switch (node.layout.align_items) {
                .start, .stretch => 0,
                .center => (cross_avail - cross) / 2,
                .end => cross_avail - cross,
            };
            rect.* = if (row)
                .{ .x = content.x + cursor, .y = content.y + offset, .w = main, .h = cross }
            else
                .{ .x = content.x + offset, .y = content.y + cursor, .w = cross, .h = main };
            cursor += main + between;
        }
        return rects;
    }

    /// How big `node` is with `avail` of its parent's content box: its fixed sizes, else what
    /// its content needs plus padding. `fill` measures as `auto`; the parent stretches it.
    fn outerSize(self: *Engine, node: *const Node, avail: [2]f32) [2]f32 {
        const padding = node.layout.padding;
        const pad = [2]f32{ padding.left + padding.right, padding.top + padding.bottom };
        const fixed = [2]?f32{ fixedSize(node.layout.width, avail[0]), fixedSize(node.layout.height, avail[1]) };
        if (fixed[0] != null and fixed[1] != null) return .{ fixed[0].?, fixed[1].? };
        // The content box's width when known, for wrapping text and keeping images' shape.
        const width_hint: ?f32 = if (fixed[0]) |w| @max(0, w - pad[0]) else if (node.layout.width == .fill) @max(0, avail[0] - pad[0]) else null;
        const height_hint: ?f32 = if (fixed[1]) |h| @max(0, h - pad[1]) else null;
        const inner = self.contentSize(node, width_hint, height_hint, .{ @max(0, (fixed[0] orelse avail[0]) - pad[0]), @max(0, (fixed[1] orelse avail[1]) - pad[1]) });
        return .{ fixed[0] orelse inner[0] + pad[0], fixed[1] orelse inner[1] + pad[1] };
    }

    /// What `node`'s content needs: its widget's size or its children's run, whichever is bigger.
    fn contentSize(self: *Engine, node: *const Node, width_hint: ?f32, height_hint: ?f32, avail: [2]f32) [2]f32 {
        const override = self.overrideOf(node);
        const font = self.sources.font;
        const own: [2]f32 = switch (node.widget) {
            .panel => .{ 0, 0 },
            .text => |text| blk: {
                const value = if (override) |o| o.text orelse text.value else text.value;
                if (text.wrap) {
                    const width = width_hint orelse @min(font.measure(value, text.size), avail[0]);
                    break :blk .{ width, font.wrappedHeight(value, text.size, width) };
                }
                break :blk .{ font.measure(value, text.size), text.size * line_height };
            },
            .button => |button| .{ font.measure(if (override) |o| o.text orelse button.label else button.label, button.size), button.size * line_height },
            .image => |image| blk: {
                const key = if (override) |o| o.image orelse image.image else image.image;
                const natural = self.sources.image_size(self.sources.context, key) orelse [2]f32{ 64, 64 };
                // One side known keeps the image's shape on the other.
                if (width_hint) |w| if (natural[0] > 0) break :blk .{ w, w * natural[1] / natural[0] };
                if (height_hint) |h| if (natural[1] > 0) break :blk .{ h * natural[0] / natural[1], h };
                break :blk natural;
            },
            .progress => .{ 160, 12 },
            .scene => |instance| if (self.sources.scene(self.sources.context, instance.scene)) |nested| nested.design_size else .{ 64, 64 },
            .plugin => .{ 64, 64 },
        };
        const run = self.runSize(node, avail);
        return .{ @max(own[0], run[0]), @max(own[1], run[1]) };
    }

    /// The size of `node`'s row or column of children.
    fn runSize(self: *Engine, node: *const Node, avail: [2]f32) [2]f32 {
        const row = node.layout.direction == .row;
        var main: f32 = 0;
        var cross: f32 = 0;
        var shown: usize = 0;
        for (node.children) |*child| {
            if (child.layout.anchor != null or !self.visible(child)) continue;
            shown += 1;
            const size = self.outerSize(child, avail);
            main += if (row) size[0] else size[1];
            cross = @max(cross, if (row) size[1] else size[0]);
        }
        if (shown > 1) main += node.layout.gap * @as(f32, @floatFromInt(shown - 1));
        return if (row) .{ main, cross } else .{ cross, main };
    }

    fn visible(self: *Engine, node: *const Node) bool {
        if (self.overrideOf(node)) |override| if (override.visible) |shown| return shown;
        return node.visible;
    }

    fn overrideOf(self: *Engine, node: *const Node) ?*const Override {
        if (node.name.len == 0) return null;
        return self.sources.override(self.sources.context, node.name);
    }
};

/// Text lines are this many times their size apart (as `ui.Canvas` wraps them).
pub const line_height = 1.35;

/// Where a node of `size` pinned by `anchor` goes in `area`.
fn pinned(anchor: ui_scene.Anchor, area: ui.Rect, size: [2]f32) ui.Rect {
    return .{
        .x = area.x + anchor.at[0] * area.w - anchor.pivot[0] * size[0] + anchor.offset[0],
        .y = area.y + anchor.at[1] * area.h - anchor.pivot[1] * size[1] + anchor.offset[1],
        .w = size[0],
        .h = size[1],
    };
}

fn fixedSize(size: Size, avail: f32) ?f32 {
    return switch (size) {
        .px => |px| px,
        .percent => |percent| avail * percent / 100,
        .auto, .fill => null,
    };
}

fn mainSize(node: *const Node, row: bool) std.meta.Tag(Size) {
    return if (row) node.layout.width else node.layout.height;
}

fn crossSize(node: *const Node, row: bool) std.meta.Tag(Size) {
    return if (row) node.layout.height else node.layout.width;
}

/// `rect` less `node`'s padding.
pub fn contentBox(node: *const Node, rect: ui.Rect) ui.Rect {
    const padding = node.layout.padding;
    return .{
        .x = rect.x + padding.left,
        .y = rect.y + padding.top,
        .w = @max(0, rect.w - padding.left - padding.right),
        .h = @max(0, rect.h - padding.top - padding.bottom),
    };
}

/// How many nodes the tree under `node` holds, `node` included.
pub fn countNodes(node: *const Node) u32 {
    var count: u32 = 1;
    for (node.children) |*child| count += countNodes(child);
    return count;
}

/// The path (child indices from the root) of the node at `index` in paint order, into `buffer`;
/// null when the tree has fewer nodes.
pub fn pathOf(root: *const Node, index: u32, buffer: []u16) ?[]u16 {
    var remaining = index;
    var node = root;
    var depth: usize = 0;
    while (remaining > 0) {
        remaining -= 1;
        const children = node.children;
        var found = false;
        for (children, 0..) |*child, i| {
            const count = countNodes(child);
            if (remaining < count) {
                if (depth == buffer.len) return null;
                buffer[depth] = @intCast(i);
                depth += 1;
                node = child;
                found = true;
                break;
            }
            remaining -= count;
        }
        if (!found) return null;
    }
    return buffer[0..depth];
}

/// The paint-order index of the node at `path`; null when there is none.
pub fn indexOf(root: *const Node, path: []const u16) ?u32 {
    var index: u32 = 0;
    var node = root;
    for (path) |at| {
        if (at >= node.children.len) return null;
        index += 1;
        for (node.children[0..at]) |*before| index += countNodes(before);
        node = &node.children[at];
    }
    return index;
}

test "a column stacks children with gaps, and fill takes what is left" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var children = [_]Node{
        .{ .name = "a", .layout = .{ .height = .{ .px = 100 } } },
        .{ .name = "b", .layout = .{ .height = .fill } },
        .{ .name = "c", .layout = .{ .height = .{ .px = 50 } } },
    };
    const scene = UiScene{ .root = .{ .layout = .{ .width = .fill, .height = .fill, .gap = 10, .padding = .{ .top = 20 }, .align_items = .stretch }, .children = &children } };
    const placed = try place(arena.allocator(), &scene, .plain(&font), .{ .x = 0, .y = 0, .w = 400, .h = 600 }, 1);
    try std.testing.expectEqual(@as(usize, 4), placed.len);
    try std.testing.expectEqual(ui.Rect{ .x = 0, .y = 20, .w = 400, .h = 100 }, placed[1].rect);
    // 600 - 20 padding - 100 - 50 - two 10 gaps = 410 for the filler.
    try std.testing.expectEqual(ui.Rect{ .x = 0, .y = 130, .w = 400, .h = 410 }, placed[2].rect);
    try std.testing.expectEqual(@as(f32, 550), placed[3].rect.y);
    try std.testing.expectEqual(@as(u32, 4), placed[0].end);
}

test "a pinned node sits at its anchor, and scaling moves every box" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var children = [_]Node{.{ .name = "corner", .layout = .{ .width = .{ .px = 100 }, .height = .{ .px = 40 }, .anchor = .{ .at = .{ 1, 1 }, .pivot = .{ 1, 1 }, .offset = .{ -10, -10 } } } }};
    const scene = UiScene{ .root = .{ .layout = .{ .width = .fill, .height = .fill }, .children = &children } };
    const placed = try place(arena.allocator(), &scene, .plain(&font), .{ .x = 0, .y = 0, .w = 1280, .h = 720 }, 1);
    try std.testing.expectEqual(ui.Rect{ .x = 1170, .y = 670, .w = 100, .h = 40 }, placed[1].rect);
    // At half scale the screen is laid out as 2560 by 1440 design pixels, then halved.
    const half = try place(arena.allocator(), &scene, .plain(&font), .{ .x = 0, .y = 0, .w = 1280, .h = 720 }, 0.5);
    try std.testing.expectEqual(ui.Rect{ .x = 1225, .y = 695, .w = 50, .h = 20 }, half[1].rect);
}

test "children paint in the order they are declared, pinned or not" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var children = [_]Node{
        .{ .name = "pinned", .layout = .{ .anchor = .{} } },
        .{ .name = "flowing" },
    };
    const scene = UiScene{ .root = .{ .children = &children } };
    const placed = try place(arena.allocator(), &scene, .plain(&font), .{ .x = 0, .y = 0, .w = 100, .h = 100 }, 1);
    try std.testing.expectEqualStrings("pinned", placed[1].node.name);
    try std.testing.expectEqual(@as(?u32, 2), placed[2].index);
}

test "a row centres its children, and hidden ones take no room but keep their place" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var children = [_]Node{
        .{ .name = "a", .layout = .{ .width = .{ .px = 50 }, .height = .{ .px = 10 } } },
        .{ .name = "gone", .visible = false, .layout = .{ .width = .{ .px = 500 } } },
        .{ .name = "b", .layout = .{ .width = .{ .px = 50 }, .height = .{ .px = 30 } } },
    };
    const scene = UiScene{ .root = .{ .layout = .{ .width = .{ .px = 300 }, .height = .{ .px = 30 }, .direction = .row, .justify = .center, .align_items = .center }, .children = &children } };
    const placed = try place(arena.allocator(), &scene, .plain(&font), .{ .x = 0, .y = 0, .w = 300, .h = 30 }, 1);
    try std.testing.expectEqual(@as(usize, 3), placed.len);
    try std.testing.expectEqual(ui.Rect{ .x = 100, .y = 10, .w = 50, .h = 10 }, placed[1].rect);
    try std.testing.expectEqual(ui.Rect{ .x = 150, .y = 0, .w = 50, .h = 30 }, placed[2].rect);
    // "b" is the third node of the scene in paint order, though the second drawn child.
    try std.testing.expectEqual(@as(?u32, 3), placed[2].index);
}

test "paths and paint-order indices name the same nodes" {
    var grandchildren = [_]Node{ .{ .name = "x" }, .{ .name = "y" } };
    var children = [_]Node{ .{ .name = "a", .children = &grandchildren }, .{ .name = "b" } };
    const root = Node{ .children = &children };
    var buffer: [8]u16 = undefined;
    try std.testing.expectEqualSlices(u16, &.{}, pathOf(&root, 0, &buffer).?);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1 }, pathOf(&root, 3, &buffer).?);
    try std.testing.expectEqualSlices(u16, &.{1}, pathOf(&root, 4, &buffer).?);
    try std.testing.expect(pathOf(&root, 5, &buffer) == null);
    try std.testing.expectEqual(@as(?u32, 3), indexOf(&root, &.{ 0, 1 }));
    try std.testing.expectEqual(@as(?u32, 4), indexOf(&root, &.{1}));
}
