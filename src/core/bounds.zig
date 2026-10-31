//! Conservative local-space bounds tested against all six homogeneous clip planes.
const std = @import("std");

pub const Bounds = @import("eggy_assets").bounds.Bounds;

test "bounds retain near-plane intersections and reject each outside plane" {
    const identity: [4][4]f32 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
    try std.testing.expect(Bounds.unit.visible(identity));
    for ([_][3]f32{ .{ -3, 0, 0 }, .{ 3, 0, 0 }, .{ 0, -3, 0 }, .{ 0, 3, 0 }, .{ 0, 0, -3 }, .{ 0, 0, 3 } }) |translation| {
        var moved = identity;
        moved[3] = .{ translation[0], translation[1], translation[2], 1 };
        try std.testing.expect(!Bounds.unit.visible(moved));
    }
    var invalid = identity;
    invalid[0][0] = std.math.nan(f32);
    try std.testing.expect(Bounds.unit.visible(invalid));
}
