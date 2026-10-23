//! The UI Designer's preview: the scene drawn at a chosen screen size and fit into its area of
//! the panel over a grid of design pixels, the selected node outlined and named. Pressing a node
//! selects it, and dragging a pinned node moves its offset, snapped to the grid while it shows.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ui_scene = eggy.assets.ui_scene;
const ui_scenes = eggy.ui_scenes;
const Document = @import("document.zig").Document;

/// The screen sizes the preview can show the scene at; null is the scene's design size.
pub const screens = [_]struct { label: []const u8, size: ?[2]f32 }{
    .{ .label = "Design size", .size = null },
    .{ .label = "1920 x 1080", .size = .{ 1920, 1080 } },
    .{ .label = "1280 x 720", .size = .{ 1280, 720 } },
    .{ .label = "1024 x 768", .size = .{ 1024, 768 } },
    .{ .label = "Phone (390 x 844)", .size = .{ 390, 844 } },
    .{ .label = "Phone sideways (844 x 390)", .size = .{ 844, 390 } },
};

/// What happened in the preview this frame.
pub const Outcome = struct {
    /// The node pressed, as a paint-order index in the scene.
    picked: ?u32 = null,
    /// A drag moved the selected node.
    moved: bool = false,
    /// A drag just ended: the move is done.
    dropped: bool = false,
};

/// Design pixels between the grid's lines; every fifth line is stronger.
pub const grid_step_px = 10;

const Drag = struct { index: u32, pointer: ui.Vec2, offset: [2]f32, scale: f32 };

pub const Preview = struct {
    /// Which of `screens` the scene is shown at.
    screen: usize = 0,
    /// Whether the grid shows, and drags snap to it.
    grid: bool = true,
    /// The scene's images, in the designer page's font.
    images: ui_scenes.cache.Images,
    drag: ?Drag = null,
    /// Where the scene was last drawn, and at what scale, for drops.
    shown: ?struct { viewport: ui.Rect, scale: f32 } = null,

    pub fn deinit(self: *Preview) void {
        self.images.deinit();
    }

    /// Where `at` (the page's units) is in the scene, in design pixels from its top left; null
    /// off the scene.
    pub fn designPoint(self: *const Preview, at: ui.Vec2) ?[2]f32 {
        const shown = self.shown orelse return null;
        if (!shown.viewport.contains(at.x, at.y)) return null;
        return .{ (at.x - shown.viewport.x) / shown.scale, (at.y - shown.viewport.y) / shown.scale };
    }

    /// Draw `document`'s scene into `area` of `context` (its units), outlining the selected
    /// node, and follow presses and drags over it. Images and nested scenes come through
    /// `state` and `resources`.
    pub fn build(self: *Preview, context: *ui.Context, document: *Document, state: *ui_scenes.State, resources: eggy.resources.Resources, area: ui.Rect, time_ms: u64) Outcome {
        var outcome = Outcome{};
        const scene = document.scene();
        const screen = screens[self.screen].size orelse scene.design_size;
        if (area.w < 8 or area.h < 8) return outcome;

        // The screen fit into the area, and the scene scaled to the screen as the game would.
        const fit = @min(area.w / screen[0], area.h / screen[1]);
        const viewport = ui.Rect{ .x = area.x + (area.w - screen[0] * fit) / 2, .y = area.y + (area.h - screen[1] * fit) / 2, .w = screen[0] * fit, .h = screen[1] * fit };
        const scale = scene.scaling.scale(scene.design_size, screen) * fit;
        self.shown = .{ .viewport = viewport, .scale = scale };
        overlayBox(context, viewport, .{ .fill = context.theme.muted }, 0) catch return outcome;
        if (self.grid) overlayBox(context, viewport, .{ .grid = .{ .color = context.theme.border, .step = grid_step_px * scale } }, 0) catch {};
        const built = ui_scenes.scene_ui.build(context, state, resources, &self.images, scene, .{ .id = 0, .generation = 0 }, .{ .viewport = viewport, .scale = scale, .z_index = 1, .mode = .design, .clip = viewport }, time_ms) catch |err| {
            std.log.err("cannot preview the UI scene: {t}", .{err});
            return outcome;
        };

        // The selected node's outline and name, over everything.
        const selected_index = ui_scenes.layout.indexOf(&scene.root, document.selection());
        for (built.placed) |item| if (item.index != null and item.index == selected_index) {
            overlayBox(context, item.rect, .{ .outline = context.theme.ring }, 3) catch {};
            nameTag(context, item.node.name, item.rect, viewport);
        };

        // A press picks the node under it, and holding a pinned node drags it. A click pressed and
        // let go between two frames picks it too. (The hit boxes are plain elements, so weeoui's
        // `active`, which its own widgets set, never names them.)
        const pressed_on = if (context.pressed_down) if (context.press) |press| press.widget else 0 else 0;
        for (built.placed, built.ids) |item, id| {
            if (id == 0) continue;
            const index = item.index orelse continue;
            if (id == pressed_on) {
                outcome.picked = index;
                if (item.node.layout.anchor) |anchor| if (index != 0) {
                    self.drag = .{ .index = index, .pointer = context.pointer, .offset = anchor.offset, .scale = scale };
                };
            } else if (context.activated(id)) outcome.picked = index;
        }
        if (self.drag) |drag| {
            if (!context.pointer_held) {
                self.drag = null;
                outcome.dropped = true;
            } else if (dragged(document, drag)) |node| {
                const moved = [2]f32{ drag.offset[0] + (context.pointer.x - drag.pointer.x) / drag.scale, drag.offset[1] + (context.pointer.y - drag.pointer.y) / drag.scale };
                const anchor = &node.layout.anchor.?;
                const step: f32 = if (self.grid) grid_step_px else 1;
                const rounded = [2]f32{ @round(moved[0] / step) * step, @round(moved[1] / step) * step };
                if (!std.meta.eql(anchor.offset, rounded)) {
                    anchor.offset = rounded;
                    outcome.moved = true;
                }
            }
        }
        return outcome;
    }
};

/// The node a drag holds, while it is still pinned.
fn dragged(document: *Document, drag: Drag) ?*ui_scene.Node {
    var buffer: [ui_scene.max_depth]u16 = undefined;
    const path = ui_scenes.layout.pathOf(&document.scene().root, drag.index, &buffer) orelse return null;
    const node = ui_scene.nodeAt(&document.scene().root, path) orelse return null;
    return if (node.layout.anchor != null) node else null;
}

/// The selected node's name on a small chip just above its top left (inside it when that is off
/// the screen), so it is clear what is selected.
fn nameTag(context: *ui.Context, name: []const u8, rect: ui.Rect, viewport: ui.Rect) void {
    if (name.len == 0) return;
    const b = context.builder();
    const size: f32 = 11;
    const width = context.font.measure(name, size) + 12;
    const tag = b.node(0, .{ .width = width, .height = 18, .padding = .{ .left = 6, .right = 6, .top = 2 }, .z_index = 4 }, .{ .surface = .tooltip }, &.{
        b.node(0, .{}, .{ .text = .{ .value = name, .size = size } }, &.{}) catch return,
    }) catch return;
    const above = rect.y - 20;
    tag.overlay = .{ .point = .init(@max(viewport.x, rect.x), if (above >= viewport.y) above else rect.y + 2) };
    context.element(tag);
}

const Grid = struct { color: ui.Color, step: f32 };
const Box = union(enum) { fill: ui.Color, outline: ui.Color, grid: Grid };

/// A box painted over the page at `rect`, taking no presses.
fn overlayBox(context: *ui.Context, rect: ui.Rect, box: Box, z_index: i16) !void {
    const b = context.builder();
    const held = try b.allocator.create(Box);
    held.* = box;
    const element = try b.node(0, .{ .width = rect.w, .height = rect.h, .z_index = z_index }, .{ .custom = .{ .context = held, .draw = drawBox } }, &.{});
    element.overlay = .{ .point = .{ .x = rect.x, .y = rect.y } };
    context.element(element);
}

fn drawBox(context: *const anyopaque, canvas: *ui.Canvas, rect: ui.Rect) anyerror!void {
    const box: *const Box = @ptrCast(@alignCast(context));
    switch (box.*) {
        .fill => |color| try canvas.rect(rect, color),
        .outline => |color| try canvas.outline(rect, color),
        .grid => |grid| try drawGrid(canvas, rect, grid),
    }
}

// One-unit lines across `rect` every `grid.step`, from its top left; the finest lines are left
// out when they would crowd together, keeping the stronger ones.
fn drawGrid(canvas: *ui.Canvas, rect: ui.Rect, grid: Grid) !void {
    const every: usize = if (grid.step >= 6) 1 else 5;
    const step = grid.step * @as(f32, @floatFromInt(every));
    if (step < 6) return;
    var line: usize = 0;
    while (@as(f32, @floatFromInt(line)) * step <= rect.w) : (line += 1) {
        const alpha: f32 = if ((line * every) % 5 == 0) 0.6 else 0.25;
        try canvas.rectAlpha(.{ .x = rect.x + @as(f32, @floatFromInt(line)) * step, .y = rect.y, .w = 1, .h = rect.h }, grid.color, alpha);
    }
    line = 0;
    while (@as(f32, @floatFromInt(line)) * step <= rect.h) : (line += 1) {
        const alpha: f32 = if ((line * every) % 5 == 0) 0.6 else 0.25;
        try canvas.rectAlpha(.{ .x = rect.x, .y = rect.y + @as(f32, @floatFromInt(line)) * step, .w = rect.w, .h = 1 }, grid.color, alpha);
    }
}

test "clicking a node in the preview picks it, even pressed and let go between two frames" {
    const gpa = std.testing.allocator;
    var document = try Document.init(gpa, "resources/hud.ui.zon", "", ui_scene.template);
    defer document.deinit();
    var state = ui_scenes.State{ .gpa = gpa };
    defer state.deinit();
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    var preview = Preview{ .images = .{ .gpa = gpa } };
    defer preview.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };

    // Lay it out once, then click inside the template's title, 32 design pixels in from the top left.
    context.newFrame(viewport);
    _ = preview.build(&context, &document, &state, .{}, viewport, 0);
    _ = try context.render();
    const shown = preview.shown.?;
    const at = ui.Vec2{ .x = shown.viewport.x + 40 * shown.scale, .y = shown.viewport.y + 44 * shown.scale };
    context.handle(.{ .pointer_move = at });
    context.handle(.{ .pointer_down = .{ .position = at, .button = .left, .clicks = 1 } });
    context.handle(.{ .pointer_up = .{ .position = at, .button = .left } });

    context.newFrame(viewport);
    const outcome = preview.build(&context, &document, &state, .{}, viewport, 0);
    _ = try context.render();
    try std.testing.expectEqual(@as(?u32, 1), outcome.picked);
}

test "a text node is laid out and painted in the font it chose" {
    const gpa = std.testing.allocator;
    var font = try ui.Font.init(gpa, ui.default_font);
    defer font.deinit();
    var mono = try ui.Font.initCompanion(gpa, @embedFile("mono_font"), &font, &.{16});
    defer mono.deinit();
    const fonts = struct {
        fn get(context: *anyopaque, key: []const u8) ?*const ui.Font {
            return if (std.mem.eql(u8, key, "mono")) @ptrCast(@alignCast(context)) else null;
        }
    };
    var sources = ui_scenes.layout.Sources.plain(&font);
    sources.context = &mono;
    sources.text_font = fonts.get;
    var children = [_]ui_scene.Node{
        .{ .name = "plain", .widget = .{ .text = .{ .value = "iiii" } } },
        .{ .name = "mono", .widget = .{ .text = .{ .value = "iiii", .font = "mono" } } },
    };
    const scene = ui_scene.UiScene{ .root = .{ .layout = .{ .width = .fill, .height = .fill }, .children = &children } };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const placed = try ui_scenes.layout.place(arena.allocator(), &scene, sources, .{ .x = 0, .y = 0, .w = 400, .h = 300 }, 1);

    // A monospace "i" is as wide as any letter, so the text in it is wider.
    try std.testing.expectApproxEqAbs(mono.measure("iiii", 16), placed[2].rect.w, 0.01);
    try std.testing.expect(placed[2].rect.w > placed[1].rect.w);

    // Painting draws the node in it and gives the canvas its own font back.
    const vertices = try gpa.alloc(ui.Vertex, 4096);
    defer gpa.free(vertices);
    var canvas = ui.Canvas.init(vertices, &font);
    try ui_scenes.paint.paint(&canvas, .{ .placed = placed, .scale = 1, .fonts = .{ .context = &mono, .get = fonts.get } });
    try std.testing.expect(canvas.font == &font);
    try std.testing.expect(canvas.len > 0);
}
