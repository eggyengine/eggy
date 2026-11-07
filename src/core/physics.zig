//! Physics: humpty run as a clutch plugin over Eggy's world. Entities with a `Collider` (and a
//! `RigidBody` to move) are simulated in 2D or 3D, as the scene's root says, in the project's
//! precision (`f32` or `f64`), with the root's `PhysicsSettings`; their `Transform`s follow
//! their bodies.
const std = @import("std");
const ecs = @import("clutch");
const math = @import("eggenvector");
const humpty = @import("humpty");
const Transform = @import("transform.zig").Transform;
const Time = @import("time.zig").Time;
const Mesh = @import("mesh.zig").Mesh;
const Resources = @import("resources/resources.zig").Resources;
const SceneRoot = @import("scene_root.zig").SceneRoot;
const DebugDraw = @import("debug_draw.zig").DebugDraw;

pub const RigidBody = humpty.ecs.RigidBody;
pub const Collider = humpty.ecs.Collider;
pub const LinearVelocity = humpty.ecs.LinearVelocity;
pub const AngularVelocity = humpty.ecs.AngularVelocity;
pub const CollidingEntities = humpty.ecs.CollidingEntities;
pub const PhysicsSettings = humpty.ecs.PhysicsSettings;
pub const CollisionStarted = humpty.ecs.CollisionStarted;
pub const CollisionEnded = humpty.ecs.CollisionEnded;
pub const PhysicsStage = humpty.ecs.PhysicsStage;
pub const RayFilter = humpty.ecs.RayFilter;

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

    /// Where `transform` puts `entity` in the world: after its parents' transforms.
    // ponytail: a parent scaled unevenly and turned shears its children, which a place can't
    // hold; scales multiply per axis, as if it didn't.
    pub fn place(world: *ecs.World, entity: ecs.EntityId, transform: Host.Transform) humpty.ecs.Place {
        const local: humpty.ecs.Place = .{ .position = transform.position, .rotation = transform.orientation(), .scale = transform.scale };
        const parent = world.getParent(entity) orelse return local;
        const above = place(world, parent, if (world.get(parent, Host.Transform)) |found| found.* else .{});
        return .{
            .position = above.position.add(above.rotation.rotateVector(local.position.mul(above.scale))),
            .rotation = above.rotation.mul(local.rotation),
            .scale = above.scale.mul(local.scale),
        };
    }

    /// Sets `transform` so `entity` is at `position`, turned by `rotation`, in the world.
    /// Its angles are kept as they are while they still turn it so, as when a body's rotation is
    /// locked: written back, a yaw of 120° would read (180, 60, 180).
    pub fn setPlace(world: *ecs.World, entity: ecs.EntityId, transform: *Host.Transform, position: math.Vec3, rotation: math.UnitQuat) void {
        var local_position = position;
        var local_rotation = rotation;
        if (world.getParent(entity)) |parent| {
            const above = place(world, parent, if (world.get(parent, Host.Transform)) |found| found.* else .{});
            const unscale = math.Vec3.init(1 / above.scale.x, 1 / above.scale.y, 1 / above.scale.z);
            local_position = above.rotation.inverseRotateVector(position.sub(above.position)).mul(unscale);
            local_rotation = above.rotation.inverse().mul(rotation);
        }
        transform.position = local_position;
        const same = @abs(@reduce(.Add, transform.orientation().quat.v * local_rotation.quat.v)) > 1 - 1e-6;
        if (!same) transform.setOrientation(local_rotation);
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
                // A rigged model's stored corners are in its bones' space; collide with it as drawn at rest.
                const rest = try @import("eggy_assets").rig.restVertices(gpa, model);
                defer gpa.free(rest);
                const positions = try gpa.alloc([3]f32, rest.len);
                errdefer gpa.free(positions);
                for (positions, rest) |*p, v| p.* = v.position;
                const indices = try gpa.alloc([3]u32, model.indices.len / 3);
                for (indices, 0..) |*triangle, i| triangle.* = model.indices[i * 3 ..][0..3].*;
                break :blk .{ .triangles = .{ .positions = positions, .indices = indices } };
            },
        };
    }
};

/// Which plugin `install` put in this world, so it is installed once.
const Installed = struct { dimension: humpty.Dim, precision: Precision };

pub const Precision = humpty.ecs.Precision;

/// The precision `eggy.zon`'s `.physics` asks for.
pub fn precisionOf(config: @import("project.zig").Physics) Precision {
    return switch (config.precision) {
        .f32 => .f32,
        .f64 => .f64,
    };
}

/// Installs physics in `world`, unless already installed: 2D or 3D as its scene's root says
/// (`SceneRoot.dimension`; 3D without one), in `precision` (the project's, `eggy.zon`'s
/// `.physics`), with its first `PhysicsSettings`. Call each gameplay frame before the world's
/// update stages; a world made again (`App.resetWorld`) gets it again.
///
/// ```zig
/// try physics.install(&app.world, gpa, app.physics_precision);
/// ```
pub fn install(world: *ecs.World, gpa: std.mem.Allocator, precision: Precision) !void {
    if (world.getResource(Installed) != null) return;
    var roots = world.query(.{*const SceneRoot});
    const dimension: humpty.Dim = if (roots.next()) |view| view.get(*const SceneRoot).dimension else .three;
    var found = world.query(.{*const PhysicsSettings});
    const settings: PhysicsSettings = if (found.next()) |view| view.get(*const PhysicsSettings).* else .{};
    switch (dimension) {
        inline else => |dim| switch (precision) {
            inline else => |chosen| try Plugin(dim, chosen.Type()).install(world, gpa, settings),
        },
    }
    try world.insertResource(Installed{ .dimension = dimension, .precision = precision });
}

pub const Hit = struct { entity: ecs.EntityId, point: math.Vec3, normal: math.Vec3, distance_m: f32 };

/// The nearest entity a ray from `origin` along unit `direction` meets, in whichever space the
/// world's physics runs; null without physics.
///
/// ```zig
/// if (physics.raycast(&app.world, eye, forward, 100, .{})) |hit| aim(hit.entity);
/// // Ground beneath a body, past its own collider.
/// const grounded = physics.raycast(&app.world, feet, down, 0.1, .{ .exclude = player }) != null;
/// ```
pub fn raycast(world: *ecs.World, origin: math.Vec3, direction: math.Vec3, max_distance_m: f32, filter: RayFilter) ?Hit {
    const installed = world.getResource(Installed) orelse return null;
    switch (installed.dimension) {
        inline else => |dim| switch (installed.precision) {
            inline else => |precision| {
                const P = Plugin(dim, precision.Type());
                const res = world.getResource(P.Resource) orelse return null;
                const hit = res.raycast(origin, direction, max_distance_m, filter) orelse return null;
                return .{ .entity = hit.entity, .point = hit.point, .normal = hit.normal, .distance_m = hit.distance_m };
            },
        },
    }
}

/// Wireframes of the colliders on `only` (every collider when null) into `draw`, coloured by
/// what they are on (`humpty.debug_draw.palette`). Drawn from components, so it shows colliders
/// in an editor that isn't playing as well as in a running game. Stops quietly once `draw` is
/// full.
///
/// ```zig
/// try physics.drawColliders(&app.world, gpa, &.{selected}, &app.debug_draw);
/// ```
pub fn drawColliders(world: *ecs.World, gpa: std.mem.Allocator, only: ?[]const ecs.EntityId, draw: *DebugDraw) !void {
    try drawWith(world, draw, .{ .colliders = only, .gpa = gpa });
}

/// Every collider, as `drawColliders` draws them, and where they touched in the last step, in
/// red: what the console's `physics debug on` shows each frame.
pub fn drawDebug(world: *ecs.World, gpa: std.mem.Allocator, draw: *DebugDraw) !void {
    try drawWith(world, draw, .{ .colliders = null, .gpa = gpa, .contacts = true });
}

const Drawn = struct { colliders: ?[]const ecs.EntityId, gpa: std.mem.Allocator, contacts: bool = false };

fn drawWith(world: *ecs.World, draw: *DebugDraw, drawn: Drawn) !void {
    // A running world says which plugin it is; otherwise its scene says the dimension, and
    // precision doesn't change a wireframe.
    const installed = world.getResource(Installed);
    var roots = world.query(.{*const SceneRoot});
    const dimension: humpty.Dim = if (installed) |found| found.dimension else if (roots.next()) |view| view.get(*const SceneRoot).dimension else .three;
    const precision: Precision = if (installed) |found| found.precision else .f32;
    switch (dimension) {
        inline else => |dim| switch (precision) {
            inline else => |chosen| {
                const P = Plugin(dim, chosen.Type());
                P.drawColliders(world, drawn.colliders, drawn.gpa, draw) catch |err| switch (err) {
                    error.DebugDrawCapacity => return,
                    else => return err,
                };
                if (drawn.contacts) P.drawContacts(world, draw) catch |err| switch (err) {
                    error.DebugDrawCapacity => return,
                    else => return err,
                };
            },
        },
    }
}

fn runFrames(world: *ecs.World, frames: usize) !void {
    try runFramesIn(world, frames, .f32);
}

fn runFramesIn(world: *ecs.World, frames: usize, precision: Precision) !void {
    for (0..frames) |_| {
        try install(world, std.testing.allocator, precision);
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

    const ground = try world.spawn(.{ Transform{ .scale = .init(10, 1, 10) }, Collider{} });
    const crate = try world.spawn(.{ Transform{ .position = .init(0, 3, 0) }, Collider{}, RigidBody{} });
    try runFrames(&world, 180);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), world.get(crate, Transform).?.position.y, 0.03);
    try std.testing.expect(std.meta.eql(raycast(&world, .init(0, 5, 0), .init(0, -1, 0), 10, .{}).?.entity, crate));
    // From inside the crate, leaving it out: the ground half a metre down.
    const below = raycast(&world, .init(0, 1, 0), .init(0, -1, 0), 10, .{ .exclude = crate }).?;
    try std.testing.expect(std.meta.eql(below.entity, ground));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), below.distance_m, 0.03);
    // A static collider is left out too.
    try std.testing.expect(raycast(&world, .init(3, 5, 0), .init(0, -1, 0), 10, .{ .exclude = ground }) == null);
}

test "a body under a moved, scaled parent rests on the ground in world space" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    defer world.runStage(.Deinit) catch {};

    _ = try world.spawn(.{ Transform{}, Collider{ .shape = .{ .half_space = .{} } } });
    const holder = try world.spawn(.{Transform{ .position = .init(4, 2, 0), .scale = .splat(0.5) }});
    const crate = try world.spawn(.{ Transform{ .position = .init(0, 4, 0) }, Collider{}, RigidBody{} });
    try world.setParent(crate, holder);
    try runFrames(&world, 240);
    // Half a metre tall at half scale: its centre a quarter metre up, which is -3.5 in its parent.
    try std.testing.expectApproxEqAbs(@as(f32, -3.5), world.get(crate, Transform).?.position.y, 0.06);
    try std.testing.expectApproxEqAbs(@as(f32, 0), world.get(crate, Transform).?.position.x, 0.01);
}

test "a static collider follows its parent when only the parent moves" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    defer world.runStage(.Deinit) catch {};

    const hinge = try world.spawn(.{Transform{}});
    const door = try world.spawn(.{ Transform{}, Collider{} });
    try world.setParent(door, hinge);
    try runFrames(&world, 1);
    world.get(hinge, Transform).?.position = .init(0, 3, 0);
    try runFrames(&world, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 6.5), raycast(&world, .init(0, 10, 0), .init(0, -1, 0), 20, .{}).?.distance_m, 1e-3);
}

test "a body that isn't turned keeps its angles as written" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const entity = try world.spawn(.{Transform{ .rotation_deg = .init(0, 120, 0) }});
    const transform = world.get(entity, Transform).?;
    Host.setPlace(&world, entity, transform, .init(1, 0, 0), transform.orientation());
    try std.testing.expectEqual(math.Vec3.init(0, 120, 0), transform.rotation_deg);
}

test "a 2D scene in a double-precision project gets that world, and a sphere mesh collides as a ball" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    defer world.runStage(.Deinit) catch {};

    _ = try world.spawn(.{ SceneRoot{ .dimension = .two }, PhysicsSettings{} });
    _ = try world.spawn(.{ Transform{}, Collider{ .shape = .{ .half_space = .{} } } });
    const ball = try world.spawn(.{ Transform{ .position = .init(0, 2, 0) }, Mesh{ .shape = .sphere }, Collider{ .shape = .convex_hull_from_mesh }, RigidBody{} });
    try runFramesIn(&world, 180, .f64);
    try std.testing.expect(world.getResource(Plugin(.two, f64).Resource) != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), world.get(ball, Transform).?.position.y, 0.03);
}

test "drawColliders outlines a collider in the scene's dimension without running physics" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    _ = try world.spawn(.{ SceneRoot{ .dimension = .two }, PhysicsSettings{} });
    const crate = try world.spawn(.{ Transform{ .position = .init(3, 0, 0) }, Collider{} });
    var draw: DebugDraw = .{};
    try drawColliders(&world, gpa, &.{crate}, &draw);
    // A 2D box: four edges, the nearest at 3 - 0.5.
    try std.testing.expectEqual(@as(usize, 4), draw.line_count);
    var min_x: f32 = std.math.inf(f32);
    for (draw.lines[0..draw.line_count]) |line| min_x = @min(min_x, line.from_m.x, line.to_m.x);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), min_x, 1e-4);
}

test "drawDebug adds contact markers once bodies touch" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    defer world.runStage(.Deinit) catch {};
    _ = try world.spawn(.{ Transform{ .scale = .init(10, 1, 10) }, Collider{} });
    _ = try world.spawn(.{ Transform{ .position = .init(0, 1, 0) }, Collider{}, RigidBody{} });
    try runFrames(&world, 30);
    var only_colliders: DebugDraw = .{};
    try drawColliders(&world, gpa, null, &only_colliders);
    var everything: DebugDraw = .{};
    try drawDebug(&world, gpa, &everything);
    try std.testing.expectEqual(@as(usize, 24), only_colliders.line_count);
    try std.testing.expect(everything.line_count > only_colliders.line_count);
}
