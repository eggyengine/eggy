//! `Transform`: where an entity is, how it is turned and how big it is, relative to its parent.
//! A built-in component: every project's Inspector can add it.
const std = @import("std");
const math = @import("eggenvector");

pub const Transform = struct {
    position: [3]f32 = .{ 0, 0, 0 },
    /// Turns about x, then y, then z, in degrees.
    rotation_deg: [3]f32 = .{ 0, 0, 0 },
    scale: [3]f32 = .{ 1, 1, 1 },

    /// The matrix taking points from the entity's space into its parent's: scaled, turned, then
    /// moved.
    pub fn matrix(self: Transform) math.Mat4 {
        const radians = @as(@Vector(3, f32), self.rotation_deg) * @as(@Vector(3, f32), @splat(std.math.rad_per_deg));
        const turn = math.mul(f32, 4, 4, 4, math.mat.rotationZ4x4(f32, radians[2]), math.mul(f32, 4, 4, 4, math.mat.rotationY4x4(f32, radians[1]), math.mat.rotationX4x4(f32, radians[0])));
        const scaled = math.mul(f32, 4, 4, 4, turn, math.mat.scaling4x4(f32, self.scale[0], self.scale[1], self.scale[2]));
        return math.mul(f32, 4, 4, 4, math.mat.translation4x4(f32, self.position[0], self.position[1], self.position[2]), scaled);
    }
};

test "a transform scales, then turns, then moves" {
    const transform = Transform{ .position = .{ 10, 0, 0 }, .rotation_deg = .{ 0, 0, 90 }, .scale = .{ 2, 2, 2 } };
    const corner = math.mat.transformPoint4x4(f32, transform.matrix(), .{ .x = 1, .y = 0, .z = 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 10), corner.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), corner.y, 0.001);
}
