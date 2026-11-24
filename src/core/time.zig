//! Time for game code: how long the last frame took, to move things at the same speed however
//! fast frames come, how long the game has run, and how many frames. `app.time` has it in
//! hooks, and systems take `Res(eggy.Time)`.
//!
//!     transform.position[0] += speed_m_per_s * app.time.delta_s;
const std = @import("std");
const support = @import("support.zig");
pub const timer_support: support.Support = .available;
pub const scaling_support: support.Support = .available;

/// A clock-relative value, not a callback or an allocated handle. Keep it in game/component
/// state. It is invalid against a clock whose timer generation has changed.
pub const Timer = struct {
    deadline_s: f64,
    clock_generation: u64,
    cancelled: bool = false,

    pub const Status = enum { running, finished, cancelled };

    /// Observe this value against the gameplay clock that created it; does not consume it.
    /// Returns `StaleTimer` after that clock resets or invalidates timers.
    ///
    /// ```zig
    /// // In a game hook, with a timer previously started on app.time:
    /// const state = try timer.status(app.time);
    /// ```
    pub fn status(self: Timer, clock: Time) error{StaleTimer}!Status {
        if (self.clock_generation != clock.generation) return error.StaleTimer;
        if (self.cancelled) return .cancelled;
        return if (clock.elapsed_s >= self.deadline_s) .finished else .running;
    }

    /// Whether the deadline has passed on the creating clock. Cancelled timers return false;
    /// an invalidated generation returns `StaleTimer`.
    ///
    /// ```zig
    /// // In a game hook, with a timer from this run:
    /// const ready = try timer.finished(app.time);
    /// ```
    pub fn finished(self: Timer, clock: Time) error{StaleTimer}!bool {
        return try self.status(clock) == .finished;
    }

    /// Counted gameplay seconds left. A finished or cancelled timer has zero remaining time.
    /// Use the creating clock; invalidated generations return `StaleTimer`.
    ///
    /// ```zig
    /// // In a game hook, with a timer from this run:
    /// const seconds_left = try timer.remainingSeconds(app.time);
    /// ```
    pub fn remainingSeconds(self: Timer, clock: Time) error{StaleTimer}!f64 {
        if (try self.status(clock) != .running) return 0;
        return self.deadline_s - clock.elapsed_s;
    }
};

/// The longest unscaled frame step, before applying the gameplay multiplier.
const max_delta_s: f32 = 0.1;

pub const Time = struct {
    /// How long the last frame took, in seconds (0 on the first).
    delta_s: f32 = 0,
    /// How long the game has run, in seconds.
    elapsed_s: f64 = 0,
    /// Counted frame time before scaling; still capped to protect against stalls.
    unscaled_delta_s: f32 = 0,
    unscaled_elapsed_s: f64 = 0,
    /// Read-only outside `setScale`; affects subsequent ticks, not an already-counted frame.
    scale: f32 = 1,
    /// Timer values belong to this run of the gameplay clock, not a saved scene.
    generation: u64 = 0,
    /// Frames so far.
    frame: u64 = 0,
    /// When the last frame began; null before the first.
    last_ns: ?u64 = null,

    /// Start a frame at `now_ns` (any steady clock in nanoseconds).
    /// Host-only: caps the unscaled step at 0.1 seconds, applies scale, and increments frame.
    /// The first tick has zero delta; a backwards timestamp also counts zero seconds.
    ///
    /// ```zig
    /// var clock = Time{};
    /// clock.tick(1_000_000_000);
    /// clock.tick(1_016_000_000); // delta_s is approximately 0.016.
    /// ```
    pub fn tick(self: *Time, now_ns: u64) void {
        const since_ns = if (self.last_ns) |last| now_ns -| last else 0;
        self.last_ns = now_ns;
        self.unscaled_delta_s = @min(max_delta_s, @as(f32, @floatFromInt(since_ns)) / std.time.ns_per_s);
        self.unscaled_elapsed_s += self.unscaled_delta_s;
        self.delta_s = self.unscaled_delta_s * self.scale;
        self.elapsed_s += self.delta_s;
        self.frame += 1;
    }

    /// Start a one-shot timer in counted, scaled gameplay seconds. Zero finishes immediately.
    /// No memory or callbacks are retained; observe it with `timer.status` or `finished`.
    /// Rejects negative or non-finite seconds with `InvalidDuration`.
    ///
    /// ```zig
    /// // In a game hook; store the returned value in game state:
    /// const cooldown = try app.time.startTimer(0.5);
    /// ```
    pub fn startTimer(self: *const Time, duration_s: f32) error{InvalidDuration}!Timer {
        if (!std.math.isFinite(duration_s) or duration_s < 0) return error.InvalidDuration;
        return .{ .deadline_s = self.elapsed_s + duration_s, .clock_generation = self.generation };
    }

    /// Cancel this value, idempotently. Cancellation never invokes game code.
    /// Returns `StaleTimer` for an invalidated generation; other copies are not cancelled.
    ///
    /// ```zig
    /// var cooldown = try app.time.startTimer(0.5);
    /// try app.time.cancelTimer(&cooldown);
    /// ```
    pub fn cancelTimer(self: *const Time, timer: *Timer) error{StaleTimer}!void {
        _ = try timer.status(self.*);
        timer.cancelled = true;
    }

    /// Scale the gameplay clock without changing which systems/hooks run. Zero freezes counted
    /// gameplay time; negative, infinite and NaN scales are rejected.
    ///
    /// ```zig
    /// // In a game hook: subsequent gameplay ticks run at half speed.
    /// try app.time.setScale(0.5);
    /// ```
    pub fn setScale(self: *Time, multiplier: f32) error{InvalidTimeScale}!void {
        if (!std.math.isFinite(multiplier) or multiplier < 0) return error.InvalidTimeScale;
        self.scale = multiplier;
    }

    /// Reset frame time and scaling and invalidate timers from the previous run.
    /// Host-only: the next tick is a zero-delta first frame again.
    ///
    /// ```zig
    /// // Host restarting a gameplay run:
    /// app.time.reset();
    /// ```
    pub fn reset(self: *Time) void {
        const generation = self.generation +% 1;
        self.* = .{ .generation = generation };
    }

    /// Invalidate world-scoped timers without rewinding an otherwise continuous clock.
    /// Host-only: use when replacing the world, before accepting new timer values.
    ///
    /// ```zig
    /// // Host replacing the current world:
    /// app.time.invalidateTimers();
    /// ```
    pub fn invalidateTimers(self: *Time) void {
        self.generation +%= 1;
    }
};
