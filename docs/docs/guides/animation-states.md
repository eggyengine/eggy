---
title: Blend animation states
---

An `Animator` mixes imported clips by weight, each on its own clock, with every weight easing toward a target. Drive them from code through `app.animation()`, each frame, on the entity that draws the model.

A clip may come from another model with the same bone names. Animations downloaded from Mixamo without skin import as skeletons with one clip each, named `mixamo.com`, and play on the character they were made for:

```zig
const walk = eggy.AssetRef(.animation).init("resources/models/animations/Walking.fbx/mixamo.com");
```

`blendAlong` is a 1D blend space. Place clips along an axis, such as ground speed, and the two either side of the value share the pose. Every other whole-body state fades out, so calling it each frame on the ground also ends a jump.

```zig
try app.animation().blendAlong(mesh, &.{
    .{ .clip = idle, .at = 0 },
    .{ .clip = walk, .at = 1.7 },
    .{ .clip = run, .at = 3.5 },
}, ground_speed_m_per_s, 0.2, .{ .root_motion = .in_place });
```

`fadeToState` moves to one state alone, such as a jump. Give `start_s` to start the clip there; leave it out on later frames so the clip carries on. `setState` sets one state's weight and leaves the others alone.

```zig
try app.animation().fadeToState(mesh, jump, 0.1, .{ .start_s = 0.45, .repeat = .once, .root_motion = .pinned });
```

A state given a `bone` is a layer: it moves only that bone and those below it, over what the other states make. Drawing a gun on `mixamorig:Spine` leaves the legs walking. `stateEnded` says when a `once` clip has finished, to fade its layer back out:

```zig
if (drew) try app.animation().setState(mesh, draw_gun, 1, 0.2, .{ .start_s = 0, .repeat = .once, .bone = "mixamorig:Spine" });
if (app.animation().stateEnded(mesh, draw_gun, &app.graphics.clips)) try app.animation().setState(mesh, draw_gun, 0, 0.2, .{ .repeat = .once, .bone = "mixamorig:Spine" });
```

`root_motion` decides what a clip does with its hips when the game moves the body itself. `.in_place` takes out a walk's travel and keeps its sway, and `.pinned` holds the hips still, leaving the lift of a jump to physics.

Weights of whole-body states are shared out when they add up to more than 1. Below 1, the `Animator`'s model clip shows through; without one the states share the whole pose, so a T-pose never shows mid-fade. Set the model clip to the idle in the scene and the model stands idle in the editor and on the game's first frame too. An `Animator` holds eight states at once, and a state that fades out to nothing frees its slot.
