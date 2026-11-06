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

- `clip`: an authored `.clip.zon` that moves the entity, its children, its model's nodes
  and any other entity in the scene, and can set cameras, UI, sprites, sounds and events.
  Make and key one in the [Animation panel](../guides/animate-entities.md).
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
| `start(entity)` | Plays the clips the entity's `Animator` already names from the start, once: how a cutscene set up in a scene begins. |
| `isPlaying(entity, &app.graphics.clips)` | Whether its authored clip is playing and short of its end. |
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

A track of an authored clip names what it acts on with its `target`: empty for the animated
entity, `Arm/Hand` for a descendant, `/bee` or `/garden/gate` for an entity from the top of the
scene, and `model:Head` for a node of its model. Its `property` is one of these:

| Property | Acts on | A key holds |
| --- | --- | --- |
| `position`, `rotation_deg`, `scale` | `Transform`, or a model node | three numbers, blended |
| `morph_weight` | a model's blend shape | a weight, blended |
| `fov_deg` | `Camera` | degrees, blended |
| `visible` | the track's UI `node`, or the whole `UiScreen` or `UiBillboard` | on or off |
| `text` | the track's UI `node` | the text shown |
| `sprite_frame` | `SpriteAnimator`'s first frame | a frame number |
| `sound` | `AudioSource` (added if missing) | a sound, started when the key is passed |
| `event` | the [`animationEvent`](plugin-hooks.md) hook | a name, sent when the key is passed |

The last four change at their keys rather than blending, and do nothing before their first
key. An `Animator`'s **Takes over** field (`takes_over`: `input`, `hud` or `input_and_hud`)
makes its clip a cutscene; see [Cutscenes](../guides/cutscenes.md).

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
    transform.position.y = base_height_m + @sin(phase) * amplitude_m;
    app.world.markChanged(entity, eggy.Transform);
}
```

Call it from `update`. It follows gameplay time and editor Play/pause behavior.
See [Input and gameplay time](../explanation/input-and-time.md),
[Render entities and cameras](../how-to/render-scene.md), and
[feature support](feature-support.md).
