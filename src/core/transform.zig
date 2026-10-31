//! `Transform`: where an entity is, how it is turned and how big it is, relative to its parent.
//! A built-in component: every project's Inspector can add it.
const std = @import("std");
const ecs = @import("clutch");
const math = @import("eggenvector");

pub const Transform = struct {
    /// Marks it in the editor (nf-md-axis_arrow).
    pub const icon = "\u{f0d49}";
    pub const category = "Scene";
    position: math.Vec3 = .zero,
    /// Turns about x, then y, then z, in degrees.
    rotation_deg: math.Vec3 = .zero,
    scale: math.Vec3 = .one,

    /// The matrix taking points from the entity's space into its parent's: scaled, turned, then
    /// moved.
    /// Positions are in parent-space metres, rotations in degrees, and scales unitless.
    /// Returns the matrix by value without changing ECS storage.
    ///
    /// ```zig
    /// const local = (Transform{ .position = .init(0, 2, 0) }).matrix();
    /// ```
    pub fn matrix(self: Transform) math.Mat4 {
        const radians = self.rotation_deg.scale(std.math.rad_per_deg);
        const turn = math.mul(f32, 4, 4, 4, math.mat.rotationZ4x4(f32, radians.z), math.mul(f32, 4, 4, 4, math.mat.rotationY4x4(f32, radians.y), math.mat.rotationX4x4(f32, radians.x)));
        const scaled = math.mul(f32, 4, 4, 4, turn, math.mat.scaling4x4(f32, self.scale.x, self.scale.y, self.scale.z));
        return math.mul(f32, 4, 4, 4, math.translationVec4x4(f32, self.position), scaled);
    }

    /// Which way it faces, in its parent's space: its -z turned by its rotation (one metre long).
    /// A camera looks this way.
    /// Ignores scale and translation.
    ///
    /// ```zig
    /// const ahead = (Transform{}).forward(); // (0, 0, -1)
    /// ```
    pub fn forward(self: Transform) math.Vec3 {
        return self.axis(.forward);
    }

    /// Its right, in its parent's space: its +x turned by its rotation.
    /// Returns a unit direction, independent of scale and translation.
    ///
    /// ```zig
    /// const rightward = (Transform{}).right();
    /// ```
    pub fn right(self: Transform) math.Vec3 {
        return self.axis(.right);
    }

    /// Its up, in its parent's space: its +y turned by its rotation.
    /// Returns a unit direction, independent of scale and translation.
    ///
    /// ```zig
    /// const upward = (Transform{}).up();
    /// ```
    pub fn up(self: Transform) math.Vec3 {
        return self.axis(.up);
    }

    /// Move it by `offset` (in its parent's space): `transform.translate(transform.forward())`
    /// steps a metre ahead.
    /// Mutates only this value; when editing a borrowed ECS component, also mark it changed
    /// through the world so observers see the edit.
    ///
    /// ```zig
    /// var transform = Transform{};
    /// transform.translate(.init(0, 1, 0));
    /// ```
    pub fn translate(self: *Transform, offset: math.Vec3) void {
        self.position = self.position.add(offset);
    }

    /// `direction` turned by the rotation alone.
    fn axis(self: Transform, direction: math.Vec3) math.Vec3 {
        const turned = Transform{ .rotation_deg = self.rotation_deg };
        return math.transformDirection4x4(f32, turned.matrix(), direction);
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

/// `m` as plain columns, for `extern` structs and GPU buffers, which can't hold `math.Mat4`'s
/// SIMD columns. `math.fromArray(f32, 4, 4, columns)` turns them back.
///
/// ```zig
/// drawable.model = columns(worldMatrix(world, entity));
/// ```
pub fn columns(m: math.Mat4) [4][4]f32 {
    var out: [4][4]f32 = undefined;
    for (&out, m.data) |*column, data| column.* = data;
    return out;
}

test "a transform's inverse takes its points back" {
    const transform = Transform{ .position = .init(3, -1, 2), .rotation_deg = .init(30, 45, 10), .scale = .init(2, 0.5, 1) };
    const back = math.inverse4x4(f32, transform.matrix()).?;
    const moved = math.transformPoint4x4(f32, transform.matrix(), .init(1, 2, 3));
    try std.testing.expect(math.transformPoint4x4(f32, back, moved).approxEql(.init(1, 2, 3), 0.001));
    try std.testing.expect(math.inverse4x4(f32, (Transform{ .scale = .init(0, 1, 1) }).matrix()) == null);
}

test "a transform scales, then turns, then moves" {
    const transform = Transform{ .position = .init(10, 0, 0), .rotation_deg = .init(0, 0, 90), .scale = .splat(2) };
    const corner = math.transformPoint4x4(f32, transform.matrix(), .unit_x);
    try std.testing.expectApproxEqAbs(@as(f32, 10), corner.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), corner.y, 0.001);
}

test "a transform faces down its -z, turned as it is" {
    var transform = Transform{ .rotation_deg = .init(0, 90, 0) };
    // Turned a quarter left about y: it faces -x, and its right is -z.
    try std.testing.expect(transform.forward().approxEql(.left, 0.001));
    try std.testing.expect(transform.right().approxEql(.forward, 0.001));
    transform.translate(transform.forward());
    try std.testing.expectApproxEqAbs(@as(f32, -1), transform.position.x, 0.001);
}
