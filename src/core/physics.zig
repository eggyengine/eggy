//! Physics: entities with a `Collider`, moved by a `RigidBody` beside it, stepped by humpty
//! during play, with their `Transform`s following the bodies.
const std = @import("std");
const ecs = @import("clutch");
const math = @import("eggenvector");
const humpty = @import("humpty");
const Transform = @import("transform.zig").Transform;

pub const RigidBody = humpty.eggy_types.RigidBody;
pub const Collider = humpty.eggy_types.Collider;

// ponytail: Transforms are taken as world space, so a physics entity under a moved parent is
// misplaced, and a Collider attaches only to a RigidBody on its own entity. Walk the parent
// chain (compound bodies from child Colliders) when scenes nest physics.
/// The humpty world mirroring the ECS world's physics entities. Lives on `App` as `physics`.
pub const Physics = struct {
    sim: ?humpty.Physics = null,
    links: std.AutoHashMapUnmanaged(ecs.EntityId, Link) = .empty,
    gravity: math.Vec3 = .init(0, -9.81, 0),

    const fixed_step_s: f32 = 1.0 / 60.0;

    /// One entity's body and collider, with what they were built from, so an edit rebuilds them.
    const Link = struct {
        body: ?humpty.BodyHandle,
        collider: humpty.ColliderHandle,
        rigid_body: ?RigidBody,
        source: Collider,
        /// The Transform as physics last left it; any other change is a move by the game or the
        /// Inspector, taken as the body's new place.
        transform: Transform,
        seen: bool = true,
    };

    pub fn deinit(self: *Physics, gpa: std.mem.Allocator) void {
        if (self.sim) |*sim| sim.deinit();
        self.links.deinit(gpa);
        self.* = .{};
    }

    /// Advances the simulation by `delta_s` and moves the bodies' Transforms. Entities that gained,
    /// changed or lost their physics components since the last call are rebuilt or dropped first.
    /// Once per gameplay frame, after the game's systems.
    ///
    /// ```zig
    /// try app.physics.step(gpa, &app.world, app.time.delta_s);
    /// ```
    pub fn step(self: *Physics, gpa: std.mem.Allocator, world: *ecs.World, delta_s: f32) !void {
        if (self.sim == null) self.sim = try humpty.Physics.init(gpa, .{ .gravity = self.gravity, .fixed_step_s = fixed_step_s });
        const sim = &self.sim.?;

        var links = self.links.valueIterator();
        while (links.next()) |link| link.seen = false;
        try self.sync(gpa, world, sim);
        try self.dropUnseen(gpa, sim);

        if (!std.math.isFinite(delta_s)) return;
        try sim.update(delta_s);

        // Moving bodies carry their Transforms; scale is the entity's own.
        var entries = self.links.iterator();
        while (entries.next()) |entry| {
            const link = entry.value_ptr;
            const body = link.body orelse continue;
            if (sim.isSleeping(body) or link.rigid_body.?.kind != .dynamic) continue;
            const transform = world.get(entry.key_ptr.*, Transform) orelse continue;
            const pose = sim.pose(body);
            transform.position = pose.translation;
            transform.setOrientation(pose.rotation);
            world.markChanged(entry.key_ptr.*, Transform);
            link.transform = transform.*;
        }
    }

    /// Builds a body for each new or edited physics entity, and moves bodies whose Transforms moved.
    fn sync(self: *Physics, gpa: std.mem.Allocator, world: *ecs.World, sim: *humpty.Physics) !void {
        var colliders = world.query(.{ *Collider, *Transform });
        while (colliders.next()) |view| {
            const collider = view.get(*Collider).*;
            const transform = view.get(*Transform).*;
            const rigid_body: ?RigidBody = if (world.get(view.entity, RigidBody)) |found| found.* else null;
            const slot = try self.links.getOrPut(gpa, view.entity);
            if (slot.found_existing) {
                const link = slot.value_ptr;
                link.seen = true;
                const same_parts = std.meta.eql(link.rigid_body, rigid_body) and std.meta.eql(link.source, collider) and link.transform.scale.eql(transform.scale);
                if (same_parts and std.meta.eql(link.transform, transform)) continue;
                if (same_parts and link.body != null) {
                    sim.setPose(link.body.?, poseOf(transform));
                    link.transform = transform;
                    continue;
                }
                // Scenery colliders and edited parts are rebuilt where they now are.
                if (link.body) |body| sim.removeBody(body) else sim.removeCollider(link.collider);
            }
            slot.value_ptr.* = build(sim, rigid_body, collider, transform) catch |err| {
                self.links.removeByPtr(slot.key_ptr);
                return err;
            };
        }
    }

    fn dropUnseen(self: *Physics, gpa: std.mem.Allocator, sim: *humpty.Physics) !void {
        var gone: std.ArrayList(ecs.EntityId) = .empty;
        defer gone.deinit(gpa);
        var entries = self.links.iterator();
        while (entries.next()) |entry| {
            if (entry.value_ptr.seen) continue;
            if (entry.value_ptr.body) |body| sim.removeBody(body) else sim.removeCollider(entry.value_ptr.collider);
            try gone.append(gpa, entry.key_ptr.*);
        }
        for (gone.items) |entity| _ = self.links.remove(entity);
    }
};

fn build(sim: *humpty.Physics, rigid_body: ?RigidBody, collider: Collider, transform: Transform) !Physics.Link {
    const pose = poseOf(transform);
    const body = if (rigid_body) |found| try sim.addBody(.{
        .kind = switch (found.kind) {
            .static => .static,
            .dynamic => .dynamic,
        },
        .pose = pose,
        .mass_kg = found.mass_kg,
    }) else null;
    errdefer if (body) |handle| sim.removeBody(handle);
    const handle = try sim.addCollider(.{
        .shape = shapeOf(collider.shape, transform.scale),
        // With no body, a collider's own pose is where it sits in the world.
        .local_pose = if (body == null) pose else math.Isometry3(f32).identity(),
        .material = .{ .restitution = collider.restitution, .friction = collider.friction },
    }, body);
    return .{ .body = body, .collider = handle, .rigid_body = rigid_body, .source = collider, .transform = transform };
}

fn poseOf(transform: Transform) math.Isometry3(f32) {
    return .fromParts(transform.position, transform.orientation());
}

/// The collider's shape at the entity's scale; a sphere takes the largest axis.
fn shapeOf(shape: Collider.Shape, scale: math.Vec3) humpty.Shape {
    const size = scale.abs();
    return switch (shape) {
        .sphere => |sphere| .{ .sphere = .{ .radius = sphere.radius_m * @max(size.x, size.y, size.z) } },
        .box => |box| .{ .box = .{ .half_extents = box.half_extents_m.mul(size) } },
    };
}

test "a dynamic body falls onto static scenery and its Transform follows" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    var physics: Physics = .{};
    defer physics.deinit(gpa);

    _ = try world.spawn(.{ Transform{ .scale = .init(10, 1, 10) }, Collider{} });
    const crate = try world.spawn(.{ Transform{ .position = .init(0, 3, 0) }, Collider{}, RigidBody{} });
    for (0..180) |_| try physics.step(gpa, &world, 1.0 / 60.0);

    // The ground's top is at 0.5, so the crate's centre rests a half metre above it.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), world.get(crate, Transform).?.position.y, 0.02);
}

test "an entity that loses its Collider leaves the simulation" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    var physics: Physics = .{};
    defer physics.deinit(gpa);

    const ball = try world.spawn(.{ Transform{}, Collider{}, RigidBody{} });
    try physics.step(gpa, &world, 1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 1), physics.links.count());
    world.remove(ball, Collider);
    try physics.step(gpa, &world, 1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 0), physics.links.count());
}
