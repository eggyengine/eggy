//! Physics: humpty run as a clutch plugin over Eggy's world. Entities with a `Collider` (and a
//! `RigidBody` to move) are simulated in 2D or 3D, in `f32` or `f64`, as the scene's
//! `PhysicsSettings` (on its root entity) asks, their `Transform`s following their bodies.
const std = @import("std");
const ecs = @import("clutch");
const math = @import("eggenvector");
const humpty = @import("humpty");
const Transform = @import("transform.zig").Transform;
const Time = @import("time.zig").Time;
const Mesh = @import("mesh.zig").Mesh;
const Resources = @import("resources/resources.zig").Resources;

pub const RigidBody = humpty.ecs.RigidBody;
pub const Collider = humpty.ecs.Collider;
pub const LinearVelocity = humpty.ecs.LinearVelocity;
pub const AngularVelocity = humpty.ecs.AngularVelocity;
pub const CollidingEntities = humpty.ecs.CollidingEntities;
pub const PhysicsSettings = humpty.ecs.PhysicsSettings;
pub const CollisionStarted = humpty.ecs.CollisionStarted;
pub const CollisionEnded = humpty.ecs.CollisionEnded;
pub const PhysicsStage = humpty.ecs.PhysicsStage;

/// The physics components every project has.
pub const components = .{ RigidBody, Collider, LinearVelocity, AngularVelocity, CollidingEntities, PhysicsSettings };

/// The plugin for each space a scene can pick; `Plugin(.three, f32).Resource` is its world.
pub fn Plugin(comptime dim: humpty.Dim, comptime T: type) type {
    return humpty.ecs.Plugin(dim, T, Host);
}

/// How physics reads and moves Eggy's entities.
pub const Host = struct {
    pub const Transform = @import("transform.zig").Transform;
    pub const Time = @import("time.zig").Time;

    pub fn deltaSeconds(time: *const Host.Time) f32 {
        return time.delta_s;
    }

    pub fn place(transform: Host.Transform) humpty.ecs.Place {
        return .{ .position = transform.position, .rotation = transform.orientation(), .scale = transform.scale };
    }

    pub fn setPlace(transform: *Host.Transform, position: math.Vec3, rotation: math.UnitQuat) void {
        transform.position = position;
        transform.setOrientation(rotation);
    }

    /// The entity's `Mesh`: a built-in shape as its exact collider, a model as its triangles,
    /// loaded through the world's `Resources`.
    pub fn mesh(world: *ecs.World, entity: ecs.EntityId, gpa: std.mem.Allocator) !?humpty.ecs.MeshSource {
        const drawn = world.get(entity, Mesh) orelse return null;
        // Built-in shapes are unit sized: half a metre each way, flat ones a millimetre thick.
        return switch (drawn.shape) {
            .cube => .{ .shape = .{ .cuboid = .{} } },
            .sphere => .{ .shape = .{ .ball = .{} } },
            .cylinder => .{ .shape = .{ .cylinder = .{} } },
            .cone => .{ .shape = .{ .cone = .{} } },
            .plane => .{ .shape = .{ .cuboid = .{ .half_extents_m = .init(0.5, 0.001, 0.5) } } },
            .quad => .{ .shape = .{ .cuboid = .{ .half_extents_m = .init(0.5, 0.5, 0.001) } } },
            .model => |file| blk: {
                const resources = world.getResource(Resources) orelse return error.NoResources;
                var model = try resources.loadModel(gpa, file);
                defer model.deinit(gpa);
                const positions = try gpa.alloc([3]f32, model.vertices.len);
                errdefer gpa.free(positions);
                for (positions, model.vertices) |*p, v| p.* = v.position;
                const indices = try gpa.alloc([3]u32, model.indices.len / 3);
                for (indices, 0..) |*triangle, i| triangle.* = model.indices[i * 3 ..][0..3].*;
                break :blk .{ .triangles = .{ .positions = positions, .indices = indices } };
            },
        };
    }
};

/// Which plugin `install` put in this world, so it is installed once.
const Installed = struct { dimension: humpty.Dim, precision: humpty.ecs.Precision };

/// Installs physics in `world` for the space its first `PhysicsSettings` asks for (3D, `f32`
/// when there is none), unless already installed. Call each gameplay frame before the world's
/// update stages; a world made again (`App.resetWorld`) gets it again.
///
/// ```zig
/// try physics.install(&app.world, gpa);
/// ```
pub fn install(world: *ecs.World, gpa: std.mem.Allocator) !void {
    if (world.getResource(Installed) != null) return;
    var found = world.query(.{*const PhysicsSettings});
    const settings: PhysicsSettings = if (found.next()) |view| view.get(*const PhysicsSettings).* else .{};
    switch (settings.dimension) {
        inline else => |dim| switch (settings.precision) {
            inline else => |precision| try Plugin(dim, if (precision == .f32) f32 else f64).install(world, gpa, settings),
        },
    }
    try world.insertResource(Installed{ .dimension = settings.dimension, .precision = settings.precision });
}

pub const Hit = struct { entity: ecs.EntityId, point: math.Vec3, normal: math.Vec3, distance_m: f32 };

/// The nearest entity a ray from `origin` along unit `direction` meets, in whichever space the
/// world's physics runs; null without physics.
///
/// ```zig
/// if (physics.raycast(&app.world, eye, forward, 100)) |hit| aim(hit.entity);
/// ```
pub fn raycast(world: *ecs.World, origin: math.Vec3, direction: math.Vec3, max_distance_m: f32) ?Hit {
    const installed = world.getResource(Installed) orelse return null;
    switch (installed.dimension) {
        inline else => |dim| switch (installed.precision) {
            inline else => |precision| {
                const P = Plugin(dim, if (precision == .f32) f32 else f64);
                const res = world.getResource(P.Resource) orelse return null;
                const hit = res.raycast(origin, direction, max_distance_m) orelse return null;
                return .{ .entity = hit.entity, .point = hit.point, .normal = hit.normal, .distance_m = hit.distance_m };
            },
        },
    }
}

fn runFrames(world: *ecs.World, frames: usize) !void {
    for (0..frames) |_| {
        try install(world, std.testing.allocator);
        try world.insertResource(Time{ .delta_s = 1.0 / 60.0 });
        try world.runStage(PhysicsStage);
        world.tick();
    }
}

test "a crate falls onto scaled static ground, and its Transform follows" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    defer world.runStage(.Deinit) catch {};

    _ = try world.spawn(.{ Transform{ .scale = .init(10, 1, 10) }, Collider{} });
    const crate = try world.spawn(.{ Transform{ .position = .init(0, 3, 0) }, Collider{}, RigidBody{} });
    try runFrames(&world, 180);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), world.get(crate, Transform).?.position.y, 0.03);
    try std.testing.expect(std.meta.eql(raycast(&world, .init(0, 5, 0), .init(0, -1, 0), 10).?.entity, crate));
}

test "a scene asking for 2D in double precision gets it, and a sphere mesh collides as a ball" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    defer world.runStage(.Deinit) catch {};

    _ = try world.spawn(.{PhysicsSettings{ .dimension = .two, .precision = .f64 }});
    _ = try world.spawn(.{ Transform{}, Collider{ .shape = .{ .half_space = .{} } } });
    const ball = try world.spawn(.{ Transform{ .position = .init(0, 2, 0) }, Mesh{ .shape = .sphere }, Collider{ .shape = .convex_hull_from_mesh }, RigidBody{} });
    try runFrames(&world, 180);
    try std.testing.expect(world.getResource(Plugin(.two, f64).Resource) != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), world.get(ball, Transform).?.position.y, 0.03);
}
