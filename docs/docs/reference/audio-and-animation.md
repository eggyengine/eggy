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

## Animation

An entity animates through its `Animator` component, which plays up to two clips together,
both `AssetRef(.animation)`:

- `clip`: an authored `.clip.zon` that moves the entity, its children and its model's
  nodes. Make and key one in the [Animation panel](../guides/animate-entities.md).
- `model_clip`: one of a model's own clips (bones, blend shapes or baked frames), which
  only moves that model. A model's clips show under it in Assets.

`app.animation()` drives it from code. An `eggy.animation.Clip` sets either or both:

```zig
const walk = eggy.animation.Clip{ .imported = .init("resources/models/hero.glb/walk") };
const idle = eggy.animation.Clip{ .imported = .init("resources/models/hero.glb/idle") };

try app.animation().play(hero, walk, .{ .repeat = .loop });
// Later, fade to idle over a fifth of a second.
try app.animation().blendTo(hero, idle, 0.2, .{ .repeat = .loop });
```

| Call | What it does |
| --- | --- |
| `play(entity, clip, options)` | Starts `clip` now, adding an `Animator` if the entity has none. The options are `start_s`, `speed` and `repeat` (`once` or `loop`). |
| `blendTo(entity, clip, duration_s, options)` | Fades from what plays to `clip` over `duration_s` seconds. |
| `pause` / `unpause` | Holds the pose, then carries on. |
| `stop` | Goes back to the first pose and holds it. |
| `seek(entity, time_s)` | Jumps to a time in seconds. |
| `setSpeed`, `setRepeat` | Change a playing animation. |

`play` and `blendTo` return `error.InvalidClip` for a clip that sets neither field, and
`error.ModelMismatch` when `clip.model` is set to a model the entity doesn't draw. The others
return `error.NoAnimator` for an entity without one. Animation follows game time, so a
paused game holds its pose. Packaged `.eggmodel`s keep their rigs, so imported clips play in
an exported game too. There are no controller graphs, retargeting or root motion.

## Component motion

Game code can also animate ordinary component values using frame time:

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
[Render entities and cameras](../how-to/render-scene.md), and
[feature support](feature-support.md).
