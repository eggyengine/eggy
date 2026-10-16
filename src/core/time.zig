//! Time for game code: how long the last frame took, to move things at the same speed however
//! fast frames come, how long the game has run, and how many frames. `app.time` has it in
//! hooks, and systems take `Res(eggy.Time)`.
//!
//!     transform.position[0] += speed_m_per_s * app.time.delta_s;
const std = @import("std");

/// The longest a frame counts as, so a stall (a breakpoint, a dragged window) doesn't send
/// things flying.
const max_delta_s: f32 = 0.1;

pub const Time = struct {
    /// How long the last frame took, in seconds (0 on the first).
    delta_s: f32 = 0,
    /// How long the game has run, in seconds.
    elapsed_s: f64 = 0,
    /// Frames so far.
    frame: u64 = 0,
    /// When the last frame began; null before the first.
    last_ns: ?u64 = null,

    /// Start a frame at `now_ns` (any steady clock in nanoseconds).
    pub fn tick(self: *Time, now_ns: u64) void {
        const since_ns = if (self.last_ns) |last| now_ns -| last else 0;
        self.last_ns = now_ns;
        self.delta_s = @min(max_delta_s, @as(f32, @floatFromInt(since_ns)) / std.time.ns_per_s);
        self.elapsed_s += self.delta_s;
        self.frame += 1;
    }
};

test "a frame's length is the time since the last, but never more than a tenth of a second" {
    var time = Time{};
    time.tick(1_000_000_000);
    try std.testing.expectEqual(@as(f32, 0), time.delta_s);
    time.tick(1_016_000_000);
    try std.testing.expectApproxEqAbs(@as(f32, 0.016), time.delta_s, 1e-6);
    time.tick(9_000_000_000);
    try std.testing.expectEqual(max_delta_s, time.delta_s);
    try std.testing.expectEqual(@as(u64, 3), time.frame);
}
