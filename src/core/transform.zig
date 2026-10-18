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
    /// Positions are in parent-space metres, rotations in degrees, and scales unitless.
    /// Returns the matrix by value without changing ECS storage.
    ///
    /// ```zig
    /// const local = (Transform{ .position = .{ 0, 2, 0 } }).matrix();
    /// ```
    pub fn matrix(self: Transform) math.Mat4 {
        const radians = @as(@Vector(3, f32), self.rotation_deg) * @as(@Vector(3, f32), @splat(std.math.rad_per_deg));
        const turn = math.mul(f32, 4, 4, 4, math.mat.rotationZ4x4(f32, radians[2]), math.mul(f32, 4, 4, 4, math.mat.rotationY4x4(f32, radians[1]), math.mat.rotationX4x4(f32, radians[0])));
        const scaled = math.mul(f32, 4, 4, 4, turn, math.mat.scaling4x4(f32, self.scale[0], self.scale[1], self.scale[2]));
        return math.mul(f32, 4, 4, 4, math.mat.translation4x4(f32, self.position[0], self.position[1], self.position[2]), scaled);
    }

    /// Which way it faces, in its parent's space: its -z turned by its rotation (one metre long).
    /// A camera looks this way.
    /// Ignores scale and translation.
    ///
    /// ```zig
    /// const ahead = (Transform{}).forward(); // { 0, 0, -1 }
    /// ```
    pub fn forward(self: Transform) [3]f32 {
        return self.axis(.{ 0, 0, -1 });
    }

    /// Its right, in its parent's space: its +x turned by its rotation.
    /// Returns a unit direction, independent of scale and translation.
    ///
    /// ```zig
    /// const rightward = (Transform{}).right();
    /// ```
    pub fn right(self: Transform) [3]f32 {
        return self.axis(.{ 1, 0, 0 });
    }

    /// Its up, in its parent's space: its +y turned by its rotation.
    /// Returns a unit direction, independent of scale and translation.
    ///
    /// ```zig
    /// const upward = (Transform{}).up();
    /// ```
    pub fn up(self: Transform) [3]f32 {
        return self.axis(.{ 0, 1, 0 });
    }

    /// Move it by `offset` (in its parent's space): `transform.translate(transform.forward())`
    /// steps a metre ahead.
    /// Mutates only this value; when editing a borrowed ECS component, also mark it changed
    /// through the world so observers see the edit.
    ///
    /// ```zig
    /// var transform = Transform{};
    /// transform.translate(.{ 0, 1, 0 });
    /// ```
    pub fn translate(self: *Transform, offset: [3]f32) void {
        for (&self.position, offset) |*at, by| at.* += by;
    }

    /// `direction` turned by the rotation alone.
    fn axis(self: Transform, direction: [3]f32) [3]f32 {
        const turned = Transform{ .rotation_deg = self.rotation_deg };
        var columns: [4][4]f32 = undefined;
        for (&columns, turned.matrix().data) |*column, data| column.* = data;
        return apply(columns, direction, 0);
    }
};

/// `entity`'s transform within the world: its own (or none), inside each parent's.
/// Reads the parent chain without mutation; missing transforms contribute identity.
/// Supply an entity from this world with an acyclic parent hierarchy.
///
/// ```zig
/// const placed = worldMatrix(world, entity);
/// ```
pub fn worldMatrix(world: *ecs.World, entity: ecs.EntityId) math.Mat4 {
    const local = if (world.get(entity, Transform)) |transform| transform.matrix() else math.identity(f32, 4);
    const parent = world.getParent(entity) orelse return local;
    return math.mul(f32, 4, 4, 4, worldMatrix(world, parent), local);
}

/// The inverse of `m`, a transform's matrix (as columns: no projection), or null when it
/// squashes space flat (a scale of 0).
/// Treats determinants smaller than `1e-12` in magnitude as singular; returns by value.
///
/// ```zig
/// const world_from_local = [4][4]f32{
///     .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 3, 0, 0, 1 },
/// };
/// const local_from_world = invert(world_from_local) orelse return error.SingularTransform;
/// ```
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
/// Use `w = 1` for positions; this affine helper does not perform perspective division.
///
/// ```zig
/// const transformed = apply(world_from_local, .{ 1, 2, 3 }, 1);
/// ```
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

test "a transform faces down its -z, turned as it is" {
    var transform = Transform{ .rotation_deg = .{ 0, 90, 0 } };
    // Turned a quarter left about y: it faces -x, and its right is -z.
    for (transform.forward(), [3]f32{ -1, 0, 0 }) |got, want| try std.testing.expectApproxEqAbs(want, got, 0.001);
    for (transform.right(), [3]f32{ 0, 0, -1 }) |got, want| try std.testing.expectApproxEqAbs(want, got, 0.001);
    transform.translate(transform.forward());
    try std.testing.expectApproxEqAbs(@as(f32, -1), transform.position[0], 0.001);
}
