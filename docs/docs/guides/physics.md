---
title: Physics
---

Eggy's physics is [humpty](../reference/humpty.md), built into every project. An entity with a
**Collider** is something others bump into; add a **RigidBody** and the physics world moves it
too, writing where it went back to its **Transform** each frame. It runs while you play or
simulate, never while you edit.

## Make things collide

1. Give the floor a **Collider**. Alone, a collider is static scenery: it never moves.
2. Give a crate a **Collider** and a **RigidBody**, place it above the floor, and press Play.
   It falls, lands and settles.

A collider's **Shape** is one of:

| Shape | Use it for |
| --- | --- |
| `ball` | Balls, and anything round enough. The cheapest. |
| `cuboid` | Crates, walls, floors. Give its half extents. |
| `capsule` | Characters: a cylinder with rounded ends, which slides over bumps. |
| `cylinder`, `cone` | Barrels, posts, traffic cones. 3D only. |
| `half_space` | Endless ground: everything below a plane through the entity. |
| `convex_hull_from_mesh` | The tightest convex shape around the entity's **Mesh**. Good for props that move. |
| `mesh` | The entity's **Mesh** itself, triangle by triangle. Static 3D scenery only, such as terrain. |

Sizes are before the entity's scale, so a scaled entity's collider grows with it. An axis
(a capsule's, a cylinder's) runs along the entity's Y. **Offset** moves the shape away from the
entity's origin, for a character whose origin is at its feet.

**Restitution** is bounce, 0 to 1. **Friction** is grip; 0 slides like ice. Where two meet,
the bouncier one wins and their frictions are combined. A **Sensor** collider pushes nothing but
still reports what it overlaps: a trigger zone.

A collider under a moving parent goes where the parent takes it, so a door's collider can be a
child of the door.

## Bodies

A **RigidBody**'s **Kind** is one of:

- `dynamic`: pushed by gravity, collisions and your code. **Mass** sets how hard it is to push.
- `kinematic`: moved only by your code, setting its **Transform** or **LinearVelocity**, and
  pushes dynamic bodies out of its way. Lifts and moving platforms.
- `static`: never moves, like a collider alone.

**Rotation** `locked` keeps a body upright however it's pushed: use it for characters.
**Gravity scale** multiplies gravity for this body (0 floats). **Linear damping** and **Angular
damping** slow it down over time, like air.

Bodies that come to rest fall asleep and cost nothing until something touches them.

## Move bodies from code

Add **LinearVelocity** (and **AngularVelocity**) to a body to read and set its speed, in metres
and radians per second. Setting it is how you throw something, or walk a character into a wall
without passing through:

```zig
if (world.get(player, eggy.physics.LinearVelocity)) |body| {
    // Walk on the ground, and keep falling as gravity says.
    body.value = .init(walk.x, body.value.y, walk.z);
}
```

Setting a body's **Transform** teleports it.

To jump, set the upward speed while something is underneath. The speed that rises `h` metres
under gravity `g` is `@sqrt(2 * g * h)`:

```zig
const feet_below_m = 1.0; // the bottom of the collider, from the entity
const ground = eggy.physics.raycast(world, position, .init(0, -1, 0), feet_below_m + 0.1, .{ .exclude = player, .sensors = .skip });
if (jump_pressed and ground != null) body.value.y = @sqrt(2 * 9.81 * 1.2);
```

A ray that starts inside a collider meets it straight away, so `.exclude` leaves out the one
casting.

## What touched what

Add **CollidingEntities** to an entity and physics keeps it listing what its collider touches,
up to eight at once:

```zig
const touching = world.get(coin, eggy.physics.CollidingEntities).?;
for (touching.entities) |other| if (other) |entity| {
    if (entity.eql(player)) collect(coin);
};
```

For every pair that starts or stops touching, physics also sends a `CollisionStarted` or
`CollisionEnded` event. They last until the end of the frame, so read them from a system in
`PostUpdate`:

```zig
var started = world.eventReader(eggy.physics.CollisionStarted);
while (started.next()) |hit| std.log.info("{d} hit {d}", .{ hit.a.id, hit.b.id });
```

`eggy.physics.raycast(world, origin, direction, max_distance_m, filter)` finds the nearest
entity along a ray, with where it was hit, the surface's normal and how far away.

## The scene's physics

A scene's physics runs in the space of the tab it was made in: a scene made from a 2D tab is
2D, using X and Y and turning about Z, and leaves out cylinders, cones and meshes. Select the
scene at the top of the Hierarchy to see its **PhysicsSettings**: **Gravity**, and **Steps per
second**, where more steps cost more and keep fast things from passing through thin walls.

**Edit > Settings > Physics** (or the link in that card) sets the project's precision. Single (`f32`) is right for most
games. Double (`f64`) keeps a world many kilometres across steady, at some speed.

## See the colliders

Select an entity in the editor and its colliders are drawn as wireframes over the Scene panel,
updating as you edit them. Grey is static, green dynamic, purple kinematic, blue asleep and
yellow a sensor.

While playing, open the console with the backquote key and type `physics debug on` to draw
every collider, and the points where they touch in red; `physics debug off` stops it, and
`physics` alone shows what's set. From a Buzz script, `physicsDebug(true)` does the same.

To draw them from code, for one frame:

```zig
try eggy.physics.drawColliders(&app.world, gpa, &.{entity}, &app.debug_draw);
```

## What's not there yet

- Joints, such as hinges and ropes, and character controllers that climb steps.
- Bodies can't pass through each other one way, as on platforms jumped up through.
- A `mesh` collider is never 2D and never moves.
