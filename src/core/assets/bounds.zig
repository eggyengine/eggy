//! A conservative box round a model, shared by the importer and the renderer.
//! `eggy.bounds.Bounds` re-exports it, with the matrix helpers.
const std = @import("std");

pub const Bounds = struct {
    min: [3]f32,
    max: [3]f32,

    pub const unit: Bounds = .{ .min = @splat(-0.5), .max = @splat(0.5) };

    /// Include a point in these bounds; input must contain finite coordinates.
    pub fn include(self: *Bounds, point: [3]f32) void {
        for (&self.min, &self.max, point) |*low, *high, value| {
            low.* = @min(low.*, value);
            high.* = @max(high.*, value);
        }
    }

    /// Keep boxes crossing any clip plane. Matrix columns map these local coordinates into
    /// clip space, including model scale/rotation/shear. Invalid inputs are never culled.
    pub fn visible(self: Bounds, clip_from_local: [4][4]f32) bool {
        var outside: u6 = std.math.maxInt(u6);
        for (0..8) |corner| {
            var clip: @Vector(4, f32) = clip_from_local[3];
            for (0..3) |axis| {
                const value = if (corner & (@as(usize, 1) << @intCast(axis)) != 0) self.max[axis] else self.min[axis];
                clip += @as(@Vector(4, f32), clip_from_local[axis]) * @as(@Vector(4, f32), @splat(value));
            }
            inline for (0..4) |axis| if (!std.math.isFinite(clip[axis])) return true;
            var mask: u6 = 0;
            if (clip[0] < -clip[3]) mask |= 1;
            if (clip[0] > clip[3]) mask |= 2;
            if (clip[1] < -clip[3]) mask |= 4;
            if (clip[1] > clip[3]) mask |= 8;
            if (clip[2] < 0) mask |= 16;
            if (clip[2] > clip[3]) mask |= 32;
            outside &= mask;
        }
        return outside == 0;
    }
};
