//! The 2D Scene panel's handles on the selection: its box, a square at each corner that scales
//! it and a knob above it that turns it, and what dragging one makes of its `Transform`.
//! Everything here is in world metres on the XY plane; the panel converts to and from points.
const std = @import("std");
const math = @import("eggy").math;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;

/// How near the pointer must be to a handle to take it, and how far above the box the knob is.
pub const reach_px: f32 = 8;
pub const knob_gap_px: f32 = 28;

/// The selection's box as drawn: its centre and half its width and height along its own
/// (turned, scaled) x and y.
pub const Box = struct {
    centre: Vec2,
    half_x: Vec2,
    half_y: Vec2,

    /// The box a drawable with model matrix `model` (columns) covers: its one-metre shape's.
    pub fn of(model: [4][4]f32) Box {
        return .{
            .centre = .init(model[3][0], model[3][1]),
            .half_x = Vec2.init(model[0][0], model[0][1]).scale(0.5),
            .half_y = Vec2.init(model[1][0], model[1][1]).scale(0.5),
        };
    }

    /// Its corners, round from the bottom left.
    pub fn corners(self: Box) [4]Vec2 {
        const signs = [4]Vec2{ .init(-1, -1), .init(1, -1), .init(1, 1), .init(-1, 1) };
        var result: [4]Vec2 = undefined;
        for (&result, signs) |*corner, sign| corner.* = self.centre.add(self.half_x.scale(sign.x)).add(self.half_y.scale(sign.y));
        return result;
    }

    /// The turning knob: above the box's top edge by `knob_gap_px` at `metres_per_px`.
    pub fn knob(self: Box, metres_per_px: f32) Vec2 {
        return self.centre.add(unit(self.half_y).scale(self.half_y.length() + knob_gap_px * metres_per_px));
    }

    /// The handle within reach of `at`, if any, of those `shown`: the knob first, then the
    /// nearest corner.
    pub fn handleAt(self: Box, at: Vec2, metres_per_px: f32, shown: Shown) ?Handle {
        const reach = reach_px * metres_per_px;
        if (shown.knob and at.distance(self.knob(metres_per_px)) <= reach) return .turn;
        if (shown.corners) for (self.corners(), 0..) |corner, i| {
            if (at.distance(corner) <= reach) return .{ .corner = @intCast(i) };
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
    from: Vec2,
    rotation_deg: Vec3,
    scale: Vec3,

    /// The Transform field the drag changes and its new value, with the pointer at `at`.
    /// Corners scale about the centre (both axes alike with `uniform`); the knob turns about z,
    /// in 15 degree steps with `snap`.
    pub fn apply(self: Drag, at: Vec2, uniform: bool, snap: bool) Change {
        switch (self.handle) {
            .turn => {
                const before = self.from.sub(self.box.centre);
                const now = at.sub(self.box.centre);
                var turned = self.rotation_deg;
                turned.z += (now.angle() - before.angle()) * std.math.deg_per_rad;
                if (snap) turned.z = @round(turned.z / 15) * 15;
                return .{ .rotation_deg = turned };
            },
            .corner => {
                var factor = Vec2.init(self.stretch(at, self.box.half_x), self.stretch(at, self.box.half_y));
                if (uniform) factor = .splat((factor.x + factor.y) / 2);
                return .{ .scale = .init(self.scale.x * factor.x, self.scale.y * factor.y, self.scale.z) };
            },
        }
    }

    /// How much farther from the centre along `half` the pointer is now than when taken.
    fn stretch(self: Drag, at: Vec2, half: Vec2) f32 {
        const along = unit(half);
        const before = @abs(self.from.sub(self.box.centre).dot(along));
        if (before < 1e-6) return 1;
        return @abs(at.sub(self.box.centre).dot(along)) / before;
    }
};

pub const Change = union(enum) { rotation_deg: Vec3, scale: Vec3 };

/// `v`'s direction, or straight up when it has none.
fn unit(v: Vec2) Vec2 {
    return if (v.length() < 1e-6) .unit_y else v.normalize();
}

const two_by_one = Box.of(.{ .{ 2, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 3, 0, 0, 1 } });

test "corners and the knob are found near the pointer, and nothing far from them or hidden" {
    try std.testing.expectEqual(Handle{ .corner = 2 }, two_by_one.handleAt(.init(4.02, 0.5), 0.01, all).?);
    try std.testing.expectEqual(Handle.turn, two_by_one.handleAt(.init(3, 0.5 + knob_gap_px * 0.01), 0.01, all).?);
    try std.testing.expect(two_by_one.handleAt(.init(3, 0), 0.01, all) == null);
    try std.testing.expect(two_by_one.handleAt(.init(4.02, 0.5), 0.01, .{ .corners = false, .knob = true }) == null);
    try std.testing.expect(two_by_one.handleAt(.init(3, 0.5 + knob_gap_px * 0.01), 0.01, .{ .corners = true, .knob = false }) == null);
}

test "dragging a corner outwards scales by how much farther it went, uniformly with Shift" {
    const drag = Drag{ .handle = .{ .corner = 2 }, .box = two_by_one, .from = .init(4, 0.5), .rotation_deg = .zero, .scale = .init(2, 1, 1) };
    try std.testing.expectEqual(Change{ .scale = .init(4, 2, 1) }, drag.apply(.init(5, 1), false, false));
    try std.testing.expectEqual(Change{ .scale = .init(2, 2, 1) }, drag.apply(.init(4, 1), false, false));
    try std.testing.expectEqual(Change{ .scale = .init(3, 1.5, 1) }, drag.apply(.init(4, 1), true, false));
}

test "dragging the knob a quarter turn round turns 90 degrees about z, in steps when snapping" {
    const drag = Drag{ .handle = .turn, .box = two_by_one, .from = .init(3, 1), .rotation_deg = .init(0, 0, 10), .scale = .one };
    const turned = drag.apply(.init(2, 0), false, false).rotation_deg;
    try std.testing.expectApproxEqAbs(@as(f32, 100), turned.z, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 105), drag.apply(.init(2, 0), false, true).rotation_deg.z, 1e-3);
}
