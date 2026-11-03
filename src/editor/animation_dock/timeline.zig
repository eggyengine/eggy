//! The Animation panel's timeline: a ruler of seconds, and a row per track of the clip with its
//! target, its property and a diamond at each key, the scrub head across them all. Rows and the
//! ruler share one layout (`Layout`), so a click maps back to a time or a key the same way.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const Track = eggy.assets.clip.Track;
const Property = eggy.assets.clip.Property;

/// The gutter on the left of each row for its target and property, in points.
pub const label_width: f32 = 210;
/// A key this close to the pointer is the one clicked, in points.
const pick_radius: f32 = 7;
const key_half: f32 = 4.5;
const row_height: f32 = 24;
const ruler_height: f32 = 22;

/// Where times sit across a row `width` points wide, for a clip `duration_s` long.
pub const Layout = struct {
    width: f32,
    duration_s: f32,

    /// The x of `time_s`, from the row's left edge.
    pub fn xOf(self: Layout, time_s: f32) f32 {
        const t = if (self.duration_s > 0) std.math.clamp(time_s / self.duration_s, 0, 1) else 0;
        return label_width + t * self.span();
    }

    /// The time at `x` from the row's left edge, held inside the clip; null over the gutter.
    pub fn timeAt(self: Layout, x: f32) ?f32 {
        if (x < label_width - key_half) return null;
        const t = std.math.clamp((x - label_width) / @max(1, self.span()), 0, 1);
        return t * self.duration_s;
    }

    /// The key of `keys` nearest `x`, if one is within reach.
    pub fn keyNear(self: Layout, keys: []const eggy.assets.clip.Key, x: f32) ?usize {
        var best: ?usize = null;
        var best_distance: f32 = pick_radius;
        for (keys, 0..) |key, index| {
            const distance = @abs(self.xOf(key.time_s) - x);
            if (distance <= best_distance) {
                best = index;
                best_distance = distance;
            }
        }
        return best;
    }

    fn span(self: Layout) f32 {
        return @max(0, self.width - label_width - key_half * 2);
    }
};

/// What kind of thing a property moves, for the color of its row.
fn colorOf(property: Property) [3]f32 {
    return switch (property) {
        .position, .rotation_deg, .scale, .morph_weight => .{ 0.37, 0.75, 0.66 },
        .fov_deg => .{ 0.44, 0.66, 0.86 },
        .visible, .text => .{ 0.36, 0.80, 0.55 },
        .sound => .{ 0.71, 0.59, 0.88 },
        .event => .{ 0.91, 0.54, 0.42 },
        .sprite_frame => .{ 0.96, 0.75, 0.29 },
    };
}

/// One track's row: what it acts on, its keys, the head, and the key picked.
pub const Row = struct {
    target: []const u8,
    property: []const u8,
    color: [3]f32,
    /// Spans between keys are drawn for tracks that blend; discrete ones show only their keys.
    blends: bool,
    times_s: []const f32,
    /// The label beside each key (a line of text, a sound, an event's name), or "".
    labels: []const []const u8,
    duration_s: f32,
    head_s: f32,
    selected_key: ?usize,
    recording: bool,
};

/// A paint drawing `row`, copied into `arena`.
pub fn rowPaint(arena: std.mem.Allocator, row: Row) ui.Layout.Paint {
    const drawing = arena.create(Row) catch return .none;
    drawing.* = row;
    return .{ .custom = .{ .context = drawing, .draw = drawRow } };
}

/// The row for `track` of a clip `duration_s` long: its keys' times and labels in `arena`.
pub fn rowOf(arena: std.mem.Allocator, track: Track, target: []const u8, duration_s: f32, head_s: f32, selected_key: ?usize, recording: bool) !Row {
    const times = try arena.alloc(f32, track.keys.len);
    const labels = try arena.alloc([]const u8, track.keys.len);
    for (track.keys, times, labels) |key, *time, *label| {
        time.* = key.time_s;
        label.* = try keyLabel(arena, track.property, key);
    }
    var buffer: [96]u8 = undefined;
    return .{
        .target = target,
        .property = try arena.dupe(u8, track.label(&buffer)),
        .color = colorOf(track.property),
        .blends = !track.property.discrete(),
        .times_s = times,
        .labels = labels,
        .duration_s = duration_s,
        .head_s = head_s,
        .selected_key = selected_key,
        .recording = recording,
    };
}

/// How a key reads beside its diamond: the text it carries, or its number where that says more
/// than the diamond (a field of view, on or off, a frame).
pub fn keyLabel(arena: std.mem.Allocator, property: Property, key: eggy.assets.clip.Key) ![]const u8 {
    return switch (property) {
        .text, .event => key.text,
        .sound => std.fs.path.basename(key.text),
        .fov_deg => try std.fmt.allocPrint(arena, "{d:.0}°", .{key.value[0]}),
        .visible => if (key.value[0] > 0.5) "on" else "off",
        .sprite_frame => try std.fmt.allocPrint(arena, "{d:.0}", .{key.value[0]}),
        .position, .rotation_deg, .scale, .morph_weight => "",
    };
}

fn drawRow(context: *const anyopaque, c: *ui.Canvas, area: ui.Rect) anyerror!void {
    const row: *const Row = @ptrCast(@alignCast(context));
    const layout = Layout{ .width = area.w, .duration_s = row.duration_s };
    const middle = area.y + area.h / 2;
    const text_size = c.theme.small_text_size - 1;

    // The gutter: a swatch of the track's kind, the target, then the property.
    try c.roundRect(.{ .x = area.x + 2, .y = middle - 3.5, .w = 7, .h = 7 }, row.color, 2);
    try c.textIn(.{ .x = area.x + 16, .y = area.y, .w = label_width * 0.5 - 16, .h = area.h }, row.target, text_size, c.theme.foreground, .start);
    try c.textIn(.{ .x = area.x + label_width * 0.5, .y = area.y, .w = label_width * 0.5 - 10, .h = area.h }, row.property, text_size, c.theme.muted_foreground, .end);

    // The lane, and for a blending track the span its keys cover.
    const lane = ui.Rect{ .x = area.x + label_width, .y = area.y + 1, .w = @max(0, area.w - label_width), .h = area.h - 2 };
    try c.rect(lane, c.theme.background);
    if (row.blends and row.times_s.len > 1) {
        const from = area.x + layout.xOf(row.times_s[0]);
        const to = area.x + layout.xOf(row.times_s[row.times_s.len - 1]);
        try c.roundRectAlpha(.{ .x = from, .y = middle - 3, .w = to - from, .h = 6 }, row.color, 3, 0.35);
    }

    // Each key as a diamond with its label after it; the picked one outlined and bright.
    for (row.times_s, row.labels, 0..) |time, label, index| {
        const x = area.x + layout.xOf(time);
        const picked = row.selected_key == index;
        const keyed_now = row.recording and @abs(time - row.head_s) < eggy.assets.clip.same_time_s * 10;
        const fill: [3]f32 = if (picked) c.theme.foreground else if (keyed_now) .{ 0.98, 0.44, 0.40 } else row.color;
        if (picked) try diamond(c, x, middle, key_half + 2, c.theme.primary);
        try diamond(c, x, middle, key_half, fill);
        if (label.len > 0) try c.textIn(.{ .x = x + key_half + 4, .y = area.y, .w = 160, .h = area.h }, label, text_size, c.theme.muted_foreground, .start);
    }

    try head(c, area.x + layout.xOf(row.head_s), area.y, area.h, if (row.recording) .{ 0.98, 0.44, 0.40 } else c.theme.primary);
}

/// The ruler above the rows: a tick and number at each second (or every few, when long).
pub const Ruler = struct {
    duration_s: f32,
    head_s: f32,
    recording: bool,
};

pub fn rulerPaint(arena: std.mem.Allocator, ruler: Ruler) ui.Layout.Paint {
    const drawing = arena.create(Ruler) catch return .none;
    drawing.* = ruler;
    return .{ .custom = .{ .context = drawing, .draw = drawRuler } };
}

/// Seconds between numbered ticks, so about a dozen fit.
pub fn tickStep(duration_s: f32) f32 {
    for ([_]f32{ 0.25, 0.5, 1, 2, 5, 10, 30, 60 }) |step| if (duration_s / step <= 14) return step;
    return 120;
}

fn drawRuler(context: *const anyopaque, c: *ui.Canvas, area: ui.Rect) anyerror!void {
    const ruler: *const Ruler = @ptrCast(@alignCast(context));
    const layout = Layout{ .width = area.w, .duration_s = ruler.duration_s };
    try c.rect(.{ .x = area.x + label_width, .y = area.y, .w = @max(0, area.w - label_width), .h = area.h }, c.theme.background);
    const step = tickStep(ruler.duration_s);
    var time: f32 = 0;
    var buffer: [16]u8 = undefined;
    while (time <= ruler.duration_s + 0.0001) : (time += step) {
        const x = area.x + layout.xOf(time);
        try c.rect(.{ .x = x, .y = area.y, .w = 1, .h = area.h }, c.theme.border);
        const label = std.fmt.bufPrint(&buffer, "{d}", .{time}) catch continue;
        try c.textIn(.{ .x = x + 4, .y = area.y, .w = 40, .h = area.h }, label, c.theme.small_text_size - 1, c.theme.muted_foreground, .start);
    }
    try head(c, area.x + layout.xOf(ruler.head_s), area.y, area.h, if (ruler.recording) .{ 0.98, 0.44, 0.40 } else c.theme.primary);
}

pub const heights = struct {
    pub const row = row_height;
    pub const ruler = ruler_height;
};

fn diamond(c: *ui.Canvas, x: f32, y: f32, half: f32, color: [3]f32) !void {
    const rgba = [4]f32{ color[0], color[1], color[2], 1 };
    try c.triangle(.{ .{ x - half, y }, .{ x, y - half }, .{ x + half, y } }, .{ rgba, rgba, rgba });
    try c.triangle(.{ .{ x - half, y }, .{ x + half, y }, .{ x, y + half } }, .{ rgba, rgba, rgba });
}

fn head(c: *ui.Canvas, x: f32, y: f32, h: f32, color: [3]f32) !void {
    try c.rect(.{ .x = x - 1, .y = y, .w = 2, .h = h }, color);
}

test "times map across the lane after the gutter, and back" {
    const layout = Layout{ .width = label_width + 209, .duration_s = 10 };
    try std.testing.expectEqual(label_width, layout.xOf(0));
    try std.testing.expectEqual(label_width + 100, layout.xOf(5));
    try std.testing.expectEqual(label_width + 200, layout.xOf(99));
    try std.testing.expect(layout.timeAt(10) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 5), layout.timeAt(label_width + 100).?, 0.001);
}

test "a click picks the nearest key within reach" {
    const layout = Layout{ .width = label_width + 209, .duration_s = 10 };
    const keys = [_]eggy.assets.clip.Key{ .{ .time_s = 1 }, .{ .time_s = 1.2 }, .{ .time_s = 6 } };
    try std.testing.expectEqual(@as(?usize, 1), layout.keyNear(&keys, layout.xOf(1.25)));
    try std.testing.expectEqual(@as(?usize, 2), layout.keyNear(&keys, layout.xOf(6) + 5));
    try std.testing.expect(layout.keyNear(&keys, layout.xOf(4)) == null);
}

test "ticks are spaced so about a dozen fit" {
    try std.testing.expectEqual(@as(f32, 1), tickStep(12));
    try std.testing.expectEqual(@as(f32, 0.25), tickStep(2));
    try std.testing.expectEqual(@as(f32, 10), tickStep(90));
}
