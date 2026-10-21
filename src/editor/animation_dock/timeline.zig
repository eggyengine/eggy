//! The strip above the scrub slider: a diamond for every key of the clip being edited and a line
//! for the scrub head, laid out like the slider's track so both line up.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;

/// How far the slider's track is inset from its element's edges, in points (weeoui's slider).
const track_inset: f32 = 8;
const key_half: f32 = 4;

/// What to draw: key times and the head, in seconds on a clip `duration_s` long.
pub const Strip = struct {
    duration_s: f32,
    head_s: f32,
    key_times_s: []const f32,
    /// The key the user picked, if it is one of `key_times_s`.
    selected_s: ?f32 = null,
};

/// Where `time_s` lands across a strip `width` points wide.
pub fn xOf(width: f32, duration_s: f32, time_s: f32) f32 {
    const t = if (duration_s > 0) std.math.clamp(time_s / duration_s, 0, 1) else 0;
    return track_inset + t * @max(0, width - 2 * track_inset);
}

/// A paint drawing `strip`, with its data copied into `arena`.
pub fn paint(arena: std.mem.Allocator, strip: Strip) ui.Layout.Paint {
    const drawing = arena.create(Strip) catch return .none;
    drawing.* = strip;
    drawing.key_times_s = arena.dupe(f32, strip.key_times_s) catch return .none;
    return .{ .custom = .{ .context = drawing, .draw = draw } };
}

fn draw(context: *const anyopaque, c: *ui.Canvas, area: ui.Rect) anyerror!void {
    const strip: *const Strip = @ptrCast(@alignCast(context));
    const middle = area.y + area.h / 2;

    // Keys as diamonds, the picked one brighter.
    for (strip.key_times_s) |time| {
        const x = area.x + xOf(area.w, strip.duration_s, time);
        const picked = if (strip.selected_s) |chosen| @abs(chosen - time) < eggy.assets.clip.same_time_s else false;
        const color: [4]f32 = if (picked) .{ 1, 0.84, 0.22, 1 } else .{ 0.62, 0.62, 0.66, 1 };
        try c.triangle(.{ .{ x - key_half, middle }, .{ x, middle - key_half }, .{ x + key_half, middle } }, .{ color, color, color });
        try c.triangle(.{ .{ x - key_half, middle }, .{ x + key_half, middle }, .{ x, middle + key_half } }, .{ color, color, color });
    }

    // The head: a thin line over the whole strip.
    const head_x = area.x + xOf(area.w, strip.duration_s, strip.head_s);
    const red = [4]f32{ 0.92, 0.27, 0.32, 1 };
    try c.triangle(.{ .{ head_x - 1, area.y }, .{ head_x + 1, area.y }, .{ head_x + 1, area.y + area.h } }, .{ red, red, red });
    try c.triangle(.{ .{ head_x - 1, area.y }, .{ head_x + 1, area.y + area.h }, .{ head_x - 1, area.y + area.h } }, .{ red, red, red });
}

test "times map across the track, inside its inset" {
    try std.testing.expectEqual(track_inset, xOf(200, 2, 0));
    try std.testing.expectEqual(@as(f32, 100), xOf(200, 2, 1));
    try std.testing.expectEqual(@as(f32, 192), xOf(200, 2, 5));
    try std.testing.expectEqual(track_inset, xOf(200, 0, 1));
}
