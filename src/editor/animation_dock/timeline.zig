//! The Animation panel's timeline: a ruler of seconds, and a row per track of the clip with its
//! target, its property and a diamond at each key, the scrub head across them all. Rows and the
//! ruler share one layout (`Layout`) over the stretch of the clip in view, so a click maps back
//! to a time or a key the same way.
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

/// The stretch of a clip `duration_s` long in view: from `start_s`, `span_s` long; the whole
/// clip when `span_s` is 0.
pub const View = struct {
    duration_s: f32,
    start_s: f32 = 0,
    span_s: f32 = 0,

    /// How many seconds are in view.
    pub fn shown_s(self: View) f32 {
        return if (self.span_s > 0) self.span_s else self.duration_s;
    }

    /// This view zoomed by `factor` (above 1 closer in) about `at_s`, which stays where it is,
    /// and kept inside the clip; zoomed all the way out it shows the whole clip.
    pub fn zoomed(self: View, factor: f32, at_s: f32) View {
        if (!(self.duration_s > 0) or !(factor > 0)) return self;
        const shown = self.shown_s();
        const span = std.math.clamp(shown / factor, min_span_s, self.duration_s);
        if (span >= self.duration_s) return .{ .duration_s = self.duration_s };
        const share = (at_s - self.start_s) / shown;
        return (View{ .duration_s = self.duration_s, .start_s = at_s - share * span, .span_s = span }).held();
    }

    /// This view moved later by `seconds` (earlier when negative), kept inside the clip.
    pub fn panned(self: View, seconds: f32) View {
        if (self.span_s <= 0) return self;
        var moved = self;
        moved.start_s += seconds;
        return moved.held();
    }

    /// The view moved just enough to show `time_s`.
    pub fn following(self: View, time_s: f32) View {
        if (self.span_s <= 0) return self;
        if (time_s < self.start_s) return self.panned(time_s - self.start_s);
        if (time_s > self.start_s + self.span_s) return self.panned(time_s - self.start_s - self.span_s);
        return self;
    }

    /// This view for the clip at its new length `duration_s`.
    pub fn resized(self: View, duration_s: f32) View {
        if (self.span_s <= 0 or self.span_s >= duration_s) return .{ .duration_s = duration_s };
        var view = self;
        view.duration_s = duration_s;
        return view.held();
    }

    fn held(self: View) View {
        var view = self;
        view.span_s = @min(view.span_s, view.duration_s);
        view.start_s = std.math.clamp(view.start_s, 0, view.duration_s - view.span_s);
        return view;
    }
};

/// The closest a view zooms in, in seconds across.
const min_span_s: f32 = 0.1;
/// Dragged keys land on frames of this rate.
pub const snap_fps: f32 = 30;

/// How far dragged keys move: the pointer pressed at `anchor_s` on a key at `key_s` and is now
/// at `pointer_s`. The key lands on a whole frame, or on the head at `head_s` when within reach
/// of it, unless `free`; the earliest dragged key, at `earliest_s`, stops at 0.
pub fn dragShift(layout: Layout, anchor_s: f32, key_s: f32, pointer_s: f32, head_s: f32, earliest_s: f32, free: bool) f32 {
    var landing = key_s + (pointer_s - anchor_s);
    if (!free) {
        landing = if (@abs(layout.xOf(landing) - layout.xOf(head_s)) <= pick_radius) head_s else @round(landing * snap_fps) / snap_fps;
    }
    return @max(landing - key_s, -earliest_s);
}

/// Where times sit across a row `width` points wide, for `view`.
pub const Layout = struct {
    width: f32,
    view: View,

    /// The x of `time_s`, from the row's left edge; outside the lane when out of view.
    pub fn xOf(self: Layout, time_s: f32) f32 {
        const shown = self.view.shown_s();
        const t = if (shown > 0) (time_s - self.view.start_s) / shown else 0;
        return label_width + t * self.span();
    }

    /// Whether `time_s` is in view.
    pub fn shows(self: Layout, time_s: f32) bool {
        const x = self.xOf(time_s);
        return x >= label_width - 0.5 and x <= label_width + self.span() + 0.5;
    }

    /// The time at `x` from the row's left edge, held inside the view; null over the gutter.
    pub fn timeAt(self: Layout, x: f32) ?f32 {
        if (x < label_width - key_half) return null;
        return self.timeAtAny(x);
    }

    /// The time at `x`, held inside the view even over the gutter, for a drag that strays there.
    pub fn timeAtAny(self: Layout, x: f32) f32 {
        const t = std.math.clamp((x - label_width) / @max(1, self.span()), 0, 1);
        return self.view.start_s + t * self.view.shown_s();
    }

    /// Seconds across `points` of the lane.
    pub fn secondsAcross(self: Layout, points: f32) f32 {
        return points / @max(1, self.span()) * self.view.shown_s();
    }

    /// The key of `keys` nearest `x`, if one is in view and within reach.
    pub fn keyNear(self: Layout, keys: []const eggy.assets.clip.Key, x: f32) ?usize {
        var best: ?usize = null;
        var best_distance: f32 = pick_radius;
        for (keys, 0..) |key, index| {
            if (!self.shows(key.time_s)) continue;
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

/// One track's row: what it acts on, its keys, the head, and the keys picked.
pub const Row = struct {
    target: []const u8,
    property: []const u8,
    color: [3]f32,
    /// Spans between keys are drawn for tracks that blend; discrete ones show only their keys.
    blends: bool,
    times_s: []const f32,
    /// The label beside each key (a line of text, a sound, an event's name), or "".
    labels: []const []const u8,
    /// Whether each key is picked.
    picked: []const bool,
    /// Whether the track itself is picked (from its gutter).
    track_picked: bool,
    /// How far the picked keys are being dragged; drawn there, and faintly where they were.
    drag_s: f32,
    view: View,
    head_s: f32,
    recording: bool,
};

/// A paint drawing `row`, copied into `arena`.
pub fn rowPaint(arena: std.mem.Allocator, row: Row) ui.Layout.Paint {
    const drawing = arena.create(Row) catch return .none;
    drawing.* = row;
    return .{ .custom = .{ .context = drawing, .draw = drawRow } };
}

/// How a row shows: the view, the head, what is picked, and a drag under way.
pub const RowState = struct {
    view: View,
    head_s: f32,
    /// Whether each key of the track is picked; as many as it has keys.
    picked: []const bool,
    track_picked: bool = false,
    drag_s: f32 = 0,
    recording: bool = false,
};

/// The row for `track`: its keys' times and labels in `arena`.
pub fn rowOf(arena: std.mem.Allocator, track: Track, target: []const u8, state: RowState) !Row {
    std.debug.assert(state.picked.len == track.keys.len);
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
        .picked = try arena.dupe(bool, state.picked),
        .track_picked = state.track_picked,
        .drag_s = state.drag_s,
        .view = state.view,
        .head_s = state.head_s,
        .recording = state.recording,
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
    const layout = Layout{ .width = area.w, .view = row.view };
    const middle = area.y + area.h / 2;
    const text_size = c.theme.small_text_size - 1;

    // The gutter: a swatch of the track's kind, the target, then the property; a picked track
    // is outlined.
    if (row.track_picked) try c.roundRectAlpha(.{ .x = area.x, .y = area.y + 1, .w = label_width - 4, .h = area.h - 2 }, c.theme.primary, 3, 0.18);
    try c.roundRect(.{ .x = area.x + 2, .y = middle - 3.5, .w = 7, .h = 7 }, row.color, 2);
    try c.textIn(.{ .x = area.x + 16, .y = area.y, .w = label_width * 0.5 - 16, .h = area.h }, row.target, text_size, c.theme.foreground, .start);
    try c.textIn(.{ .x = area.x + label_width * 0.5, .y = area.y, .w = label_width * 0.5 - 10, .h = area.h }, row.property, text_size, c.theme.muted_foreground, .end);

    // The lane, and for a blending track the span its keys cover, cut to the view.
    const lane = ui.Rect{ .x = area.x + label_width, .y = area.y + 1, .w = @max(0, area.w - label_width), .h = area.h - 2 };
    try c.rect(lane, c.theme.background);
    if (row.blends and row.times_s.len > 1) {
        const from = std.math.clamp(area.x + layout.xOf(row.times_s[0]), lane.x, lane.x + lane.w);
        const to = std.math.clamp(area.x + layout.xOf(row.times_s[row.times_s.len - 1]), lane.x, lane.x + lane.w);
        if (to > from) try c.roundRectAlpha(.{ .x = from, .y = middle - 3, .w = to - from, .h = 6 }, row.color, 3, 0.35);
    }

    // Each key in view as a diamond with its label after it; picked ones outlined and bright,
    // and while dragged, drawn where they would land, with a ghost where they were.
    for (row.times_s, row.labels, row.picked) |time, label, picked| {
        const dragged = picked and row.drag_s != 0;
        if (dragged and layout.shows(time)) try diamondAlpha(c, area.x + layout.xOf(time), middle, key_half, row.color, 0.35);
        const at_s = if (dragged) @max(0, time + row.drag_s) else time;
        if (!layout.shows(at_s)) continue;
        const x = area.x + layout.xOf(at_s);
        const keyed_now = row.recording and @abs(at_s - row.head_s) < eggy.assets.clip.same_time_s * 10;
        const fill: [3]f32 = if (picked) c.theme.foreground else if (keyed_now) .{ 0.98, 0.44, 0.40 } else row.color;
        if (picked) try diamond(c, x, middle, key_half + 2, c.theme.primary);
        try diamond(c, x, middle, key_half, fill);
        if (label.len > 0) try c.textIn(.{ .x = x + key_half + 4, .y = area.y, .w = 160, .h = area.h }, label, text_size, c.theme.muted_foreground, .start);
    }

    if (layout.shows(row.head_s)) try head(c, area.x + layout.xOf(row.head_s), area.y, area.h, if (row.recording) .{ 0.98, 0.44, 0.40 } else c.theme.primary);
}

/// The ruler above the rows: a tick and number at each second (or every few, when long, or
/// fractions of one, zoomed in).
pub const Ruler = struct {
    view: View,
    head_s: f32,
    recording: bool,
};

pub fn rulerPaint(arena: std.mem.Allocator, ruler: Ruler) ui.Layout.Paint {
    const drawing = arena.create(Ruler) catch return .none;
    drawing.* = ruler;
    return .{ .custom = .{ .context = drawing, .draw = drawRuler } };
}

/// Seconds between numbered ticks, so about a dozen fit across `shown_s` seconds.
pub fn tickStep(shown_s: f32) f32 {
    for ([_]f32{ 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60 }) |step| if (shown_s / step <= 14) return step;
    return 120;
}

fn drawRuler(context: *const anyopaque, c: *ui.Canvas, area: ui.Rect) anyerror!void {
    const ruler: *const Ruler = @ptrCast(@alignCast(context));
    const layout = Layout{ .width = area.w, .view = ruler.view };
    try c.rect(.{ .x = area.x + label_width, .y = area.y, .w = @max(0, area.w - label_width), .h = area.h }, c.theme.background);
    const step = tickStep(ruler.view.shown_s());
    const end_s = ruler.view.start_s + ruler.view.shown_s();
    // Counted in steps, so the numbers don't drift from adding fractions up.
    var tick = @ceil(ruler.view.start_s / step - 0.0001);
    var buffer: [16]u8 = undefined;
    while (tick * step <= end_s + 0.0001) : (tick += 1) {
        const time = tick * step;
        const x = area.x + layout.xOf(time);
        try c.rect(.{ .x = x, .y = area.y, .w = 1, .h = area.h }, c.theme.border);
        const label = std.fmt.bufPrint(&buffer, "{d}", .{@round(time * 100) / 100}) catch continue;
        try c.textIn(.{ .x = x + 4, .y = area.y, .w = 40, .h = area.h }, label, c.theme.small_text_size - 1, c.theme.muted_foreground, .start);
    }
    if (layout.shows(ruler.head_s)) try head(c, area.x + layout.xOf(ruler.head_s), area.y, area.h, if (ruler.recording) .{ 0.98, 0.44, 0.40 } else c.theme.primary);
}

pub const heights = struct {
    pub const row = row_height;
    pub const ruler = ruler_height;
};

fn diamond(c: *ui.Canvas, x: f32, y: f32, half: f32, color: [3]f32) !void {
    try diamondAlpha(c, x, y, half, color, 1);
}

fn diamondAlpha(c: *ui.Canvas, x: f32, y: f32, half: f32, color: [3]f32, alpha: f32) !void {
    const rgba = [4]f32{ color[0], color[1], color[2], alpha };
    try c.triangle(.{ .{ x - half, y }, .{ x, y - half }, .{ x + half, y } }, .{ rgba, rgba, rgba });
    try c.triangle(.{ .{ x - half, y }, .{ x + half, y }, .{ x, y + half } }, .{ rgba, rgba, rgba });
}

fn head(c: *ui.Canvas, x: f32, y: f32, h: f32, color: [3]f32) !void {
    try c.rect(.{ .x = x - 1, .y = y, .w = 2, .h = h }, color);
}

test "times map across the lane after the gutter, and back" {
    const layout = Layout{ .width = label_width + 209, .view = .{ .duration_s = 10 } };
    try std.testing.expectEqual(label_width, layout.xOf(0));
    try std.testing.expectEqual(label_width + 100, layout.xOf(5));
    try std.testing.expect(!layout.shows(99));
    try std.testing.expect(layout.timeAt(10) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 5), layout.timeAt(label_width + 100).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), layout.secondsAcross(10), 0.001);

    // Zoomed to 2..4 s, the lane shows those two seconds.
    const zoomed = Layout{ .width = label_width + 209, .view = .{ .duration_s = 10, .start_s = 2, .span_s = 2 } };
    try std.testing.expectEqual(label_width + 100, zoomed.xOf(3));
    try std.testing.expect(!zoomed.shows(1));
    try std.testing.expectApproxEqAbs(@as(f32, 4), zoomed.timeAtAny(label_width + 500), 0.001);
}

test "a view zooms about a time, pans and follows the head, inside the clip" {
    const whole = View{ .duration_s = 10 };
    const closer = whole.zoomed(2, 5);
    try std.testing.expectEqual(@as(f32, 5), closer.span_s);
    try std.testing.expectEqual(@as(f32, 2.5), closer.start_s);
    // The time under the pointer stays put.
    const near_end = whole.zoomed(4, 10);
    try std.testing.expectEqual(@as(f32, 7.5), near_end.start_s);
    try std.testing.expectEqual(@as(f32, 0), closer.zoomed(0.1, 5).span_s);
    try std.testing.expectEqual(@as(f32, 5), closer.panned(100).start_s);
    try std.testing.expectEqual(@as(f32, 0), closer.panned(-100).start_s);
    try std.testing.expectEqual(@as(f32, 4), closer.following(9).start_s);
    try std.testing.expectEqual(closer, closer.following(3));
    try std.testing.expectEqual(min_span_s, whole.zoomed(1000, 1).span_s);
}

test "dragged keys land on frames or the head, and stop at the start" {
    const layout = Layout{ .width = label_width + 209, .view = .{ .duration_s = 10 } };
    // Pressed on a key at 1 s, the pointer 0.51 s on: the key lands on the frame at 1.5 s.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dragShift(layout, 1, 1, 1.51, 9, 0, false), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.51), dragShift(layout, 1, 1, 1.51, 9, 0, true), 0.0001);
    // Near the head it lands there.
    try std.testing.expectApproxEqAbs(@as(f32, 2.27), dragShift(layout, 1, 1, 3.3, 3.27, 0, false), 0.0001);
    // Dragged back past the start, the earliest key stops at 0.
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), dragShift(layout, 2, 2, 0, 9, 0.5, false), 0.0001);
}

test "a click picks the nearest key within reach" {
    const layout = Layout{ .width = label_width + 209, .view = .{ .duration_s = 10 } };
    const keys = [_]eggy.assets.clip.Key{ .{ .time_s = 1 }, .{ .time_s = 1.2 }, .{ .time_s = 6 } };
    try std.testing.expectEqual(@as(?usize, 1), layout.keyNear(&keys, layout.xOf(1.25)));
    try std.testing.expectEqual(@as(?usize, 2), layout.keyNear(&keys, layout.xOf(6) + 5));
    try std.testing.expect(layout.keyNear(&keys, layout.xOf(4)) == null);
}

test "ticks are spaced so about a dozen fit" {
    try std.testing.expectEqual(@as(f32, 1), tickStep(12));
    try std.testing.expectEqual(@as(f32, 0.25), tickStep(2));
    try std.testing.expectEqual(@as(f32, 10), tickStep(90));
    try std.testing.expectEqual(@as(f32, 0.05), tickStep(0.4));
}
