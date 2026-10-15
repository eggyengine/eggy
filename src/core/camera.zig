//! Cameras: where the scene is seen from. `Camera` is the built-in component a game puts on an
//! entity to look through it (down the entity's -z, with its +y up); `View` is a camera placed in
//! the world, which the renderer draws from. The runtime looks through the first entity with a
//! `Camera` (`find`); the editor's Scene panel has a camera of its own.
const std = @import("std");
const ecs = @import("clutch");
const math = @import("eggenvector");
const transform_zig = @import("transform.zig");

pub const Camera = struct {
    /// How much it sees, top to bottom, in degrees.
    fov_deg: f32 = 60,
    /// The nearest and furthest it sees, in metres.
    near: f32 = 0.1,
    far: f32 = 1000,
};

/// A camera placed in the world: where it is, which way it looks, and what it sees. Plain data,
/// so it crosses from the editor's game library as is.
pub const View = extern struct {
    eye: [3]f32,
    /// Which way it looks, and which way is up for it (both unit length).
    forward: [3]f32,
    up: [3]f32,
    fov_deg: f32 = 60,
    near: f32 = 0.1,
    far: f32 = 1000,

    /// Looking at the middle of the world from above and in front, for scenes without a camera.
    pub const default: View = lookingAt(.{ 0, 8, 18 }, .{ 0, 1, 0 }, .{});

    /// From `eye` towards `target`, as `camera` sees.
    pub fn lookingAt(eye: [3]f32, target: [3]f32, camera: Camera) View {
        const forward = normalize(sub(target, eye));
        const right = normalize(cross(forward, .{ 0, 1, 0 }));
        return .{ .eye = eye, .forward = forward, .up = cross(right, forward), .fov_deg = camera.fov_deg, .near = camera.near, .far = camera.far };
    }

    /// The matrix taking world points to clip space, for a view `aspect` wide for each unit tall,
    /// as columns.
    pub fn viewProjection(self: View, aspect: f32) [4][4]f32 {
        const eye = math.Vec3{ .x = self.eye[0], .y = self.eye[1], .z = self.eye[2] };
        const target = math.Vec3{ .x = self.eye[0] + self.forward[0], .y = self.eye[1] + self.forward[1], .z = self.eye[2] + self.forward[2] };
        const view = math.mat.lookAt4x4(f32, eye, target, .{ .x = self.up[0], .y = self.up[1], .z = self.up[2] });
        const projection = math.mat.perspective4x4(f32, self.fov_deg * std.math.rad_per_deg, aspect, self.near, self.far);
        const matrix = math.mul(f32, 4, 4, 4, projection, view);
        var columns: [4][4]f32 = undefined;
        for (&columns, matrix.data) |*column, data| column.* = data;
        return columns;
    }
};

/// The view through the first entity of `world` with a `Camera`, placed by its transform (and
/// its parents'); null when there is none.
pub fn find(world: *ecs.World) ?View {
    var cameras = world.query(.{*const Camera});
    const found = cameras.next() orelse return null;
    const camera = found.get(*const Camera).*;
    const placed = transform_zig.worldMatrix(world, found.entity).data;
    return .{
        .eye = .{ placed[3][0], placed[3][1], placed[3][2] },
        .forward = normalize(.{ -placed[2][0], -placed[2][1], -placed[2][2] }),
        .up = normalize(.{ placed[1][0], placed[1][1], placed[1][2] }),
        .fov_deg = camera.fov_deg,
        .near = camera.near,
        .far = camera.far,
    };
}

pub fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return @as(@Vector(3, f32), a) - @as(@Vector(3, f32), b);
}

pub fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

pub fn normalize(v: [3]f32) [3]f32 {
    const length = @sqrt(@reduce(.Add, @as(@Vector(3, f32), v) * @as(@Vector(3, f32), v)));
    if (length == 0) return v;
    return @as(@Vector(3, f32), v) / @as(@Vector(3, f32), @splat(length));
}

/// Where world point `point` lands through `view_projection`: x and y from -1 to 1 (y up), and
/// whether it is in front of the camera.
pub fn project(view_projection: [4][4]f32, point: [3]f32) struct { x: f32, y: f32, in_front: bool } {
    var clip: @Vector(4, f32) = view_projection[3];
    for (0..3) |i| clip += @as(@Vector(4, f32), view_projection[i]) * @as(@Vector(4, f32), @splat(point[i]));
    if (clip[3] <= 0) return .{ .x = 0, .y = 0, .in_front = false };
    return .{ .x = clip[0] / clip[3], .y = clip[1] / clip[3], .in_front = true };
}

test "the default view sees the origin in the middle of the view" {
    const where = project(View.default.viewProjection(16.0 / 9.0), .{ 0, 1, 0 });
    try std.testing.expect(where.in_front);
    try std.testing.expectApproxEqAbs(@as(f32, 0), where.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), where.y, 0.001);
}

test "a camera entity looks down its -z, from where its transform puts it" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    try std.testing.expect(find(&world) == null);
    _ = try world.spawn(.{ Camera{ .fov_deg = 40 }, transform_zig.Transform{ .position = .{ 0, 2, 10 }, .rotation_deg = .{ 0, 90, 0 } } });
    const view = find(&world).?;
    try std.testing.expectEqual(@as(f32, 40), view.fov_deg);
    try std.testing.expectEqualSlices(f32, &.{ 0, 2, 10 }, &view.eye);
    // Turned a quarter about y, -z faces -x.
    try std.testing.expectApproxEqAbs(@as(f32, -1), view.forward[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), view.up[1], 0.001);
}
