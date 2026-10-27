//! The 2D Scene panel's handles on the selection: its box, a square at each corner that scales
//! it and a knob above it that turns it, and what dragging one makes of its `Transform`.
//! Everything here is in world metres on the XY plane; the panel converts to and from points.
const std = @import("std");

/// How near the pointer must be to a handle to take it, and how far above the box the knob is.
pub const reach_px: f32 = 8;
pub const knob_gap_px: f32 = 28;

/// The selection's box as drawn: its centre and half its width and height along its own
/// (turned, scaled) x and y.
pub const Box = struct {
    centre: [2]f32,
    half_x: [2]f32,
    half_y: [2]f32,

    /// The box a drawable with model matrix `model` (columns) covers: its one-metre shape's.
    pub fn of(model: [4][4]f32) Box {
        return .{
            .centre = .{ model[3][0], model[3][1] },
            .half_x = .{ model[0][0] * 0.5, model[0][1] * 0.5 },
            .half_y = .{ model[1][0] * 0.5, model[1][1] * 0.5 },
        };
    }

    /// Its corners, round from the bottom left.
    pub fn corners(self: Box) [4][2]f32 {
        const signs = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
        var result: [4][2]f32 = undefined;
        for (&result, signs) |*corner, sign| corner.* = add(self.centre, add(scale(self.half_x, sign[0]), scale(self.half_y, sign[1])));
        return result;
    }

    /// The turning knob: above the box's top edge by `knob_gap_px` at `metres_per_px`.
    pub fn knob(self: Box, metres_per_px: f32) [2]f32 {
        const up = unit(self.half_y);
        return add(self.centre, scale(up, length(self.half_y) + knob_gap_px * metres_per_px));
    }

    /// The handle within reach of `at`, if any, of those `shown`: the knob first, then the
    /// nearest corner.
    pub fn handleAt(self: Box, at: [2]f32, metres_per_px: f32, shown: Shown) ?Handle {
        const reach = reach_px * metres_per_px;
        if (shown.knob and length(sub(at, self.knob(metres_per_px))) <= reach) return .turn;
        if (shown.corners) for (self.corners(), 0..) |corner, i| {
            if (length(sub(at, corner)) <= reach) return .{ .corner = @intCast(i) };
        };
        return null;
    }
};

pub const Handle = union(enum) { corner: u2, turn };

/// Which handles the tool picked shows on the box.
pub const Shown = struct { corners: bool, knob: bool };
const all: Shown = .{ .corners = true, .knob = true };

/// A handle being dragged: the box and the pointer when it was taken, and the Transform's
/// rotation and scale then.
pub const Drag = struct {
    handle: Handle,
    box: Box,
    from: [2]f32,
    rotation_deg: [3]f32,
    scale: [3]f32,

    /// The Transform field the drag changes and its new value, with the pointer at `at`.
    /// Corners scale about the centre (both axes alike with `uniform`); the knob turns about z,
    /// in 15 degree steps with `snap`.
    pub fn apply(self: Drag, at: [2]f32, uniform: bool, snap: bool) Change {
        switch (self.handle) {
            .turn => {
                const before = sub(self.from, self.box.centre);
                const now = sub(at, self.box.centre);
                var turned = self.rotation_deg;
                turned[2] += (std.math.atan2(now[1], now[0]) - std.math.atan2(before[1], before[0])) * std.math.deg_per_rad;
                if (snap) turned[2] = @round(turned[2] / 15) * 15;
                return .{ .rotation_deg = turned };
            },
            .corner => {
                var factor = [2]f32{ self.stretch(at, self.box.half_x), self.stretch(at, self.box.half_y) };
                if (uniform) factor = @splat((factor[0] + factor[1]) / 2);
                return .{ .scale = .{ self.scale[0] * factor[0], self.scale[1] * factor[1], self.scale[2] } };
            },
        }
    }

    /// How much farther from the centre along `half` the pointer is now than when taken.
    fn stretch(self: Drag, at: [2]f32, half: [2]f32) f32 {
        const along = unit(half);
        const before = @abs(dot(sub(self.from, self.box.centre), along));
        if (before < 1e-6) return 1;
        return @abs(dot(sub(at, self.box.centre), along)) / before;
    }
};

pub const Change = union(enum) { rotation_deg: [3]f32, scale: [3]f32 };

fn add(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ a[0] + b[0], a[1] + b[1] };
}

fn sub(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ a[0] - b[0], a[1] - b[1] };
}

fn scale(v: [2]f32, by: f32) [2]f32 {
    return .{ v[0] * by, v[1] * by };
}

fn dot(a: [2]f32, b: [2]f32) f32 {
    return a[0] * b[0] + a[1] * b[1];
}

fn length(v: [2]f32) f32 {
    return @sqrt(dot(v, v));
}

fn unit(v: [2]f32) [2]f32 {
    const l = length(v);
    return if (l < 1e-6) .{ 0, 1 } else scale(v, 1 / l);
}

const two_by_one = Box.of(.{ .{ 2, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 3, 0, 0, 1 } });

test "corners and the knob are found near the pointer, and nothing far from them or hidden" {
    try std.testing.expectEqual(Handle{ .corner = 2 }, two_by_one.handleAt(.{ 4.02, 0.5 }, 0.01, all).?);
    try std.testing.expectEqual(Handle.turn, two_by_one.handleAt(.{ 3, 0.5 + knob_gap_px * 0.01 }, 0.01, all).?);
    try std.testing.expect(two_by_one.handleAt(.{ 3, 0 }, 0.01, all) == null);
    try std.testing.expect(two_by_one.handleAt(.{ 4.02, 0.5 }, 0.01, .{ .corners = false, .knob = true }) == null);
    try std.testing.expect(two_by_one.handleAt(.{ 3, 0.5 + knob_gap_px * 0.01 }, 0.01, .{ .corners = true, .knob = false }) == null);
}

test "dragging a corner outwards scales by how much farther it went, uniformly with Shift" {
    const drag = Drag{ .handle = .{ .corner = 2 }, .box = two_by_one, .from = .{ 4, 0.5 }, .rotation_deg = @splat(0), .scale = .{ 2, 1, 1 } };
    try std.testing.expectEqual(Change{ .scale = .{ 4, 2, 1 } }, drag.apply(.{ 5, 1 }, false, false));
    try std.testing.expectEqual(Change{ .scale = .{ 2, 2, 1 } }, drag.apply(.{ 4, 1 }, false, false));
    try std.testing.expectEqual(Change{ .scale = .{ 3, 1.5, 1 } }, drag.apply(.{ 4, 1 }, true, false));
}

test "dragging the knob a quarter turn round turns 90 degrees about z, in steps when snapping" {
    const drag = Drag{ .handle = .turn, .box = two_by_one, .from = .{ 3, 1 }, .rotation_deg = .{ 0, 0, 10 }, .scale = @splat(1) };
    const turned = drag.apply(.{ 2, 0 }, false, false).rotation_deg;
    try std.testing.expectApproxEqAbs(@as(f32, 100), turned[2], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 105), drag.apply(.{ 2, 0 }, false, true).rotation_deg[2], 1e-3);
}
