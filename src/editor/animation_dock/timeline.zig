//! The Animation panel's timeline: a ruler of frames, the clip's camera cuts as shot blocks, and
//! its tracks grouped under what they act on, each a row with a diamond at each key and buttons
//! to step between keys, the scrub head across them all. Rows and the ruler share one layout
//! (`Layout`) over the stretch of the clip in view, so a click maps back to a time or a key the
//! same way.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const Track = eggy.assets.clip.Track;
const Property = eggy.assets.clip.Property;
const Ease = eggy.assets.clip.Ease;

/// The gutter on the left of each row for its target and property, in points.
pub const label_width: f32 = 210;
/// A key this close to the pointer is the one clicked, in points.
const pick_radius: f32 = 7;
const key_half: f32 = 4.5;
const row_height: f32 = 24;
const group_height: f32 = 24;
const shots_height: f32 = 44;
const ruler_height: f32 = 22;
/// A nested row's buttons at the end of its gutter: previous key, key at the head, next key.
const nav_width: f32 = 20;
const nav_end: f32 = 6;

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
        .camera => .{ 0.95, 0.93, 0.88 },
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
    /// Under a group row: its gutter shows the property alone, indented, and the key buttons.
    nested: bool = false,
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
    nested: bool = false,
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
        .nested = state.nested,
    };
}

/// A nested row's key buttons.
pub const Nav = enum { previous, key, next };

/// The key button at `x` from a nested row's left edge, if any.
pub fn navAt(x: f32) ?Nav {
    const right = label_width - nav_end;
    if (x > right or x < right - nav_width * 3) return null;
    const slot: usize = @intFromFloat(@min(2, @floor((x - (right - nav_width * 3)) / nav_width)));
    return @fromBackingInt(@intCast(slot));
}

/// The key of `keys` to step to from `head_s`: the last before it, or the first after it.
pub fn stepKey(keys: []const eggy.assets.clip.Key, head_s: f32, toward: enum { previous, next }) ?f32 {
    const same = eggy.assets.clip.same_time_s;
    var found: ?f32 = null;
    for (keys) |key| switch (toward) {
        .previous => if (key.time_s < head_s - same) {
            found = key.time_s;
        },
        .next => if (key.time_s > head_s + same) return key.time_s,
    };
    return found;
}

/// Whether one of `keys` sits on `head_s`.
pub fn onKey(keys: []const eggy.assets.clip.Key, head_s: f32) bool {
    for (keys) |key| if (@abs(key.time_s - head_s) <= eggy.assets.clip.same_time_s) return true;
    return false;
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
        .camera => {
            const shot = if (key.text.len == 0) "Game camera" else std.mem.trimStart(u8, key.text, "/");
            if (!(key.value[0] > 0)) return shot;
            return try std.fmt.allocPrint(arena, "{s}, {d:.1} s blend", .{ shot, key.value[0] });
        },
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
    if (row.nested) {
        try c.roundRect(.{ .x = area.x + 16, .y = middle - 3.5, .w = 7, .h = 7 }, row.color, 2);
        try c.textIn(.{ .x = area.x + 30, .y = area.y, .w = label_width - 30 - nav_width * 3 - nav_end - 4, .h = area.h }, row.property, text_size, c.theme.foreground, .start);
        try navButtons(c, area.x + label_width - nav_end - nav_width * 3, middle, onKeyTimes(row.times_s, row.head_s));
    } else {
        try c.roundRect(.{ .x = area.x + 2, .y = middle - 3.5, .w = 7, .h = 7 }, row.color, 2);
        try c.textIn(.{ .x = area.x + 16, .y = area.y, .w = label_width * 0.5 - 16, .h = area.h }, row.target, text_size, c.theme.foreground, .start);
        try c.textIn(.{ .x = area.x + label_width * 0.5, .y = area.y, .w = label_width * 0.5 - 10, .h = area.h }, row.property, text_size, c.theme.muted_foreground, .end);
    }

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

/// The ruler above the rows: a tick and frame number (at `snap_fps`) every so many frames.
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

/// Seconds between numbered ticks, a whole number of frames, so about a dozen fit across
/// `shown_s` seconds.
pub fn tickStep(shown_s: f32) f32 {
    for ([_]f32{ 1, 2, 5, 10, 15, 30, 60, 150, 300, 900, 1800 }) |frames| {
        const step = frames / snap_fps;
        if (shown_s / step <= 14) return step;
    }
    return 3600 / snap_fps;
}

/// The frame `time_s` falls on, at `snap_fps`.
pub fn frameOf(time_s: f32) u32 {
    return @intFromFloat(@max(0, @round(time_s * snap_fps)));
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
        const label = std.fmt.bufPrint(&buffer, "{d}", .{frameOf(time)}) catch continue;
        try c.textIn(.{ .x = x + 4, .y = area.y, .w = 40, .h = area.h }, label, c.theme.small_text_size - 1, c.theme.muted_foreground, .start);
    }
    if (layout.shows(ruler.head_s)) try head(c, area.x + layout.xOf(ruler.head_s), area.y, area.h, if (ruler.recording) .{ 0.98, 0.44, 0.40 } else c.theme.primary);
}

pub const heights = struct {
    pub const row = row_height;
    pub const group = group_height;
    pub const shots = shots_height;
    pub const ruler = ruler_height;
};

// Group rows ----------------------------------------------------------------------------------

/// A group's header row: what its tracks act on, and a faint diamond wherever one has a key.
pub const Group = struct {
    name: []const u8,
    /// What it is (`Camera`, `UI`, `Actor`), or "".
    kind: []const u8,
    times_s: []const f32,
    view: View,
    head_s: f32,
    recording: bool,
};

pub fn groupPaint(arena: std.mem.Allocator, group: Group) ui.Layout.Paint {
    const drawing = arena.create(Group) catch return .none;
    drawing.* = group;
    return .{ .custom = .{ .context = drawing, .draw = drawGroup } };
}

fn drawGroup(context: *const anyopaque, c: *ui.Canvas, area: ui.Rect) anyerror!void {
    const group: *const Group = @ptrCast(@alignCast(context));
    const layout = Layout{ .width = area.w, .view = group.view };
    const middle = area.y + area.h / 2;
    const text_size = c.theme.small_text_size - 1;
    try c.rect(.{ .x = area.x, .y = area.y + 1, .w = area.w, .h = area.h - 2 }, c.theme.card);
    try c.textIn(.{ .x = area.x + 4, .y = area.y, .w = label_width * 0.6, .h = area.h }, group.name, text_size + 1, c.theme.foreground, .start);
    try c.textIn(.{ .x = area.x + label_width * 0.6, .y = area.y, .w = label_width * 0.4 - 10, .h = area.h }, group.kind, text_size, c.theme.muted_foreground, .end);
    for (group.times_s) |time| {
        if (!layout.shows(time)) continue;
        try diamondAlpha(c, area.x + layout.xOf(time), middle, key_half - 1, c.theme.muted_foreground, 0.7);
    }
    if (layout.shows(group.head_s)) try head(c, area.x + layout.xOf(group.head_s), area.y, area.h, if (group.recording) .{ 0.98, 0.44, 0.40 } else c.theme.primary);
}

// Camera cuts ---------------------------------------------------------------------------------

/// A shot on the camera cuts lane: from its key to the next (or the clip's end), blending in
/// over its first `blend_s` from the shot before.
pub const Shot = struct {
    start_s: f32,
    end_s: f32,
    blend_s: f32,
    ease: Ease,
    name: []const u8,
    detail: []const u8,
    color: [3]f32,
    from_color: [3]f32,
    picked: bool,
};

pub const Shots = struct {
    shots: []const Shot,
    view: View,
    head_s: f32,
    recording: bool,
};

pub fn shotsPaint(arena: std.mem.Allocator, shots: Shots) ui.Layout.Paint {
    const drawing = arena.create(Shots) catch return .none;
    drawing.* = shots;
    return .{ .custom = .{ .context = drawing, .draw = drawShots } };
}

/// The game's own camera on the lane: the ground's tone, so shots stand out from it.
pub const game_color: [3]f32 = .{ 0.29, 0.26, 0.23 };
const shot_colors = [_][3]f32{ .{ 0.96, 0.75, 0.29 }, .{ 0.56, 0.77, 0.91 }, .{ 0.85, 0.64, 0.88 }, .{ 0.91, 0.60, 0.56 }, .{ 0.62, 0.84, 0.66 } };

/// The color of the `index`th camera a clip cuts to (in order of first use).
pub fn shotColor(index: usize) [3]f32 {
    return shot_colors[index % shot_colors.len];
}

/// Where "Add shot" sits in the lane's gutter, from its left edge.
pub fn addShotAt(x: f32) bool {
    return x >= label_width - 76 and x <= label_width - 8;
}

/// The shot of `starts_s` (ascending) under `x` on the lane, if one.
pub fn shotNear(layout: Layout, starts_s: []const f32, end_s: f32, x: f32) ?usize {
    const time = layout.timeAt(x) orelse return null;
    var found: ?usize = null;
    for (starts_s, 0..) |start, index| {
        if (start > time) break;
        found = index;
    }
    if (time > end_s) return null;
    return found;
}

fn drawShots(context: *const anyopaque, c: *ui.Canvas, area: ui.Rect) anyerror!void {
    const lane: *const Shots = @ptrCast(@alignCast(context));
    const layout = Layout{ .width = area.w, .view = lane.view };
    const text_size = c.theme.small_text_size - 1;
    const middle = area.y + area.h / 2;

    // The gutter: what the lane is, and the button adding a shot at the head.
    try c.textIn(.{ .x = area.x + 4, .y = area.y, .w = label_width - 84, .h = area.h }, "Camera cuts", text_size + 1, c.theme.foreground, .start);
    try c.roundRect(.{ .x = area.x + label_width - 76, .y = middle - 11, .w = 68, .h = 22 }, c.theme.secondary, 6);
    try c.textIn(.{ .x = area.x + label_width - 76, .y = middle - 11, .w = 68, .h = 22 }, "Add shot", text_size, c.theme.foreground, .center);

    const left = area.x + label_width;
    const right = area.x + area.w - key_half;
    try c.rect(.{ .x = left, .y = area.y + 1, .w = @max(0, area.w - label_width), .h = area.h - 2 }, c.theme.background);
    const top = area.y + 5;
    const height = area.h - 10;
    for (lane.shots) |shot| {
        const x0 = std.math.clamp(area.x + layout.xOf(shot.start_s), left, right);
        const x1 = std.math.clamp(area.x + layout.xOf(shot.end_s), left, right);
        if (x1 - x0 < 1) continue;
        const block = ui.Rect{ .x = x0 + 1, .y = top, .w = x1 - x0 - 2, .h = height };
        if (shot.picked) try c.roundRect(.{ .x = block.x - 2, .y = block.y - 2, .w = block.w + 4, .h = block.h + 4 }, c.theme.foreground, 8);
        try c.roundRect(block, shot.color, 6);

        // The blend in: the shot before giving way to this one along the ease.
        var text_x = block.x + 8;
        if (shot.blend_s > 0) {
            const bx1 = std.math.clamp(area.x + layout.xOf(shot.start_s + shot.blend_s), block.x, block.x + block.w);
            if (bx1 - block.x >= 1) {
                try c.rect(.{ .x = block.x, .y = block.y, .w = bx1 - block.x, .h = block.h }, shot.from_color);
                try easeWedge(c, .{ .x = block.x, .y = block.y, .w = bx1 - block.x, .h = block.h }, shot.ease, shot.color);
                text_x = bx1 + 8;
            }
        }
        const ink: [3]f32 = if (luminance(shot.color) > 0.5) .{ 0.10, 0.09, 0.07 } else c.theme.foreground;
        const room = block.x + block.w - text_x - 6;
        if (room > 12) {
            try c.textIn(.{ .x = text_x, .y = block.y + 2, .w = room, .h = block.h / 2 }, shot.name, text_size + 1, ink, .start);
            try c.textIn(.{ .x = text_x, .y = block.y + block.h / 2 - 2, .w = room, .h = block.h / 2 }, shot.detail, text_size, ink, .start);
        }
    }
    if (layout.shows(lane.head_s)) try head(c, area.x + layout.xOf(lane.head_s), area.y, area.h, if (lane.recording) .{ 0.98, 0.44, 0.40 } else c.theme.primary);
}

/// Fill the part of `r` below the curve of `ease`, which climbs from the bottom left to the top
/// right: how much of the new shot shows across the blend.
fn easeWedge(c: *ui.Canvas, r: ui.Rect, ease: Ease, color: [3]f32) !void {
    const steps = 16;
    const rgba = [4]f32{ color[0], color[1], color[2], 1 };
    const bottom = r.y + r.h;
    var x_before = r.x;
    var y_before = bottom;
    for (1..steps + 1) |step| {
        const t = @as(f32, @floatFromInt(step)) / steps;
        const x = r.x + r.w * t;
        const y = bottom - r.h * ease.apply(t);
        try c.triangle(.{ .{ x_before, bottom }, .{ x_before, y_before }, .{ x, y } }, .{ rgba, rgba, rgba });
        try c.triangle(.{ .{ x_before, bottom }, .{ x, y }, .{ x, bottom } }, .{ rgba, rgba, rgba });
        x_before = x;
        y_before = y;
    }
}

fn luminance(color: [3]f32) f32 {
    return 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2];
}

/// The three key buttons from `x`: a chevron back, a diamond (filled on a key), a chevron on.
fn navButtons(c: *ui.Canvas, x: f32, y: f32, on_key: bool) !void {
    const tone = c.theme.muted_foreground;
    const rgba = [4]f32{ tone[0], tone[1], tone[2], 1 };
    const back = x + nav_width / 2;
    try c.triangle(.{ .{ back + 2.5, y - 4 }, .{ back - 2.5, y }, .{ back + 2.5, y + 4 } }, .{ rgba, rgba, rgba });
    const middle = x + nav_width * 1.5;
    try diamond(c, middle, y, key_half, c.theme.foreground);
    if (!on_key) try diamond(c, middle, y, key_half - 1.5, c.theme.background);
    const on = x + nav_width * 2.5;
    try c.triangle(.{ .{ on - 2.5, y - 4 }, .{ on + 2.5, y }, .{ on - 2.5, y + 4 } }, .{ rgba, rgba, rgba });
}

fn onKeyTimes(times_s: []const f32, head_s: f32) bool {
    for (times_s) |time| if (@abs(time - head_s) <= eggy.assets.clip.same_time_s) return true;
    return false;
}

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

test "ticks fall on whole frames, spaced so about a dozen fit" {
    try std.testing.expectEqual(@as(f32, 1), tickStep(12));
    try std.testing.expectEqual(@as(f32, 5.0 / 30.0), tickStep(2));
    try std.testing.expectEqual(@as(f32, 10), tickStep(90));
    try std.testing.expectEqual(@as(f32, 1.0 / 30.0), tickStep(0.4));
    try std.testing.expectEqual(@as(u32, 108), frameOf(3.6));
}

test "a nested row's key buttons step between keys" {
    try std.testing.expectEqual(Nav.previous, navAt(label_width - nav_end - nav_width * 3 + 1).?);
    try std.testing.expectEqual(Nav.next, navAt(label_width - nav_end - 1).?);
    try std.testing.expect(navAt(10) == null);
    const keys = [_]eggy.assets.clip.Key{ .{ .time_s = 1 }, .{ .time_s = 2 }, .{ .time_s = 3 } };
    try std.testing.expectEqual(@as(?f32, 1), stepKey(&keys, 2, .previous));
    try std.testing.expectEqual(@as(?f32, 3), stepKey(&keys, 2, .next));
    try std.testing.expect(stepKey(&keys, 3, .next) == null);
    try std.testing.expect(onKey(&keys, 2) and !onKey(&keys, 2.5));
}

test "a click on the camera lane finds the shot under it" {
    const layout = Layout{ .width = label_width + 209, .view = .{ .duration_s = 10 } };
    const starts = [_]f32{ 0, 3, 5.2 };
    try std.testing.expectEqual(@as(?usize, 1), shotNear(layout, &starts, 10, layout.xOf(4)));
    try std.testing.expectEqual(@as(?usize, 2), shotNear(layout, &starts, 10, layout.xOf(9)));
    try std.testing.expect(shotNear(layout, &starts, 10, 20) == null);
}
