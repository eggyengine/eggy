---
sidebar_position: 10
title: Audio and animation
---

# Audio and animation

Audio and animation currently expose **contracts only**. Their support queries return
`.not_implemented`; playback, stopping, seeking, gain changes, and blending return
`error.NotImplemented`. No output device, decoder, animation importer, or skinning
backend is created.

## Keep asset references in components

References are useful even before a backend exists:

```zig
pub const CharacterAssets = struct {
    footstep: eggy.AssetRef(.audio) = .init("resources/sounds/step.ogg"),
    model: eggy.AssetRef(.model) = .init("resources/models/character.glb"),
};
```

List the component in your plugin's `components` to edit it in the Inspector. The slots
accept files of the matching kind and scenes store the paths. Setting a slot does not
load or play the resource.

## Audio requests

`app.audio.play(sound, options)` describes a playback request and would return a `Voice`
only after a backend actually starts it. Options describe linear gain, `.once`/`.loop`,
an optional world position in metres, and a bus. Listener placement is explicit rather
than inferred from a global camera.

The remaining contract operations are `pause`, `unpause`, `stop`, `setGain`,
`setBusGain`, and `setListener`. They also fail explicitly today; stopping an unsupported
voice is not a successful no-op. Do not construct fake handles to make a call look successful.

Check `eggy.audio.support` when deciding whether to offer sound controls. Disable
unsupported controls or propagate the failure with context. Do not repeatedly attempt
playback and log the same unsupported error every frame.

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

## Simple motion still works

Game code can animate ordinary component values using frame time without claiming a
skeletal-animation backend exists:

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
See [Input and time](input-and-time.md), [Rendering and transforms](rendering-and-transforms.md),
and the complete [capability support table](developer-api.md#capability-support).
