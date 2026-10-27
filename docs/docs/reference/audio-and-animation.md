---
slug: /guides/audio-and-animation
sidebar_position: 5
title: Audio and animation contracts
---

# Audio and animation contracts

Sound plays through miniaudio: see [Play sound and 3D audio](../guides/play-sound.md) for the
`AudioSource` and `AudioListener` components and `app.audio()`.

## Asset references

```zig
pub const CharacterAssets = struct {
    footstep: eggy.AssetRef(.audio) = .init("resources/sounds/step.ogg"),
    model: eggy.AssetRef(.model) = .init("resources/models/character.glb"),
};
```

List the component in your plugin's `components` to edit it in the Inspector. The slots
accept files of the matching kind and scenes store the paths. Setting a slot does not
load the resource: `app.audio().play(footstep, .{})` reads the sound the first time it plays.

## Animation requests

An `eggy.animation.Clip` names a model and a clip within it:

```zig
const run = eggy.animation.Clip{
    .model = .init("resources/models/character.glb"),
    .name = "run",
};
```

The name is borrowed for a request. `app.animation.play(entity, run, options)` describes
the target, speed, repeat mode, and start time in seconds. `blendTo` supplies a transition
duration in seconds; `seek` supplies a time, not an undocumented normalized fraction.
`pause` and `stop` complete the small playback contract.

These requests do not change an entity's pose today. Packaged `.eggmodel` data currently
contains static geometry, parts, and textures, not skeletons or animation clips.
No controller graphs, retargeting, root motion, or physics integration is implied.
Check `eggy.animation.support` rather than assuming a model file enables animation.

## Component motion

Game code can animate ordinary component values using frame time:

```zig
pub fn bob(
    app: *eggy.App,
    entity: eggy.ecs.EntityId,
    base_height_m: f32,
    amplitude_m: f32,
) !void {
    if (!app.world.isAlive(entity)) return error.InvalidEntity;
    const transform = app.world.get(entity, eggy.Transform) orelse return error.NoTransform;
    const phase: f32 = @floatCast(app.time.elapsed_s);
    transform.position[1] = base_height_m + @sin(phase) * amplitude_m;
    app.world.markChanged(entity, eggy.Transform);
}
```

Call it from `update`. It follows gameplay time and editor Play/pause behavior.
See [Input and gameplay time](../explanation/input-and-time.md),
[Render entities and cameras](../how-to/render-scene.md), and the
[capability support table](feature-support.md#capability-support).
