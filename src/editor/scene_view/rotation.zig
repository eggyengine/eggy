//! Rotations as 3×3 matrices (rows), for turning a `Transform` by the gizmo: built from and
//! taken back to its Euler angles (degrees, turned about x, then y, then z), and composed with a
//! turn about any axis.
const std = @import("std");

pub const Matrix = [3][3]f32;

/// The rotation `Transform.rotation_deg` stands for: `z · y · x`.
pub fn fromEuler(degrees: [3]f32) Matrix {
    const x = degrees[0] * std.math.rad_per_deg;
    const y = degrees[1] * std.math.rad_per_deg;
    const z = degrees[2] * std.math.rad_per_deg;
    const sx, const cx = .{ @sin(x), @cos(x) };
    const sy, const cy = .{ @sin(y), @cos(y) };
    const sz, const cz = .{ @sin(z), @cos(z) };
    return .{
        .{ cy * cz, sx * sy * cz - cx * sz, cx * sy * cz + sx * sz },
        .{ cy * sz, sx * sy * sz + cx * cz, cx * sy * sz - sx * cz },
        .{ -sy, sx * cy, cx * cy },
    };
}

/// The Euler angles (degrees) of `m`, a rotation; at a quarter turn about y, where x and z turn
/// the same way, all of it goes to x.
pub fn toEuler(m: Matrix) [3]f32 {
    const sy = std.math.clamp(-m[2][0], -1, 1);
    const y = std.math.asin(sy);
    const degrees = std.math.deg_per_rad;
    if (@abs(sy) > 0.9999) {
        return .{ std.math.atan2(-m[1][2], m[1][1]) * degrees, y * degrees, 0 };
    }
    return .{ std.math.atan2(m[2][1], m[2][2]) * degrees, y * degrees, std.math.atan2(m[1][0], m[0][0]) * degrees };
}

/// A turn of `degrees` about `axis` (unit length), counter-clockwise looking down it.
pub fn aboutAxis(axis: [3]f32, degrees: f32) Matrix {
    const angle = degrees * std.math.rad_per_deg;
    const s, const c = .{ @sin(angle), @cos(angle) };
    const t = 1 - c;
    const x, const y, const z = axis;
    return .{
        .{ t * x * x + c, t * x * y - s * z, t * x * z + s * y },
        .{ t * x * y + s * z, t * y * y + c, t * y * z - s * x },
        .{ t * x * z - s * y, t * y * z + s * x, t * z * z + c },
    };
}

pub fn mul(a: Matrix, b: Matrix) Matrix {
    var out: Matrix = undefined;
    for (0..3) |row| for (0..3) |col| {
        out[row][col] = a[row][0] * b[0][col] + a[row][1] * b[1][col] + a[row][2] * b[2][col];
    };
    return out;
}

/// `v` turned by `m`.
pub fn apply(m: Matrix, v: [3]f32) [3]f32 {
    return .{
        m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
        m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
        m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
    };
}

fn expectSame(a: Matrix, b: Matrix) !void {
    for (a, b) |row_a, row_b| for (row_a, row_b) |x, y| try std.testing.expectApproxEqAbs(x, y, 0.0005);
}

test "Euler angles come back from their rotation" {
    const angles = [3]f32{ 20, -35, 70 };
    const back = toEuler(fromEuler(angles));
    for (angles, back) |want, got| try std.testing.expectApproxEqAbs(want, got, 0.01);
    // At a quarter turn about y the angles change, but the rotation doesn't.
    const locked = [3]f32{ 10, 90, 30 };
    try expectSame(fromEuler(locked), fromEuler(toEuler(fromEuler(locked))));
}

test "a turn about z matches the Euler angle about z" {
    try expectSame(fromEuler(.{ 0, 0, 40 }), aboutAxis(.{ 0, 0, 1 }, 40));
    const turned = apply(aboutAxis(.{ 0, 1, 0 }, 90), .{ 1, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, -1), turned[2], 0.0001);
}
