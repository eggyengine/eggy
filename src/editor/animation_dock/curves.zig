//! The Animation panel's curve view: a blending track's values drawn against time, one curve
//! per axis over the timeline's own time scale, with its keys to drag up and down.
// ponytail: spans bend only by their key's `Ease`, no free tangents; add per-key tangents to the
// clip format when people ask to shape a curve by hand.
const std = @import("std");
const eggy = @import("eggy");
const timeline = @import("timeline.zig");

const ui = eggy.ui;
const Track = eggy.assets.clip.Track;
const Property = eggy.assets.clip.Property;

/// How tall the graph is drawn.
pub const height: f32 = 240;
/// Space above and below the curves, so keys at the ends stay whole.
const margin: f32 = 14;
const key_half: f32 = 5;
const pick_radius: f32 = 8;

/// The axes' colors: X red, Y green, Z blue, as the gizmo draws them.
pub const axis_colors = [3][3]f32{ .{ 0.95, 0.55, 0.48 }, .{ 0.84, 0.91, 0.60 }, .{ 0.44, 0.66, 0.86 } };
const axis_names = [3][]const u8{ "X", "Y", "Z" };

/// How many of a key's values a property uses.
pub fn axesOf(property: Property) usize {
    return switch (property) {
        .position, .rotation_deg, .scale => 3,
        else => 1,
    };
}

/// Whether a track has a curve: it blends between numbers.
pub fn hasCurve(property: Property) bool {
    return !property.discrete() and !property.textual();
}

/// The values the graph spans, bottom to top.
pub const Range = struct {
    low: f32,
    high: f32,

    /// The y of `value` from the graph's top, `h` tall.
    pub fn yOf(self: Range, value: f32, h: f32) f32 {
        const t = (value - self.low) / @max(1e-6, self.high - self.low);
        return margin + (1 - t) * @max(1, h - margin * 2);
    }

    /// The value across `points` of a graph `h` tall.
    pub fn valueAcross(self: Range, points: f32, h: f32) f32 {
        return points / @max(1, h - margin * 2) * (self.high - self.low);
    }
};

/// The values `track`'s keys hold on the axes it uses, with a little room around them; at least
/// one unit across, so a flat curve sits in the middle.
pub fn rangeOf(track: Track) Range {
    const axes = axesOf(track.property);
    var low: f32 = std.math.inf(f32);
    var high: f32 = -std.math.inf(f32);
    for (track.keys) |key| for (key.value[0..axes]) |value| {
        low = @min(low, value);
        high = @max(high, value);
    };
    if (low > high) return .{ .low = -1, .high = 1 };
    const pad = @max(0.5, (high - low) * 0.1);
    const middle = (low + high) / 2;
    const half = @max(high - middle + pad, 0.5);
    return .{ .low = middle - half, .high = middle + half };
}

/// A key's value on one axis.
pub const Point = struct { key: usize, axis: usize };

/// The key point of `track` nearest `x`, `y` (from the graph's top left), if one is in reach.
pub fn pointNear(layout: timeline.Layout, range: Range, h: f32, track: Track, x: f32, y: f32) ?Point {
    var best: ?Point = null;
    var best_distance: f32 = pick_radius;
    for (track.keys, 0..) |key, index| {
        if (!layout.shows(key.time_s)) continue;
        const dx = layout.xOf(key.time_s) - x;
        for (key.value[0..axesOf(track.property)], 0..) |value, axis| {
            const dy = range.yOf(value, h) - y;
            const distance = @sqrt(dx * dx + dy * dy);
            if (distance <= best_distance) {
                best = .{ .key = index, .axis = axis };
                best_distance = distance;
            }
        }
    }
    return best;
}

/// What the graph draws.
pub const Graph = struct {
    /// The track as shown: a key being dragged already holds where it is dragged to.
    track: Track,
    target: []const u8,
    property: []const u8,
    range: Range,
    view: timeline.View,
    head_s: f32,
    recording: bool,
    /// Whether each key is picked.
    picked: []const bool,
    /// The point being dragged.
    held: ?Point,
};

pub fn graphPaint(arena: std.mem.Allocator, graph: Graph) ui.Layout.Paint {
    const drawing = arena.create(Graph) catch return .none;
    drawing.* = graph;
    return .{ .custom = .{ .context = drawing, .draw = drawGraph } };
}

fn drawGraph(context: *const anyopaque, c: *ui.Canvas, area: ui.Rect) anyerror!void {
    const graph: *const Graph = @ptrCast(@alignCast(context));
    const layout = timeline.Layout{ .width = area.w, .view = graph.view };
    const text_size = c.theme.small_text_size - 1;
    const axes = axesOf(graph.track.property);
    const line_color = c.theme.border;

    // The gutter: what the curves are, and each axis's value at the head.
    try c.textIn(.{ .x = area.x + 8, .y = area.y + 6, .w = timeline.label_width - 16, .h = 18 }, graph.target, text_size + 1, c.theme.foreground, .start);
    try c.textIn(.{ .x = area.x + 8, .y = area.y + 24, .w = timeline.label_width - 16, .h = 18 }, graph.property, text_size, c.theme.muted_foreground, .start);
    const now = graph.track.valueAt(graph.head_s) orelse .{ 0, 0, 0 };
    for (0..axes) |axis| {
        const y = area.y + 52 + @as(f32, @floatFromInt(axis)) * 22;
        try c.roundRect(.{ .x = area.x + 8, .y = y + 4, .w = 10, .h = 10 }, axis_colors[axis], 3);
        if (axes > 1) try c.textIn(.{ .x = area.x + 24, .y = y, .w = 20, .h = 18 }, axis_names[axis], text_size, c.theme.foreground, .start);
        var buffer: [32]u8 = undefined;
        const shown = std.fmt.bufPrint(&buffer, "{d:.2}", .{now[axis]}) catch "";
        try c.textIn(.{ .x = area.x + 44, .y = y, .w = timeline.label_width - 52, .h = 18 }, shown, text_size, c.theme.muted_foreground, .end);
    }

    // The lane, with a line at each round value and each numbered tick.
    const left = area.x + timeline.label_width;
    const right = area.x + area.w;
    try c.rect(.{ .x = left, .y = area.y, .w = @max(0, right - left), .h = area.h }, c.theme.background);
    const step = valueStep(graph.range.high - graph.range.low);
    var value = @ceil(graph.range.low / step) * step;
    while (value <= graph.range.high) : (value += step) {
        const y = area.y + graph.range.yOf(value, area.h);
        try c.rect(.{ .x = left, .y = y, .w = right - left, .h = 1 }, line_color);
        var buffer: [32]u8 = undefined;
        const shown = std.fmt.bufPrint(&buffer, "{d}", .{@round(value / step) * step}) catch "";
        try c.textIn(.{ .x = left + 4, .y = y - 16, .w = 60, .h = 14 }, shown, text_size - 1, c.theme.muted_foreground, .start);
    }
    const tick = timeline.tickStep(graph.view.shown_s());
    var time = @ceil(graph.view.start_s / tick) * tick;
    while (time <= graph.view.start_s + graph.view.shown_s()) : (time += tick) {
        try c.rect(.{ .x = area.x + layout.xOf(time), .y = area.y, .w = 1, .h = area.h }, line_color);
    }

    // The curves, sampled every few points across the lane; then each key on each.
    for (0..axes) |axis| {
        const color = axis_colors[axis];
        const width: f32 = if (graph.held != null and graph.held.?.axis == axis) 2.5 else 1.75;
        var before: ?[2]f32 = null;
        var x = left;
        while (x <= right) : (x += 3) {
            const at = layout.timeAtAny(x - area.x);
            const sample = graph.track.valueAt(at) orelse break;
            const point = [2]f32{ x, area.y + graph.range.yOf(sample[axis], area.h) };
            if (before) |from| try segment(c, from, point, width, color);
            before = point;
        }
    }
    for (graph.track.keys, 0..) |key, index| {
        if (!layout.shows(key.time_s)) continue;
        const x = area.x + layout.xOf(key.time_s);
        for (0..axes) |axis| {
            const y = area.y + graph.range.yOf(key.value[axis], area.h);
            const held = if (graph.held) |point| point.key == index and point.axis == axis else false;
            const picked = index < graph.picked.len and graph.picked[index];
            const half = if (held) key_half + 1.5 else key_half;
            if (picked or held) try diamond(c, x, y, half + 2, c.theme.primary);
            try diamond(c, x, y, half, if (held) c.theme.primary else c.theme.foreground);
        }
    }
    if (layout.shows(graph.head_s)) {
        const head_color: [3]f32 = if (graph.recording) .{ 0.98, 0.44, 0.40 } else c.theme.primary;
        try c.rect(.{ .x = area.x + layout.xOf(graph.head_s) - 1, .y = area.y, .w = 2, .h = area.h }, head_color);
    }
}

/// The gap between value lines, a round number, so about four fit across `span`.
fn valueStep(span: f32) f32 {
    const rough = @max(1e-4, span / 4);
    const power = std.math.pow(f32, 10, @floor(std.math.log10(rough)));
    for ([_]f32{ 1, 2, 5, 10 }) |factor| {
        if (power * factor >= rough) return power * factor;
    }
    return power * 10;
}

/// A line from `a` to `b`, `width` thick.
fn segment(c: *ui.Canvas, a: [2]f32, b: [2]f32, width: f32, color: [3]f32) !void {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const length = @sqrt(dx * dx + dy * dy);
    if (length < 0.01) return;
    const nx = -dy / length * width / 2;
    const ny = dx / length * width / 2;
    const rgba = [4]f32{ color[0], color[1], color[2], 1 };
    const p0 = [2]f32{ a[0] + nx, a[1] + ny };
    const p1 = [2]f32{ a[0] - nx, a[1] - ny };
    const p2 = [2]f32{ b[0] + nx, b[1] + ny };
    const p3 = [2]f32{ b[0] - nx, b[1] - ny };
    try c.triangle(.{ p0, p1, p2 }, .{ rgba, rgba, rgba });
    try c.triangle(.{ p1, p3, p2 }, .{ rgba, rgba, rgba });
}

fn diamond(c: *ui.Canvas, x: f32, y: f32, half: f32, color: [3]f32) !void {
    const rgba = [4]f32{ color[0], color[1], color[2], 1 };
    try c.triangle(.{ .{ x, y - half }, .{ x - half, y }, .{ x + half, y } }, .{ rgba, rgba, rgba });
    try c.triangle(.{ .{ x - half, y }, .{ x, y + half }, .{ x + half, y } }, .{ rgba, rgba, rgba });
}

test "a track's range holds its keys with room around them, and a flat one sits in the middle" {
    const keys = [_]eggy.assets.clip.Key{ .{ .time_s = 0, .value = .{ 0, 2, -1 } }, .{ .time_s = 1, .value = .{ 3, 2, 0 } } };
    const range = rangeOf(.{ .target = "", .property = .position, .keys = &keys });
    try std.testing.expect(range.low < -1 and range.high > 3);
    try std.testing.expectApproxEqAbs(range.yOf(1, 200), 100, 0.01);
    const flat = [_]eggy.assets.clip.Key{.{ .time_s = 0, .value = .{ 45, 0, 0 } }};
    const fov = rangeOf(.{ .target = "", .property = .fov_deg, .keys = &flat });
    try std.testing.expectApproxEqAbs((fov.low + fov.high) / 2, 45, 0.001);
}

test "a key's point is found on the axis nearest the pointer" {
    const keys = [_]eggy.assets.clip.Key{.{ .time_s = 1, .value = .{ 0, 1, 2 } }};
    const track = Track{ .target = "", .property = .position, .keys = &keys };
    const layout = timeline.Layout{ .width = timeline.label_width + 210, .view = .{ .duration_s = 2 } };
    const range = Range{ .low = 0, .high = 2 };
    const x = layout.xOf(1);
    try std.testing.expectEqual(Point{ .key = 0, .axis = 2 }, pointNear(layout, range, 200, track, x, range.yOf(2, 200) + 2).?);
    try std.testing.expectEqual(@as(?Point, null), pointNear(layout, range, 200, track, x + 40, range.yOf(2, 200)));
}

test "value lines fall on round numbers" {
    try std.testing.expectEqual(@as(f32, 1), valueStep(4));
    try std.testing.expectEqual(@as(f32, 0.5), valueStep(1.6));
    try std.testing.expectEqual(@as(f32, 20), valueStep(70));
}
