---
title: humpty
sidebar_position: 6
---

humpty is the rigid-body physics under Eggy's [Physics](../guides/physics.md), in 2D or 3D and
`f32` or `f64`, after Rapier and Avian. It doesn't import Eggy, so any Zig 0.17 project can use
it: on its own as a physics world, or inside a [clutch](https://github.com/eggyengine/clutch)
ECS world as a plugin. Its only dependencies are clutch and the eggenvector maths library.

## Add it to a project

```sh
zig fetch --save git+https://github.com/eggyengine/humpty
```

```zig
// build.zig
const humpty = b.dependency("humpty", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("humpty", humpty.module("humpty"));
```

`zig build docs` in humpty's checkout writes the full API reference to `zig-out/docs`.

## A world

`humpty.Physics(dim, T)` is a world type: `dim` is `.two` or `.three`, and `T` the scalar it
computes in. `Physics2` and `Physics3` are the `f32` ones. Every vector, pose and shape below
is that world's: `World.Vec`, `World.Pose`, `World.Shape`.

```zig
const humpty = @import("humpty");
const World = humpty.Physics3;

var world = try World.init(gpa, .{ .gravity = .init(0, -9.81, 0), .fixed_step_s = 1.0 / 60.0 });
defer world.deinit();

// Ground: a collider with no body is static scenery.
_ = try world.addCollider(.{ .shape = .{ .half_space = .{ .normal = .init(0, 1, 0) } } }, null, 0);

// A ball: a body, and the collider it touches the world with.
const ball = try world.addBody(.{ .kind = .dynamic, .pose = .fromTranslation(.init(0, 10, 0)), .mass_kg = 1 }, 1);
_ = try world.addCollider(.{
    .shape = .{ .ball = .{ .radius = 0.5 } },
    .material = .{ .restitution = 0.3, .friction = 0.5 },
}, ball, 1);

// Each frame, with the frame's length in seconds.
try world.update(frame_s);
const where = world.pose(ball).translation;
```

`update` runs as many fixed steps as fit in the frame and carries the rest over, so the
simulation is the same at any frame rate.

The last argument of `addBody` and `addCollider` is a `u64` of your own, read back with
`bodyData` and `colliderData`: an entity id, an index into your own array. Handles are
generational, so one kept after its body is removed goes stale (`contains` says false) instead
of naming whatever reuses the slot.

| Call | Does |
| --- | --- |
| `addBody(body, data)`, `removeBody(handle)` | Adds a body, or removes it with its colliders. |
| `addCollider(collider, body, data)`, `removeCollider(handle)` | Attaches a collider to a body, or with `null` adds static scenery. |
| `pose(body)`, `setPose(body, pose)` | Where a body is, or teleports it. |
| `velocity(body)`, `setVelocity(body, .{ .linear, .angular })` | How fast it moves (m/s) and turns (rad/s). |
| `applyImpulse(body, impulse_ns, .center_of_mass)` | Pushes it, in N·s; `.{ .at_world_point = p }` pushes off-centre and spins it. |
| `setColliderPose(collider, pose)` | Moves a collider on its body, or in the world when it has none. |
| `isSleeping(body)` | Whether it has settled; touching or pushing it wakes it. |
| `contacts()`, `started()`, `ended()` | The last step's contact points, and the collider pairs that began and stopped touching. |
| `raycast(ray, filter)` | The nearest collider along a ray. |
| `debugDraw(options, sink)` | The world as lines, for any renderer. |

## Bodies and colliders

A `Body` has a `kind`: `.dynamic` bodies are pushed by gravity, contacts and impulses;
`.kinematic` ones move only at the velocity you give them and push dynamic ones aside;
`.static` ones never move. Only dynamic bodies have `mass_kg`, spread over their colliders by
volume for how they turn. `gravity_scale`, `linear_damping` and `angular_damping` tune how it
moves, and `rotation = .locked` keeps it from turning at all, for characters.

A `Collider` has a `shape`, a `local_pose` on its body (in the world when it has none), a
`material` (`restitution` 0 to 1, `friction`) and `sensor`: a sensor reports what it overlaps
in `started` and `ended` without pushing anything.

| Shape | Fields |
| --- | --- |
| `ball` | `radius` |
| `cuboid` | `half_extents` |
| `capsule` | `half_height` of the straight part, `radius`; along local y |
| `cylinder`, `cone` | `half_height`, `radius`; along local y; 3D only |
| `convex_hull` | `points`, copied |
| `mesh` | `vertices` and `indices` (triangles in 3D, segments in 2D), copied; static only |
| `half_space` | `normal`: everything behind the plane through the origin |

## Rays

```zig
const hit = world.raycast(.{
    .origin = eye,
    .direction = forward, // unit length
    .max_distance_m = 100,
}, .{ .exclude_body = player, .sensors = .skip }) orelse return;
// hit.collider, hit.point, hit.normal, hit.distance_m
```

A ray that starts inside a collider meets it at distance 0, so leave out the body casting it
with `exclude_body` (or one collider with `exclude_collider`).

## Debug drawing

humpty doesn't draw; it hands line segments to a sink you give it, any value with a
`line(from, to, color)` method:

```zig
const Lines = struct {
    renderer: *MyRenderer,
    pub fn line(self: *@This(), from: World.Vec, to: World.Vec, color: [4]f32) !void {
        try self.renderer.addLine(from.toArray(), to.toArray(), color);
    }
};
var lines: Lines = .{ .renderer = &renderer };
try world.debugDraw(.{}, &lines);
```

Each collider is drawn in its `humpty.debug_draw.palette` colour (static grey, dynamic green,
kinematic purple, sleeping blue, sensor yellow), and each contact as a red cross with its
normal. `DebugDrawOptions` turns either off and sizes the crosses. To draw one shape yourself,
`humpty.debug_draw.DebugDraw(World.S).shape(shape, pose, color, &lines)`.

## In a clutch world

`humpty.ecs` runs a world inside a clutch ECS world. Entities get components; the plugin builds
bodies for them, steps the world in its own stage after `Update`, and writes where bodies went
back to your transform component.

```zig
const Physics = humpty.ecs.Plugin(.three, f32, MyHost);
try Physics.install(&world, gpa, .{ .gravity_mps2 = .init(0, -9.81, 0) });
defer world.runStage(.Deinit) catch {};

_ = try world.spawn(.{ MyTransform{ .scale = .init(10, 1, 10) }, humpty.ecs.Collider{} });
_ = try world.spawn(.{ MyTransform{ .position = .init(0, 3, 0) }, humpty.ecs.Collider{}, humpty.ecs.RigidBody{} });

// Each frame, after your Update systems:
try world.insertResource(MyTime{ .delta_s = frame_s });
try world.runStage(humpty.ecs.PhysicsStage);
```

The plugin knows your engine only through the host type you give it:

```zig
const MyHost = struct {
    pub const Transform = MyTransform;
    pub const Time = MyTime;
    pub fn deltaSeconds(time: *const MyTime) f32 {
        return time.delta_s;
    }
    /// Where `transform` puts `entity` in the world, after any parents.
    pub fn place(world: *clutch.World, entity: clutch.EntityId, transform: MyTransform) humpty.ecs.Place {
        _ = .{ world, entity };
        return .{ .position = transform.position, .rotation = transform.rotation, .scale = transform.scale };
    }
    /// Puts `entity` at a world position and rotation, by changing its own `transform`.
    pub fn setPlace(world: *clutch.World, entity: clutch.EntityId, transform: *MyTransform, position: Vec3, rotation: UnitQuat) void {
        _ = .{ world, entity };
        transform.position = position;
        transform.rotation = rotation;
    }
    // Optional: the triangles of `entity`'s mesh, for mesh and convex-hull colliders.
    // pub fn mesh(world: *clutch.World, entity: clutch.EntityId, gpa: Allocator) !?humpty.ecs.MeshSource
};
```

Components are plain `f32` data whatever the world's dimension and precision, so an editor can
list and save them; in 2D only x and y are read, and bodies turn about z.

| Component | What it is |
| --- | --- |
| `Collider` | `shape` (sizes in metres before the entity's scale), `offset_m`, `restitution`, `friction`, `sensor`, `mesh_from` (another entity whose mesh the mesh shapes take, where it sits; the collider's own when unset) |
| `RigidBody` | `kind`, `mass_kg`, damping, `gravity_scale`, `rotation` |
| `LinearVelocity`, `AngularVelocity` | Read to see how a body moves; set to change it |
| `CollidingEntities` | Kept listing the entities its collider touches |
| `PhysicsSettings` | `gravity_mps2` and `steps_per_second`, read from the first entity that has it |

Editing a component rebuilds that entity's body; moving its transform (or a parent's) moves it.
`CollisionStarted` and `CollisionEnded` events are sent for each pair that begins and stops
touching. `Plugin.Resource` is the running world: `raycast(origin, direction, max_m, filter)`
by entity (`humpty.ecs.RayFilter{ .exclude = entity }`), and `started()` and `ended()` as
entity pairs. `Plugin.drawColliders(world, entities, gpa, sink)` draws colliders from their
components, with no world running, and `Plugin.drawContacts(world, sink)` the last step's
contacts.
