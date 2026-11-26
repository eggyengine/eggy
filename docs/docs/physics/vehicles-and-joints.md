---
title: Vehicles and joints
sidebar_position: 2
sidebar_label: Vehicles and joints
description: Trucks on suspension, trailers on a hitch, hinged and sliding parts, and bodies built from many colliders.
---

Everything here is 3D. A vehicle is a **RigidBody** with a **Vehicle** on it and a **Wheel** on
each of the entities below it; a trailer hangs off it by a **Joint**. The game only sets a
**VehicleInput** each frame. Raise the scene's **Steps per second** to 120: springs and tyres are
worked out each step, and a vehicle drives better the more often that is.

## Bodies made of many colliders

A **Collider** joins the body of the nearest entity at or above it with a **RigidBody**, so a
truck is one body however many boxes it is built from, and a machine built on a trailer's deck
as a child entity rides along with it. A collider's **Mass** adds that many kilograms where it
sits; left unset, it takes a share of the body's own **Mass** by its size. The body balances
where its colliders' masses do, unless **Center of mass** says where: set it low for a vehicle,
so it doesn't roll over in turns.

A **RigidBody**'s **Kind** can change while playing and keeps where the body is: turn a parked
trailer `static` while building on it, then `dynamic` again to tow it. Turning off
**Enabled** on a **RigidBody** and its **Collider** leaves the entity where its **Transform**
puts it and lets everything pass through it, as for a player who climbs into a cab and is
parented to the seat; turned back on, the body starts again from where the entity is.

## A truck

1. Give the truck's entity a **RigidBody** (3000 kg, its **Center of mass** a little below its
   middle), a **Collider** for its body, and a **Vehicle**. A **VehicleInput** comes with it.
   The truck faces -Z.
2. Add a child entity for each wheel where its suspension is mounted, a little inside the body,
   and give it a **Wheel**. Tick **Steers** on the front wheels, **Driven** on the ones the
   engine turns, and **Handbrake** on the rear ones.
3. Drag each wheel's model from the Hierarchy onto its **Visual**. Physics places it each frame
   where the wheel is, turned by its steering and rolling about its X axis.

The defaults drive a 3000 kg truck; tune from there. **Suspension rest** is the spring's
unloaded length from the mount to the wheel's centre, and **Suspension travel** how far it
squashes or stretches either side. **Stiffness** and the two **Damping**s set how it rides:
stiffer for a heavier vehicle. **Forward friction** and **Side friction** are how hard a tyre
grips along and across itself, as shares of the load on it. Wheels sharing an **Axle** number
with an **Anti roll** stiffness lean less in turns.

Drive it from the game's `update`:

```zig
const input = world.get(truck, eggy.physics.VehicleInput).?;
input.throttle = app.input.axis(.s, .w); // -1 reverses
input.steer = app.input.axis(.a, .d); // positive turns right
input.brake = if (app.input.held(.left_shift)) 1 else 0;
input.handbrake = app.input.held(.space);
```

Add a **VehicleState** to read its speed, and a **WheelState** to a wheel to read whether it is
on the ground, what it stands on, how squashed its spring is, how much it slides and how fast it
spins. Parked with its handbrake on, a vehicle holds still on a slope and falls asleep.

## Joints

A **Joint** on an entity with a **RigidBody** holds it to the entity dragged onto **Other**, at
**Anchor** on this one and **Other anchor** on that one, each in its own entity's space. Left
empty, **Other** is the world, and **Other anchor** a place in it. Add the joint to hitch, and
remove it to unhitch.

| Kind | Holds | Use it for |
| --- | --- | --- |
| `fixed` | Everything | Welding two bodies |
| `ball` | The anchors together; with a **Cone limit**, its **Axis** within that angle of where it started | A trailer's hitch, which can't fold into the cab |
| `hinge` | Turning only about its **Axis**, within **Limits** in degrees | Folding wings, ramps, doors |
| `slider` | Sliding only along its **Axis**, within **Limits** in metres | A deck section that slides out |

A hinge's or slider's **Motor** drives it: `velocity` at a speed, or `position` to a target,
which it holds there under load, never pushing harder than **Max**. Limits and targets count
from where the joint was made, the other body against this one. Set **Break force** and the
joint lets go when pulled harder; add a **JointState** to see whether it broke, where it is and
how hard it holds.

## Every step

Physics runs in fixed steps, several a frame or none. A game or plugin with a `fixedUpdate` hook
runs inside each, before anything moves, for anything that must keep in step with physics, such
as forces of its own:

```zig
pub fn fixedUpdate(self: *Self, app: *eggy.App, step_s: f32) !void {
    const lift_n = self.balloon_volume_m3 * 1.2 * 9.81;
    eggy.physics.applyForce(&app.world, self.balloon, .init(0, lift_n, 0), .center_of_mass);
    _ = step_s;
}
```

A force applied in `update` pushes through every step of that frame; one applied in
`fixedUpdate` pushes through that step. `applyImpulse` pushes once, at once, and `applyTorque`
turns. A **VehicleInput** set in `fixedUpdate` is read that same step. Don't spawn or despawn
entities there.

## Riding on things

A body standing on a moving one keeps its speed by friction, so a crate rides in a truck's bed.
A character controller that sets its own velocity needs the ground's too:

```zig
const riding = if (eggy.physics.groundVelocity(&app.world, player, 50)) |ground| ground.velocity else math.Vec3.zero;
body.value = .init(walk.x + riding.x, body.value.y, walk.z + riding.z);
```

`eggy.physics.shapecast(world, shape, origin, rotation, direction, max_distance_m, filter)`
sweeps a ball, box, capsule, cylinder or cone, as a raycast sweeps a point; `.exclude` leaves
out every collider of that entity's body.

## See it working

In the console, `physics debug vehicles` draws each wheel's cast and spring, the ground it
meets and how hard it pushes, each joint's anchors, axis and limits, each body's centre of mass,
and how hard each contact pushes. Run it again to stop.

`examples/vehicle_sandbox` puts all of this together — a four-wheel truck towing a two-wheel
trailer with a hinged rear ramp and a sliding deck over a heightfield with a ramp, a 15° slope
and bumps. Run it from its folder with `zig build run-runtime`.
