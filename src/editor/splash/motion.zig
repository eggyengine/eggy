//! How the splash screen moves, each animation a function of time taken from its design: the
//! tile's glow, the sparkles, the step label's roll, the bar, and the failed egg's crack.
const std = @import("std");

/// How often the failed egg cracks again.
const alarm_period_s = 3.2;

/// How much of the crack across the failed egg is drawn, 0 to 1: it draws every 3.2 s.
pub fn crack(time_s: f32) f32 {
    return keyframes(&.{ 0, 0.10, 0.22, 1 }, &.{ 0, 0, 1, 1 }, phase(time_s, alarm_period_s));
}

/// How red the failed egg's tile border is, 0 to 1: a flash as each crack draws.
pub fn alarm(time_s: f32) f32 {
    return keyframes(&.{ 0, 0.06, 0.22, 1 }, &.{ 0, 1, 0, 0 }, phase(time_s, alarm_period_s));
}

/// How strongly the egg's tile glows, 0 to 1: a breath every 2.4 s.
pub fn glow(time_s: f32) f32 {
    return 0.5 - 0.5 * @cos(2 * std.math.pi * phase(time_s, 2.4));
}

/// A sparkle's strength, 0 to 1, starting `delay_s` into the splash: a twinkle every 1.8 s.
/// Its opacity is the strength, its size from 40% at none to all of it at full.
pub fn twinkle(time_s: f32, delay_s: f32) f32 {
    if (time_s < delay_s) return 0;
    return keyframes(&.{ 0, 0.5, 1 }, &.{ 0, 1, 0 }, phase(time_s - delay_s, 1.8));
}

/// How long a step's label takes to roll in.
pub const roll_s = 0.32;

/// How far the step label has rolled from the last step to the new, `elapsed_s` after the new
/// began: past 1 for a moment, then 1.
pub fn roll(elapsed_s: f32) f32 {
    if (elapsed_s >= roll_s) return 1;
    return cubicBezier(.{ 0.2, 0.9, 0.3, 1.25 }, @max(0, elapsed_s) / roll_s);
}

/// How full the current step's segment is `elapsed_s` into the step, which can't say how far it
/// is: quickly at first, then slower, never quite full until the next step begins.
pub fn fill(elapsed_s: f32) f32 {
    return 0.92 * (1 - @exp(-@max(0, elapsed_s) / 1.2));
}

/// The shimmer band's width across the current segment, in pixels.
pub const sweep_width = 40;

/// Where the shimmer band's left edge is across a segment `width` pixels wide, from its left:
/// across and past it every 0.9 s.
pub fn sweep(time_s: f32, width: f32) f32 {
    return -48 + (width + 76) * phase(time_s, 0.9);
}

/// How far into a `period_s` loop `time_s` is, 0 to 1.
fn phase(time_s: f32, period_s: f32) f32 {
    return @mod(time_s, period_s) / period_s;
}

/// The value at `t` (0 to 1) of `values` at the times `at` (ascending, 0 to 1), eased in and
/// out between each pair as CSS keyframes are by default.
fn keyframes(at: []const f32, values: []const f32, t: f32) f32 {
    for (at[1..], 1..) |end, i| {
        if (t > end) continue;
        const start = at[i - 1];
        const local = if (end > start) (t - start) / (end - start) else 1;
        return std.math.lerp(values[i - 1], values[i], easeInOut(local));
    }
    return values[values.len - 1];
}

/// CSS `ease-in-out`.
fn easeInOut(t: f32) f32 {
    return cubicBezier(.{ 0.42, 0, 0.58, 1 }, t);
}

/// CSS `cubic-bezier(x1, y1, x2, y2)` at `t` (0 to 1): the curve's height where it is `t` across.
fn cubicBezier(points: [4]f32, t: f32) f32 {
    const x1, const y1, const x2, const y2 = points;
    // Newton's method finds how far along the curve it is `t` across; it converges in a few steps.
    var u = t;
    for (0..8) |_| {
        const x = bezier(x1, x2, u) - t;
        const slope = 3 * (1 - u) * (1 - u) * x1 + 6 * (1 - u) * u * (x2 - x1) + 3 * u * u * (1 - x2);
        if (@abs(x) < 1e-5 or slope == 0) break;
        u = std.math.clamp(u - x / slope, 0, 1);
    }
    return bezier(y1, y2, u);
}

fn bezier(p1: f32, p2: f32, u: f32) f32 {
    return 3 * (1 - u) * (1 - u) * u * p1 + 3 * (1 - u) * u * u * p2 + u * u * u;
}

test "the step label overshoots as it rolls in, then settles" {
    try std.testing.expectEqual(@as(f32, 0), roll(0));
    var most: f32 = 0;
    var t: f32 = 0;
    while (t < roll_s) : (t += 0.01) most = @max(most, roll(t));
    try std.testing.expect(most > 1.05);
    try std.testing.expectEqual(@as(f32, 1), roll(roll_s));
}

test "a step's segment fills but never quite until the step ends" {
    try std.testing.expectEqual(@as(f32, 0), fill(0));
    try std.testing.expect(fill(1) > fill(0.5));
    try std.testing.expect(fill(60) <= 0.92);
}

test "the crack draws early in each period and the border flashes with it" {
    try std.testing.expectEqual(@as(f32, 0), crack(0.05 * alarm_period_s));
    try std.testing.expectEqual(@as(f32, 1), crack(0.5 * alarm_period_s));
    try std.testing.expectApproxEqAbs(@as(f32, 1), alarm(0.06 * alarm_period_s), 0.001);
    try std.testing.expectEqual(@as(f32, 0), alarm(0.5 * alarm_period_s));
}

test "a sparkle waits for its delay, then peaks halfway through its twinkle" {
    try std.testing.expectEqual(@as(f32, 0), twinkle(0.5, 0.6));
    try std.testing.expectApproxEqAbs(@as(f32, 1), twinkle(0.6 + 0.9, 0.6), 0.001);
}
