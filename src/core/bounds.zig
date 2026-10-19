//! Conservative local-space bounds tested against all six homogeneous clip planes.
const std = @import("std");

pub const Bounds = @import("eggy_assets").bounds.Bounds;

/// Compose column-major matrices without relying on an ECS or renderer type.
pub fn compose(a: [4][4]f32, b: [4][4]f32) [4][4]f32 {
    var result: [4][4]f32 = undefined;
    for (&result, b) |*out, column| {
        var value: @Vector(4, f32) = @splat(0);
        for (a, column) |basis, weight| value += @as(@Vector(4, f32), basis) * @as(@Vector(4, f32), @splat(weight));
        out.* = value;
    }
    return result;
}

test "bounds retain near-plane intersections and reject each outside plane" {
    const identity: [4][4]f32 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
    try std.testing.expect(Bounds.unit.visible(identity));
    for ([_][3]f32{ .{ -3, 0, 0 }, .{ 3, 0, 0 }, .{ 0, -3, 0 }, .{ 0, 3, 0 }, .{ 0, 0, -3 }, .{ 0, 0, 3 } }) |translation| {
        var moved = identity;
        moved[3] = .{ translation[0], translation[1], translation[2], 1 };
        try std.testing.expect(!Bounds.unit.visible(compose(identity, moved)));
    }
    var invalid = identity;
    invalid[0][0] = std.math.nan(f32);
    try std.testing.expect(Bounds.unit.visible(invalid));
}
