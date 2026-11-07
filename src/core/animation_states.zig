//! Animation states: the imported clips an `Animator` mixes by weight, each on its own clock,
//! every weight easing toward a target, as idle and walk blend by speed and a jump fades in over
//! them. A state given a `bone` is a layer over the rest, moving only that bone and those below
//! it: drawing a gun with the arms while the legs walk. `Animation` (`app.animation()`) drives them; the renderer poses them (`deformation.zig`).
const std = @import("std");
const assets = @import("eggy_assets");
const AssetRef = @import("refs.zig").AssetRef;
const Name = @import("name.zig").Name;

pub const Repeat = enum { once, loop };
pub const RootMotion = assets.rig.RootMotion;

/// How many states one `Animator` holds at once. A state that has faded out to nothing frees
/// its slot.
pub const max_states = 8;

/// One clip being mixed in.
pub const State = struct {
    /// An imported clip, of the entity's model or of a model with the same bone names. Unset for
    /// a free slot.
    clip: AssetRef(.animation) = .{},
    /// Where its clock is, in seconds; it keeps counting past the end like `Animator.time_s`.
    time_s: f32 = 0,
    speed: f32 = 1,
    repeat: Repeat = .loop,
    root_motion: RootMotion = .keep,
    /// How much of the pose it makes now, from 0 to 1.
    weight: f32 = 0,
    /// The weight it eases toward.
    target_weight: f32 = 0,
    /// How long a whole fade, 0 to 1, takes; 0 jumps.
    fade_s: f32 = 0,
    /// The bone it moves, with every bone below it, over what the other states make, `weight`
    /// of the way. Empty for the whole body, mixed with the other whole-body states.
    bone: Name = .{},

    pub fn used(self: State) bool {
        return self.clip.len > 0;
    }
};

pub const States = [max_states]State;

/// How a state plays. `speed`, `repeat` and `root_motion` change on every call; `start_s` only
/// moves the clock when given.
pub const Options = struct {
    /// Where to start the clip. Null carries on from where it is when it is playing already,
    /// and starts at 0 when not.
    start_s: ?f32 = null,
    speed: f32 = 1,
    repeat: Repeat = .loop,
    root_motion: RootMotion = .keep,
    /// Moves only this bone and those below it, as a layer (`State.bone`); empty for the whole
    /// body.
    bone: []const u8 = "",
};

/// A clip placed on a 1D blend space's axis (`along`).
pub const Point = struct {
    clip: AssetRef(.animation),
    /// Where on the axis it shows alone, in the units of the value `along` is given.
    at: f32,
    /// Its playback rate, times `Options.speed`.
    speed: f32 = 1,
};

pub const Error = error{ InvalidClip, InvalidWeight, InvalidTime, InvalidSpeed, InvalidPoints, TooManyStates };

/// Ease `clip` toward `weight` (0 to 1) over `fade_s`, adding it when it isn't playing. When
/// nothing shows yet it starts at `weight` at once: there is nothing to fade from.
/// `error.TooManyStates` when all `max_states` slots are in use.
pub fn set(states: *States, clip: AssetRef(.animation), weight: f32, fade_s: f32, options: Options) Error!void {
    if (clip.len == 0) return error.InvalidClip;
    if (!(weight >= 0 and weight <= 1)) return error.InvalidWeight;
    if (!(fade_s >= 0) or !std.math.isFinite(fade_s)) return error.InvalidTime;
    if (options.start_s) |start_s| if (!std.math.isFinite(start_s)) return error.InvalidTime;
    if (!std.math.isFinite(options.speed)) return error.InvalidSpeed;

    const showing = shownWeight(states.*) > 0 or options.bone.len > 0;
    const state = find(states, clip) orelse added: {
        const free = for (states) |*slot| {
            if (!slot.used()) break slot;
        } else return error.TooManyStates;
        free.* = .{ .clip = clip };
        break :added free;
    };
    if (options.start_s) |start_s| state.time_s = start_s;
    state.speed = options.speed;
    state.repeat = options.repeat;
    state.root_motion = options.root_motion;
    state.target_weight = weight;
    state.fade_s = fade_s;
    state.bone = .init(options.bone);
    if (fade_s == 0 or !showing) state.weight = weight;
}

/// Fade `clip` in to the whole pose (or the whole of its layer, with `options.bone`) and every
/// other state of the same layer out, over `fade_s`.
pub fn fadeTo(states: *States, clip: AssetRef(.animation), fade_s: f32, options: Options) Error!void {
    try set(states, clip, 1, fade_s, options);
    fadeOthers(states, &.{clip}, options.bone, fade_s);
}

/// A 1D blend space: the clips of `points` placed along an axis (`at` ascending), weighted by
/// where `value` falls between the two either side of it (beyond the ends, the end clip alone).
/// Every other state of the same layer (`options.bone`) fades out. All of them ease over `fade_s`.
///
/// ```zig
/// try states.along(&animator.states, &.{ .{ .clip = idle, .at = 0 }, .{ .clip = walk, .at = 1.7 } }, ground_speed, 0.2, .{});
/// ```
pub fn along(states: *States, points: []const Point, value: f32, fade_s: f32, options: Options) Error!void {
    if (points.len == 0 or !std.math.isFinite(value)) return error.InvalidPoints;
    if (points.len > max_states) return error.TooManyStates;
    for (points[1..], points[0 .. points.len - 1]) |point, before| if (!(point.at > before.at)) return error.InvalidPoints;
    // Check every slot fits before setting any, so a failure changes nothing.
    var needed: usize = 0;
    for (points) |point| {
        if (find(states, point.clip) == null) needed += 1;
    }
    var free: usize = 0;
    for (states) |slot| {
        if (!slot.used()) free += 1;
    }
    if (needed > free) return error.TooManyStates;

    // ponytail: clocks aren't synced across points, so two cycles of different lengths (walk, run) may step out of phase; sync them by normalized time when a game blends two gaits.
    for (points, 0..) |point, index| {
        var shown = options;
        shown.speed *= point.speed;
        try set(states, point.clip, weightAlong(points, value, index), fade_s, shown);
    }
    var clips: [max_states]AssetRef(.animation) = undefined;
    for (clips[0..points.len], points) |*clip, point| clip.* = point.clip;
    fadeOthers(states, clips[0..points.len], options.bone, fade_s);
}

/// The weight of `points[index]` with `value` on the axis.
fn weightAlong(points: []const Point, value: f32, index: usize) f32 {
    const last = points.len - 1;
    if (value <= points[0].at) return if (index == 0) 1 else 0;
    if (value >= points[last].at) return if (index == last) 1 else 0;
    const upper = for (points, 0..) |point, at| {
        if (point.at > value) break at;
    } else last;
    const lower = upper - 1;
    const t = (value - points[lower].at) / (points[upper].at - points[lower].at);
    if (index == lower) return 1 - t;
    if (index == upper) return t;
    return 0;
}

/// Ease every state of the layer `bone` but `kept` out over `fade_s`.
fn fadeOthers(states: *States, kept: []const AssetRef(.animation), bone: []const u8, fade_s: f32) void {
    for (states) |*state| {
        if (!state.used() or !std.mem.eql(u8, state.bone.text(), bone)) continue;
        const keep = for (kept) |clip| {
            if (std.mem.eql(u8, clip.key(), state.clip.key())) break true;
        } else false;
        if (keep) continue;
        state.target_weight = 0;
        state.fade_s = fade_s;
        if (fade_s == 0) state.weight = 0;
    }
}

/// The state playing `clip`, if any.
pub fn find(states: *States, clip: AssetRef(.animation)) ?*State {
    for (states) |*state| {
        if (state.used() and std.mem.eql(u8, state.clip.key(), clip.key())) return state;
    }
    return null;
}

/// Move every state's clock on by `delta_s` and its weight toward its target, freeing the slots
/// of those that have faded out to nothing.
pub fn advance(states: *States, delta_s: f32) void {
    if (!std.math.isFinite(delta_s)) return;
    for (states) |*state| {
        if (!state.used()) continue;
        state.time_s += delta_s * state.speed;
        const step = if (state.fade_s > 0) delta_s / state.fade_s else 1;
        const gap = state.target_weight - state.weight;
        state.weight += std.math.clamp(gap, -step, step);
        if (state.weight <= 0 and state.target_weight <= 0) state.* = .{};
    }
}

/// How much of the pose the whole-body states make together, before it is shared out among
/// them.
pub fn shownWeight(states: States) f32 {
    var total: f32 = 0;
    for (states) |state| {
        if (state.used() and state.bone.len == 0) total += state.weight;
    }
    return total;
}

/// Whether any state is in use.
pub fn any(states: States) bool {
    for (states) |state| {
        if (state.used()) return true;
    }
    return false;
}

const idle = AssetRef(.animation).fromId(0x31);
const walk = AssetRef(.animation).fromId(0x32);
const jump = AssetRef(.animation).fromId(0x33);

test "a 1D blend space shares weight between the two clips either side of the value" {
    var states: States = @splat(.{});
    const points = [_]Point{ .{ .clip = idle, .at = 0 }, .{ .clip = walk, .at = 2, .speed = 1.5 } };
    try along(&states, &points, 0.5, 0, .{});
    try std.testing.expectEqual(@as(f32, 0.75), find(&states, idle).?.weight);
    try std.testing.expectEqual(@as(f32, 0.25), find(&states, walk).?.weight);
    try std.testing.expectEqual(@as(f32, 1.5), find(&states, walk).?.speed);
    try along(&states, &points, 9, 0, .{});
    try std.testing.expect(find(&states, idle) != null);
    try std.testing.expectEqual(@as(f32, 1), find(&states, walk).?.weight);
    advance(&states, 0.1);
    try std.testing.expect(find(&states, idle) == null);
    try std.testing.expectError(error.InvalidPoints, along(&states, &.{ points[1], points[0] }, 1, 0, .{}));
}

test "fading to a state eases it in and the others out, and frees what faded away" {
    var states: States = @splat(.{});
    try fadeTo(&states, idle, 0.5, .{});
    // Nothing showed before, so idle shows at once.
    try std.testing.expectEqual(@as(f32, 1), find(&states, idle).?.weight);
    try fadeTo(&states, jump, 0.5, .{ .start_s = 0.4, .repeat = .once });
    try std.testing.expectEqual(@as(f32, 0), find(&states, jump).?.weight);
    advance(&states, 0.25);
    try std.testing.expectEqual(@as(f32, 0.5), find(&states, jump).?.weight);
    try std.testing.expectEqual(@as(f32, 0.5), find(&states, idle).?.weight);
    try std.testing.expectApproxEqAbs(@as(f32, 0.65), find(&states, jump).?.time_s, 1e-6);
    advance(&states, 0.25);
    try std.testing.expect(find(&states, idle) == null);
    try std.testing.expectEqual(@as(f32, 1), shownWeight(states));

    // Asked again without a start, it carries on; with one, it starts over.
    try fadeTo(&states, jump, 0.5, .{ .repeat = .once });
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), find(&states, jump).?.time_s, 1e-6);
    try fadeTo(&states, jump, 0.5, .{ .start_s = 0, .repeat = .once });
    try std.testing.expectEqual(@as(f32, 0), find(&states, jump).?.time_s);
}

test "states refuse what they can't do and change nothing" {
    var states: States = @splat(.{});
    try std.testing.expectError(error.InvalidClip, set(&states, .{}, 1, 0, .{}));
    try std.testing.expectError(error.InvalidWeight, set(&states, idle, 2, 0, .{}));
    try std.testing.expectError(error.InvalidTime, set(&states, idle, 1, -1, .{}));
    try std.testing.expect(!any(states));
    for (0..max_states) |index| try set(&states, .fromId(0x40 + index), 0.1, 0, .{});
    try std.testing.expectError(error.TooManyStates, set(&states, idle, 1, 0, .{}));
    try std.testing.expectError(error.TooManyStates, along(&states, &.{ .{ .clip = idle, .at = 0 }, .{ .clip = walk, .at = 1 } }, 0, 0, .{}));
}

test "a layer on a bone fades in over the body's states without fading them out" {
    var states: States = @splat(.{});
    try along(&states, &.{ .{ .clip = idle, .at = 0 }, .{ .clip = walk, .at = 2 } }, 2, 0.2, .{});
    try fadeTo(&states, jump, 0.2, .{ .bone = "spine", .repeat = .once });
    // It fades in over the walk, which keeps its weight.
    try std.testing.expectEqual(@as(f32, 0), find(&states, jump).?.weight);
    advance(&states, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), find(&states, jump).?.weight, 1e-6);
    try std.testing.expectEqualStrings("spine", find(&states, jump).?.bone.text());
    try along(&states, &.{ .{ .clip = idle, .at = 0 }, .{ .clip = walk, .at = 2 } }, 2, 0.2, .{});
    try std.testing.expectEqual(@as(f32, 1), find(&states, jump).?.target_weight);
    try std.testing.expectEqual(@as(f32, 1), shownWeight(states));
}
