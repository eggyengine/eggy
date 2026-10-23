//! Painting a laid-out UI scene (`layout.zig`) onto a `ui.Canvas`: each node's look (background,
//! image or nine-slice, border), then its widget, then its children, faded by its opacity and cut
//! off at its edges when it clips. The same painting serves the screen, the world (billboards) and
//! the editor's UI Designer.
const std = @import("std");
const ui = @import("weeoui");
const ui_scene = @import("eggy_assets").ui_scene;
const layout = @import("layout.zig");
const Placed = layout.Placed;

/// One plugin widget to draw, in a form that crosses to the game's library (C-callable).
pub const WidgetRequest = extern struct {
    /// `<plugin>/<key>`, as `ui_widgets` declares it.
    key_ptr: [*]const u8,
    key_len: usize,
    /// The node's `value` text, for the widget to read as it likes.
    value_ptr: [*]const u8,
    value_len: usize,
    canvas: *ui.Canvas,
    /// Where to draw: x, y, width, height in the canvas's units.
    rect: [4]f32,
    /// Viewport units per design pixel.
    scale: f32,
    time_ms: u64,

    pub fn key(self: *const WidgetRequest) []const u8 {
        return self.key_ptr[0..self.key_len];
    }
    pub fn value(self: *const WidgetRequest) []const u8 {
        return self.value_ptr[0..self.value_len];
    }
    pub fn area(self: *const WidgetRequest) ui.Rect {
        return .{ .x = self.rect[0], .y = self.rect[1], .w = self.rect[2], .h = self.rect[3] };
    }
};

/// Draws plugins' widgets (`ui_widgets`): returns false when no plugin has the key, or its
/// hook failed (logged by the painter).
pub const WidgetPainter = extern struct {
    context: ?*anyopaque,
    paint: *const fn (context: ?*anyopaque, request: *const WidgetRequest) callconv(.c) bool,

    /// A painter that knows no widgets: each draws as a labelled placeholder.
    pub const none = WidgetPainter{ .context = null, .paint = struct {
        fn paint(_: ?*anyopaque, _: *const WidgetRequest) callconv(.c) bool {
            return false;
        }
    }.paint };
};

/// Images by asset key, decoded into the font the canvas draws with.
pub const ImageSource = struct {
    context: *anyopaque,
    get: *const fn (context: *anyopaque, key: []const u8) ?*const ui.Image,

    pub const none = ImageSource{ .context = undefined, .get = struct {
        fn get(_: *anyopaque, _: []const u8) ?*const ui.Image {
            return null;
        }
    }.get };
};

/// Text nodes' fonts by asset key, drawing into the canvas's font's atlas; null for the canvas's font.
pub const FontSource = struct {
    context: *anyopaque,
    get: *const fn (context: *anyopaque, key: []const u8) ?*const ui.Font,

    pub const none = FontSource{ .context = undefined, .get = struct {
        fn get(_: *anyopaque, _: []const u8) ?*const ui.Font {
            return null;
        }
    }.get };
};

/// Everything a paint needs beyond the canvas, for one frame.
pub const Frame = struct {
    placed: []const Placed,
    /// Viewport units per design pixel, as the scene was laid out with.
    scale: f32,
    images: ImageSource = .none,
    fonts: FontSource = .none,
    widgets: WidgetPainter = .none,
    /// For GIFs: milliseconds of a steady clock.
    time_ms: u64 = 0,
    /// Per placed node, the id its hit box has (0: none), compared with the canvas's hot widget
    /// and `pressed` to draw buttons hovered and pressed.
    ids: []const u32 = &.{},
    pressed: u32 = 0,
};

/// Paint `frame` onto `canvas`. Fails only when the canvas runs out of room (its
/// `out_of_vertices`, which the caller grows and draws again for) or a draw is refused.
pub fn paint(canvas: *ui.Canvas, frame: Frame) !void {
    var index: usize = 0;
    var themes = Themes{};
    while (index < frame.placed.len) index = try paintNode(canvas, frame, &themes, index);
}

/// The themes of the scenes painted, resolved once each.
const Themes = struct {
    scenes: [layout.max_nesting * 4]*const ui_scene.UiScene = undefined,
    themes: [layout.max_nesting * 4]ui.Theme = undefined,
    len: usize = 0,

    fn of(self: *Themes, scene: *const ui_scene.UiScene) ui.Theme {
        for (self.scenes[0..self.len], self.themes[0..self.len]) |known, theme| if (known == scene) return theme;
        const theme = resolveTheme(scene.theme);
        if (self.len < self.scenes.len) {
            self.scenes[self.len] = scene;
            self.themes[self.len] = theme;
            self.len += 1;
        }
        return theme;
    }
};

/// Paint the node at `index` and its descendants; returns the index after them.
fn paintNode(canvas: *ui.Canvas, frame: Frame, themes: *Themes, index: usize) !usize {
    const item = frame.placed[index];
    const node = item.node;
    const theme = themes.of(item.scene);
    const scale = frame.scale;
    const rect = item.rect;
    const first_vertex = canvas.len;
    const outer_clip = canvas.clip;
    defer canvas.clip = outer_clip;
    const id = if (index < frame.ids.len) frame.ids[index] else 0;
    const hot = id != 0 and canvas.hot_id == id;
    const pressed = id != 0 and frame.pressed == id;

    // The box: its background (a button's, by its state), its image, its border.
    const look = node.look;
    const radius = if (look.radius > 0) look.radius * scale else if (node.widget == .button and look.background == .none and look.image.len == 0) theme.radiusMd() * scale else 0;
    var background = colorOf(look.background, theme);
    if (node.widget == .button) {
        const button = node.widget.button;
        const normal = background orelse if (look.image.len == 0) withAlpha(theme.primary, 1) else null;
        if (pressed) {
            background = colorOf(button.pressed, theme) orelse if (normal) |color| shade(color, -0.12) else null;
        } else if (hot) {
            background = colorOf(button.hover, theme) orelse if (normal) |color| shade(color, 0.1) else null;
        } else background = normal;
    }
    if (background) |color| try fill(canvas, rect, color, radius);
    const look_image = if (item.override) |o| o.image orelse look.image else look.image;
    if (look_image.len > 0) if (frame.images.get(frame.images.context, look_image)) |image| {
        const sprite = image.frameAt(frame.time_ms);
        if (sliced(look.slice)) try nineSlice(canvas, rect, sprite, image, look.slice, scale) else try canvas.image(rect, sprite, 1);
        // An image button shows hover and press as a light or dark wash over the image.
        if (node.widget == .button and look.background == .none and (hot or pressed)) try canvas.rectAlpha(rect, if (pressed) .{ 0, 0, 0 } else .{ 1, 1, 1 }, 0.15);
    };
    if (colorOf(look.border, theme)) |color| if (look.border_width > 0) {
        const start = canvas.len;
        try canvas.roundRectStroke(rect, rgb(color), radius, look.border_width * scale);
        fade(canvas, start, color[3]);
    };

    // What the widget shows, inside the padding.
    const content = layout.contentBox(node, rect);
    switch (node.widget) {
        .panel, .scene => {},
        .text => |text| {
            const value = if (item.override) |o| o.text orelse text.value else text.value;
            const color = colorOf(text.color, theme) orelse withAlpha(theme.foreground, 1);
            const start = canvas.len;
            const alignment: ui.Canvas.TextAlign = @fromBackingInt(@intCast(@backingInt(text.alignment)));
            // In the node's own font, if it chose one, as layout measured it.
            const scene_font = canvas.font;
            defer canvas.font = scene_font;
            if (frame.fonts.get(frame.fonts.context, text.font)) |face| canvas.font = face;
            if (text.wrap) {
                try canvas.textWrappedInAligned(content, value, text.size * scale, rgb(color), alignment);
            } else {
                // One line, as tall as the layout made it, centred in the box.
                try canvas.textIn(content, value, text.size * scale, rgb(color), alignment);
            }
            fade(canvas, start, color[3]);
        },
        .button => |button| {
            const label = if (item.override) |o| o.text orelse button.label else button.label;
            const color = colorOf(button.text_color, theme) orelse withAlpha(theme.primary_foreground, 1);
            const start = canvas.len;
            try canvas.textIn(content, label, button.size * scale, rgb(color), .center);
            fade(canvas, start, color[3]);
        },
        .image => |image| {
            const key = if (item.override) |o| o.image orelse image.image else image.image;
            if (frame.images.get(frame.images.context, key)) |loaded| {
                try fitted(canvas, content, loaded, loaded.frameAt(frame.time_ms), image.fit);
            } else try placeholder(canvas, content, theme, if (key.len == 0) "No image" else "Image", scale);
        },
        .progress => |progress| {
            const value = std.math.clamp(if (item.override) |o| o.value orelse progress.value else progress.value, 0, 1);
            const round = if (look.radius > 0) radius else @min(content.w, content.h) / 2;
            if (colorOf(progress.track, theme)) |color| try fill(canvas, content, color, round);
            const filled: ui.Rect = switch (progress.direction) {
                .left_to_right => .{ .x = content.x, .y = content.y, .w = content.w * value, .h = content.h },
                .right_to_left => .{ .x = content.x + content.w * (1 - value), .y = content.y, .w = content.w * value, .h = content.h },
                .top_to_bottom => .{ .x = content.x, .y = content.y, .w = content.w, .h = content.h * value },
                .bottom_to_top => .{ .x = content.x, .y = content.y + content.h * (1 - value), .w = content.w, .h = content.h * value },
            };
            if (value > 0) if (colorOf(progress.fill, theme)) |color| try fill(canvas, filled, color, round);
        },
        .plugin => |widget| {
            if (widget.widget.len == 0 or !frame.widgets.paint(frame.widgets.context, &.{ .key_ptr = widget.widget.ptr, .key_len = widget.widget.len, .value_ptr = widget.value.ptr, .value_len = widget.value.len, .canvas = canvas, .rect = .{ content.x, content.y, content.w, content.h }, .scale = scale, .time_ms = frame.time_ms })) {
                try placeholder(canvas, content, theme, if (widget.widget.len == 0) "No widget" else widget.widget, scale);
            }
        },
    }

    // The children, cut off at the box when it clips.
    if (look.clip) canvas.clip = if (outer_clip) |clip| clip.intersection(rect) else rect;
    var next = index + 1;
    while (next < item.end) next = try paintNode(canvas, frame, themes, next);
    if (look.opacity < 1) fade(canvas, first_vertex, look.opacity);
    return next;
}

/// The theme `theme` describes: Eggy's dark or light one with its replacements.
pub fn resolveTheme(theme: ui_scene.Theme) ui.Theme {
    var resolved: ui.Theme = if (theme.base == .dark) ui.Theme.dark else .{};
    inline for (@typeInfo(ui_scene.ThemeColor).@"enum".field_names) |name| {
        if (@field(theme, name)) |color| @field(resolved, name) = color[0..3].*;
    }
    if (theme.radius) |radius| resolved.radius = radius;
    return resolved;
}

/// `color` as red, green, blue and alpha; null for none.
pub fn colorOf(color: ui_scene.Color, theme: ui.Theme) ?[4]f32 {
    return switch (color) {
        .none => null,
        .color => |rgba| rgba,
        .theme => |token| switch (token) {
            inline else => |tag| withAlpha(@field(theme, @tagName(tag)), 1),
        },
    };
}

fn withAlpha(color: ui.Color, alpha: f32) [4]f32 {
    return .{ color[0], color[1], color[2], alpha };
}

fn rgb(color: [4]f32) ui.Color {
    return color[0..3].*;
}

/// `color` lighter (positive `amount`) or darker.
fn shade(color: [4]f32, amount: f32) [4]f32 {
    var out = color;
    for (out[0..3]) |*channel| channel.* = std.math.clamp(if (amount > 0) channel.* + (1 - channel.*) * amount else channel.* * (1 + amount), 0, 1);
    return out;
}

fn fill(canvas: *ui.Canvas, rect: ui.Rect, color: [4]f32, radius: f32) !void {
    if (color[3] <= 0) return;
    if (radius > 0) try canvas.roundRectAlpha(rect, rgb(color), radius, color[3]) else try canvas.rectAlpha(rect, rgb(color), color[3]);
}

/// Multiply the alpha of every vertex drawn since `start` by `alpha`.
fn fade(canvas: *ui.Canvas, start: usize, alpha: f32) void {
    if (alpha >= 1) return;
    for (canvas.vertices[start..canvas.len]) |*vertex| vertex.color[3] *= alpha;
}

fn sliced(slice: ui_scene.Insets) bool {
    return slice.left + slice.top + slice.right + slice.bottom > 0;
}

/// `sprite` (a frame of `image`) as a nine-slice over `rect`: `slice` (in the image's pixels) of
/// each edge keeps its size, `scale` times, and the middle stretches.
fn nineSlice(canvas: *ui.Canvas, rect: ui.Rect, sprite: ui.Glyph, image: *const ui.Image, slice: ui_scene.Insets, scale: f32) !void {
    // The atlas may hold the image smaller than its file; slices are in the file's pixels.
    const to_atlas = [2]f32{ @as(f32, @floatFromInt(sprite.w)) / @as(f32, @floatFromInt(@max(1, image.width))), @as(f32, @floatFromInt(sprite.h)) / @as(f32, @floatFromInt(@max(1, image.height))) };
    const source_x = [4]f32{ 0, slice.left * to_atlas[0], @as(f32, @floatFromInt(sprite.w)) - slice.right * to_atlas[0], @floatFromInt(sprite.w) };
    const source_y = [4]f32{ 0, slice.top * to_atlas[1], @as(f32, @floatFromInt(sprite.h)) - slice.bottom * to_atlas[1], @floatFromInt(sprite.h) };
    const left = @min(slice.left * scale, rect.w / 2);
    const right = @min(slice.right * scale, rect.w / 2);
    const top = @min(slice.top * scale, rect.h / 2);
    const bottom = @min(slice.bottom * scale, rect.h / 2);
    const dest_x = [4]f32{ rect.x, rect.x + left, rect.x + rect.w - right, rect.x + rect.w };
    const dest_y = [4]f32{ rect.y, rect.y + top, rect.y + rect.h - bottom, rect.y + rect.h };
    for (0..3) |row| for (0..3) |column| {
        const sx = @round(source_x[column]);
        const sy = @round(source_y[row]);
        const sw = @round(source_x[column + 1]) - sx;
        const sh = @round(source_y[row + 1]) - sy;
        if (sw <= 0 or sh <= 0) continue;
        var part = sprite;
        part.x += @intFromFloat(sx);
        part.y += @intFromFloat(sy);
        part.w = @intFromFloat(sw);
        part.h = @intFromFloat(sh);
        try canvas.image(.{ .x = dest_x[column], .y = dest_y[row], .w = dest_x[column + 1] - dest_x[column], .h = dest_y[row + 1] - dest_y[row] }, part, 1);
    };
}

/// `sprite` (a frame of `image`) in `box` as `fit` says.
fn fitted(canvas: *ui.Canvas, box: ui.Rect, image: *const ui.Image, sprite: ui.Glyph, fit: ui_scene.Fit) !void {
    if (box.w <= 0 or box.h <= 0) return;
    const width: f32 = @floatFromInt(@max(1, image.width));
    const height: f32 = @floatFromInt(@max(1, image.height));
    const scale = switch (fit) {
        .stretch => return canvas.image(box, sprite, 1),
        .contain => @min(box.w / width, box.h / height),
        .cover => @max(box.w / width, box.h / height),
    };
    const shown = ui.Rect{ .x = box.x + (box.w - width * scale) / 2, .y = box.y + (box.h - height * scale) / 2, .w = width * scale, .h = height * scale };
    const outer = canvas.clip;
    defer canvas.clip = outer;
    if (fit == .cover) canvas.clip = if (outer) |clip| clip.intersection(box) else box;
    try canvas.image(shown, sprite, 1);
}

/// A box saying what should be there: an unset image, a plugin widget the game doesn't have.
fn placeholder(canvas: *ui.Canvas, box: ui.Rect, theme: ui.Theme, label: []const u8, scale: f32) !void {
    if (box.w <= 0 or box.h <= 0) return;
    try canvas.rectAlpha(box, theme.muted, 0.6);
    try canvas.roundRectStroke(box, theme.border, 0, @max(1, scale));
    try canvas.textIn(box, label, @min(13 * scale, box.h * 0.6), theme.muted_foreground, .center);
}

test "a scene paints its boxes, text and placeholders" {
    const gpa = std.testing.allocator;
    var font = try ui.Font.init(gpa, ui.default_font);
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var children = [_]ui_scene.Node{
        .{ .name = "title", .widget = .{ .text = .{ .value = "Hi" } }, .look = .{ .opacity = 0.5 } },
        .{ .name = "go", .widget = .{ .button = .{} }, .layout = .{ .padding = .{ .left = 8, .right = 8 } } },
        .{ .name = "hp", .widget = .{ .progress = .{ .value = 0.25 } } },
        .{ .name = "pic", .widget = .{ .image = .{} }, .look = .{ .border = .{ .theme = .border }, .border_width = 1 } },
    };
    const scene = ui_scene.UiScene{ .root = .{ .look = .{ .background = .{ .theme = .card }, .radius = 4 }, .children = &children } };
    const placed = try layout.place(arena.allocator(), &scene, .plain(&font), .{ .x = 0, .y = 0, .w = 400, .h = 300 }, 1);
    const vertices = try gpa.alloc(ui.Vertex, 8192);
    defer gpa.free(vertices);
    var canvas = ui.Canvas.init(vertices, &font);
    try paint(&canvas, .{ .placed = placed, .scale = 1 });
    try std.testing.expect(canvas.len > 0);
    try std.testing.expect(!canvas.out_of_vertices);
}

test "theme colors resolve from the base and the scene's replacements" {
    const theme = resolveTheme(.{ .base = .dark, .primary = .{ 1, 0, 0, 1 }, .radius = 2 });
    try std.testing.expectEqual(ui.Color{ 1, 0, 0 }, theme.primary);
    try std.testing.expectEqual(@as(f32, 2), theme.radius);
    try std.testing.expectEqual(ui.Theme.dark.card, theme.card);
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, colorOf(.{ .theme = .primary }, theme).?);
    try std.testing.expect(colorOf(.none, theme) == null);
}
