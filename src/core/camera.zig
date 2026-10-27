//! Cameras: where the scene is seen from. `Camera` is the built-in component a game puts on an
//! entity to look through it (down the entity's -z, with its +y up); `View` is a camera placed in
//! the world, which the renderer draws from. Active cameras use priority, then stable entity ID;
//! the editor's Scene panel has a camera of its own.
const std = @import("std");
const ecs = @import("clutch");
const math = @import("eggenvector");
const transform_zig = @import("transform.zig");

pub const Projection = enum(u32) { perspective, orthographic };

pub const Camera = struct {
    /// Marks it in the editor (nf-md-video_vintage).
    pub const icon = "\u{f0a1c}";
    pub const category = "Rendering";
    /// It looks from where its `Transform` puts it.
    pub const dependencies = .{transform_zig.Transform};

    /// How much it sees, top to bottom, in degrees.
    fov_deg: f32 = 60,
    /// The nearest and furthest it sees, in metres.
    near: f32 = 0.1,
    far: f32 = 1000,
    projection: Projection = .perspective,
    orthographic_height_m: f32 = 10,
    active: bool = true,
    priority: i32 = 0,

    /// Reject unusable projection settings before selecting or projecting this camera.
    pub fn validate(self: Camera) error{InvalidCamera}!void {
        for ([_]f32{ self.fov_deg, self.near, self.far, self.orthographic_height_m }) |value|
            if (!std.math.isFinite(value)) return error.InvalidCamera;
        if (self.near <= 0 or self.far <= self.near or self.fov_deg <= 0 or self.fov_deg >= 180 or self.orthographic_height_m <= 0)
            return error.InvalidCamera;
    }
};

/// Borrowed camera controls for the current world; do not retain across world replacement.
pub const Cameras = struct {
    world: *ecs.World,

    /// Make one live camera exclusive, or disable all cameras with null.
    /// Invalid entities, missing components and invalid projections leave selection unchanged.
    pub fn setActive(self: Cameras, entity: ?ecs.EntityId) !void {
        if (entity) |id| {
            if (!self.world.isAlive(id)) return error.InvalidEntity;
            const value = self.world.get(id, Camera) orelse return error.NoCamera;
            try value.validate();
        }
        var cameras = self.world.query(.{*Camera});
        while (cameras.next()) |view| {
            view.get(*Camera).active = if (entity) |id| view.entity.eql(id) else false;
            self.world.markChanged(view.entity, Camera);
        }
    }

    /// Return the active camera with highest priority; equal priorities use the lowest entity ID.
    pub fn activeEntity(self: Cameras) ?ecs.EntityId {
        var result: ?ecs.EntityId = null;
        var priority: i32 = std.math.minInt(i32);
        var cameras = self.world.query(.{*const Camera});
        while (cameras.next()) |view| {
            const value = view.get(*const Camera).*;
            if (!value.active) continue;
            if (result == null or value.priority > priority or
                (value.priority == priority and view.entity.id < result.?.id))
            {
                result = view.entity;
                priority = value.priority;
            }
        }
        return result;
    }
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
    /// Infinity sees without end (the editor's own camera): perspective projects to infinite
    /// depth, orthographic as far as `orthographic_reach_m`.
    far: f32 = 1000,
    projection: Projection = .perspective,
    orthographic_height_m: f32 = 10,

    /// How deep an orthographic view with an infinite `far` sees.
    const orthographic_reach_m: f32 = 100_000;

    /// Looking at the middle of the world from above and in front, for scenes without a camera.
    pub const default: View = lookingAt(.{ 0, 8, 18 }, .{ 0, 1, 0 }, .{});

    /// From `eye` towards `target`, as `camera` sees.
    /// Positions use world units (metres). Choose distinct points with a direction not
    /// parallel to world +y, so a useful up vector can be constructed. Returns plain data.
    ///
    /// ```zig
    /// const view = View.lookingAt(.{ 0, 2, 8 }, .{ 0, 0, 0 }, .{ .fov_deg = 70 });
    /// ```
    pub fn lookingAt(eye: [3]f32, target: [3]f32, camera: Camera) View {
        const forward = normalize(sub(target, eye));
        const right = normalize(cross(forward, .{ 0, 1, 0 }));
        return .{ .eye = eye, .forward = forward, .up = cross(right, forward), .fov_deg = camera.fov_deg, .near = camera.near, .far = camera.far, .projection = camera.projection, .orthographic_height_m = camera.orthographic_height_m };
    }

    /// The matrix taking world points to clip space, for a view `aspect` wide for each unit tall,
    /// as columns.
    /// `aspect` must be positive; use valid perspective settings (`0 < near < far` and
    /// a field of view between 0 and 180 degrees).
    ///
    /// ```zig
    /// const clip_from_world = View.default.viewProjection(1920.0 / 1080.0);
    /// ```
    pub fn viewProjection(self: View, aspect: f32) [4][4]f32 {
        const eye = math.Vec3{ .x = self.eye[0], .y = self.eye[1], .z = self.eye[2] };
        const target = math.Vec3{ .x = self.eye[0] + self.forward[0], .y = self.eye[1] + self.forward[1], .z = self.eye[2] + self.forward[2] };
        const view = math.mat.lookAt4x4(f32, eye, target, .{ .x = self.up[0], .y = self.up[1], .z = self.up[2] });
        const infinite = std.math.isInf(self.far);
        var projection = math.mat.perspective4x4(f32, self.fov_deg * std.math.rad_per_deg, aspect, self.near, if (infinite) self.near * 2 else self.far);
        // The limit as `far` grows without end: depth 1 only at infinity.
        if (infinite) {
            projection.data[2][2] = -1;
            projection.data[3][2] = -self.near;
        }
        if (self.projection == .orthographic) {
            const far = if (infinite) orthographic_reach_m else self.far;
            projection.data = .{
                .{ 2 / (self.orthographic_height_m * aspect), 0, 0, 0 },
                .{ 0, 2 / self.orthographic_height_m, 0, 0 },
                .{ 0, 0, 1 / (self.near - far), 0 },
                .{ 0, 0, self.near / (self.near - far), 1 },
            };
        }
        const matrix = math.mul(f32, 4, 4, 4, projection, view);
        var columns: [4][4]f32 = undefined;
        for (&columns, matrix.data) |*column, data| column.* = data;
        return columns;
    }

    /// Construct a world ray from NDC coordinates (-1 to 1, Y up) for either projection.
    pub fn ray(self: View, ndc: [2]f32, aspect: f32) Ray {
        const right = normalize(cross(self.forward, self.up));
        const half_height = if (self.projection == .orthographic) self.orthographic_height_m / 2 else @tan(self.fov_deg * std.math.rad_per_deg / 2);
        var offset: [3]f32 = undefined;
        for (&offset, right, self.up) |*value, r, u| value.* = r * ndc[0] * half_height * aspect + u * ndc[1] * half_height;
        var origin = self.eye;
        var direction = self.forward;
        for (&origin, &direction, offset) |*o, *d, value| {
            if (self.projection == .orthographic) o.* += value else d.* += value;
        }
        return .{ .origin = origin, .direction = normalize(direction) };
    }
};

pub const Ray = struct { origin: [3]f32, direction: [3]f32 };

/// The highest-priority active camera, placed by its world transform; null when none is active.
/// Borrows the world only during the query; returns a copy independent of ECS storage.
/// Equal priorities use the lowest entity ID, independently of ECS query order.
///
/// ```zig
/// const view = find(world) orelse View.default;
/// ```
pub fn find(world: *ecs.World) ?View {
    const entity = (Cameras{ .world = world }).activeEntity() orelse return null;
    const camera = world.get(entity, Camera).?.*;
    camera.validate() catch |err| {
        std.log.err("active camera {d} is invalid: {t}", .{ entity.id, err });
        return null;
    };
    const placed = transform_zig.worldMatrix(world, entity).data;
    return .{
        .eye = .{ placed[3][0], placed[3][1], placed[3][2] },
        .forward = normalize(.{ -placed[2][0], -placed[2][1], -placed[2][2] }),
        .up = normalize(.{ placed[1][0], placed[1][1], placed[1][2] }),
        .fov_deg = camera.fov_deg,
        .near = camera.near,
        .far = camera.far,
        .projection = camera.projection,
        .orthographic_height_m = camera.orthographic_height_m,
    };
}

/// Subtract `b` from `a` component-wise; inputs must use the same coordinate space and units.
///
/// ```zig
/// const displacement = sub(.{ 3, 2, 1 }, .{ 1, 2, 0 });
/// ```
pub fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return @as(@Vector(3, f32), a) - @as(@Vector(3, f32), b);
}

/// Return the right-handed cross product; its magnitude is not normalized.
///
/// ```zig
/// const normal = cross(.{ 1, 0, 0 }, .{ 0, 1, 0 });
/// ```
pub fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// Return a unit vector in `v`'s direction, or the unchanged zero vector for zero length.
///
/// ```zig
/// const direction = normalize(.{ 0, 0, -5 });
/// ```
pub fn normalize(v: [3]f32) [3]f32 {
    const length = @sqrt(@reduce(.Add, @as(@Vector(3, f32), v) * @as(@Vector(3, f32), v)));
    if (length == 0) return v;
    return @as(@Vector(3, f32), v) / @as(@Vector(3, f32), @splat(length));
}

/// Where world point `point` lands through `view_projection`: x and y from -1 to 1 (y up), and
/// whether it is in front of the camera.
/// Uses a column-major clip matrix; points behind return zero coordinates.
/// `in_front` does not mean inside the viewport or between the near/far planes.
///
/// ```zig
/// const projected = project(View.default.viewProjection(16.0 / 9.0), .{ 0, 1, 0 });
/// ```
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

test "an infinite far plane keeps distant points inside the depth range" {
    const view = View.lookingAt(.{ 0, 0, 0 }, .{ 0, 0, -1 }, .{ .far = std.math.inf(f32) });
    const columns = view.viewProjection(1);
    var previous: f32 = 0;
    for ([_]f32{ 1, 1_000, 1_000_000 }) |distance| {
        var clip: @Vector(4, f32) = columns[3];
        clip += @as(@Vector(4, f32), columns[2]) * @as(@Vector(4, f32), @splat(-distance));
        const depth = clip[2] / clip[3];
        try std.testing.expect(depth > previous and depth <= 1);
        previous = depth;
    }
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

test "camera selection is explicit and priority ties do not depend on archetypes" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const first = try world.spawn(.{ Camera{}, transform_zig.Transform{} });
    const second = try world.spawn(.{ Camera{ .priority = 10 }, transform_zig.Transform{} });
    const cameras = Cameras{ .world = &world };
    try std.testing.expect(cameras.activeEntity().?.eql(second));
    try cameras.setActive(first);
    try std.testing.expect(cameras.activeEntity().?.eql(first));
    world.get(second, Camera).?.near = -1;
    try std.testing.expectError(error.InvalidCamera, cameras.setActive(second));
    try std.testing.expect(cameras.activeEntity().?.eql(first));
    try cameras.setActive(null);
    try std.testing.expect(find(&world) == null);
}

test "orthographic projection preserves apparent size across depth" {
    const view = View.lookingAt(.{ 0, 0, 10 }, .{ 0, 0, 0 }, .{ .projection = .orthographic, .orthographic_height_m = 4 });
    const matrix = view.viewProjection(2);
    const near = project(matrix, .{ 2, 1, 0 });
    const far = project(matrix, .{ 2, 1, -20 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), near.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), near.y, 0.0001);
    try std.testing.expectApproxEqAbs(near.x, far.x, 0.0001);
    try std.testing.expectApproxEqAbs(near.y, far.y, 0.0001);
    const first = view.ray(.{ 0, 0 }, 2);
    const second = view.ray(.{ 1, 1 }, 2);
    try std.testing.expectEqualSlices(f32, &first.direction, &second.direction);
    try std.testing.expectEqualSlices(f32, &.{ 4, 2, 10 }, &second.origin);
}
