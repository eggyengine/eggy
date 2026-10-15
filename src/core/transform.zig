//! `Transform`: where an entity is, how it is turned and how big it is, relative to its parent.
//! A built-in component: every project's Inspector can add it.
const std = @import("std");
const ecs = @import("clutch");
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

/// `entity`'s transform within the world: its own (or none), inside each parent's.
pub fn worldMatrix(world: *ecs.World, entity: ecs.EntityId) math.Mat4 {
    const local = if (world.get(entity, Transform)) |transform| transform.matrix() else math.identity(f32, 4);
    const parent = world.getParent(entity) orelse return local;
    return math.mul(f32, 4, 4, 4, worldMatrix(world, parent), local);
}

/// The inverse of `m`, a transform's matrix (as columns: no projection), or null when it
/// squashes space flat (a scale of 0).
pub fn invert(m: [4][4]f32) ?[4][4]f32 {
    // The inverse of the turn-and-scale part, by cofactors.
    const a = m[0];
    const b = m[1];
    const c = m[2];
    const det = a[0] * (b[1] * c[2] - c[1] * b[2]) - b[0] * (a[1] * c[2] - c[1] * a[2]) + c[0] * (a[1] * b[2] - b[1] * a[2]);
    if (@abs(det) < 1e-12) return null;
    var inverse: [4][4]f32 = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 1 } };
    inverse[0][0] = (b[1] * c[2] - c[1] * b[2]) / det;
    inverse[0][1] = -(a[1] * c[2] - c[1] * a[2]) / det;
    inverse[0][2] = (a[1] * b[2] - b[1] * a[2]) / det;
    inverse[1][0] = -(b[0] * c[2] - c[0] * b[2]) / det;
    inverse[1][1] = (a[0] * c[2] - c[0] * a[2]) / det;
    inverse[1][2] = -(a[0] * b[2] - b[0] * a[2]) / det;
    inverse[2][0] = (b[0] * c[1] - c[0] * b[1]) / det;
    inverse[2][1] = -(a[0] * c[1] - c[0] * a[1]) / det;
    inverse[2][2] = (a[0] * b[1] - b[0] * a[1]) / det;
    // Then undo the move, turned and scaled back.
    for (0..3) |row| inverse[3][row] = -(inverse[0][row] * m[3][0] + inverse[1][row] * m[3][1] + inverse[2][row] * m[3][2]);
    return inverse;
}

/// `point` taken through `m` (as columns), or as a direction (`w` 0) without its move.
pub fn apply(m: [4][4]f32, point: [3]f32, w: f32) [3]f32 {
    var out: [3]f32 = undefined;
    for (&out, 0..) |*value, row| value.* = m[0][row] * point[0] + m[1][row] * point[1] + m[2][row] * point[2] + m[3][row] * w;
    return out;
}

test "a transform's inverse takes its points back" {
    const transform = Transform{ .position = .{ 3, -1, 2 }, .rotation_deg = .{ 30, 45, 10 }, .scale = .{ 2, 0.5, 1 } };
    var forward: [4][4]f32 = undefined;
    for (&forward, transform.matrix().data) |*column, data| column.* = data;
    const back = invert(forward).?;
    const moved = apply(forward, .{ 1, 2, 3 }, 1);
    for (apply(back, moved, 1), [_]f32{ 1, 2, 3 }) |got, want| try std.testing.expectApproxEqAbs(want, got, 0.001);
    try std.testing.expect(invert(.{ .{ 0, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } }) == null);
}

test "a transform scales, then turns, then moves" {
    const transform = Transform{ .position = .{ 10, 0, 0 }, .rotation_deg = .{ 0, 0, 90 }, .scale = .{ 2, 2, 2 } };
    const corner = math.mat.transformPoint4x4(f32, transform.matrix(), .{ .x = 1, .y = 0, .z = 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 10), corner.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), corner.y, 0.001);
}
