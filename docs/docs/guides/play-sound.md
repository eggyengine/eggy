---
title: Play sound and 3D audio
---

Eggy plays WAV, FLAC, MP3 and Ogg Vorbis files. A sound can come from a place in the world,
so it pans left and right and gets quieter with distance from the listener, or it can play
unplaced, like music or a menu click. Put files anywhere in `resources/`. They ship with
the game as they are.

## Listen in the editor

Select a sound in the Assets panel. The Asset Preview shows its waveform, how long it is,
and whether it is mono or stereo. Press **Play** to hear it, **Pause** to hold it, and **Stop**
to end it and go back to the start. Click or drag along the waveform to play from that point.
Turn on **Loop** to hear it repeat.

## Put a sound on an entity

1. Select an entity and add an **AudioSource** component in the Inspector.
2. Drag a sound from Assets onto its **sound** slot.
3. Press Play. The sound starts with the game.

| Field | What it does |
| --- | --- |
| `playing` | The sound plays while this is on. A `once` sound turns it off when it ends. Turn it on again to replay. |
| `repeat` | `once` or `loop`. |
| `gain` | Volume: 1 as recorded, 0 silent. |
| `pitch` | Playback rate: 2 is an octave up and twice as fast. |
| `bus` | Which volume group it belongs to: `music`, `effects`, `dialogue`, `ui` or `master`. |
| `spatial` | On: it sounds from the entity's place. Off: it plays unplaced (use this for music). |
| `min_distance_m` | Within this many metres it plays at full volume. |
| `max_distance_m` | Past this many metres it gets no quieter. |
| `rolloff` | How fast it fades between the two. 0 doesn't fade. |

Placed sounds follow their entity as it moves, including when it's moved by a parent.
Sources only play while the game runs: not while you edit the scene, and they hold
still while the game is paused.

## Choose where the player hears from

Placed sounds are heard from the **listener**. Add an **AudioListener** component to the
entity that should hear, usually the player or the camera. It hears from its position and
faces the way the entity faces (its -z). Without an `AudioListener`, the active camera is
the listener.

## Play sounds from code

`app.audio()` plays a file and returns a `Voice`, which you can then change or stop:

```zig
const jump = eggy.AssetRef(.audio).init("resources/sounds/jump.ogg");
const boom = eggy.AssetRef(.audio).init("resources/sounds/boom.wav");

pub fn update(self: *Game, app: *eggy.App) !void {
    // Unplaced, at half volume.
    if (app.input.pressed(.space)) _ = try app.audio().play(jump, .{ .gain = 0.5 });

    // From a place in the world, fading out by 30 metres.
    if (self.exploded) _ = try app.audio().play(boom, .{
        .position_m = .{ 4, 0, -2 },
        .falloff = .{ .min_distance_m = 2, .max_distance_m = 30 },
    });
}
```

A `.once` voice ends by itself. Keep the `Voice` to control a sound while it plays:

```zig
self.siren = try app.audio().play(siren, .{ .repeat = .loop, .position_m = car_position });
// Every frame, as the car moves:
try app.audio().setPosition(self.siren, car_position);
// Later:
try app.audio().stop(self.siren);
```

| Call | What it does |
| --- | --- |
| `play(sound, options)` | Starts a sound. The options are `gain`, `pitch`, `repeat`, `position_m`, `falloff`, `bus` (`effects` unless you choose another) and `start_s`. |
| `pause(voice)` / `unpause(voice)` | Holds a sound where it is, then lets it go on. |
| `stop(voice)` | Ends a sound. |
| `setGain`, `setPitch`, `setPosition` | Change a playing sound. `setPosition` places an unplaced sound. |
| `position(voice)` / `seek(voice, seconds)` | Where a sound is, in seconds, and moving it. `play` can also start part way in, with `start_s`. |
| `setRepeat(voice, repeat)` | Makes a playing sound loop, or end when it next reaches its end. |
| `isPlaying(voice)` | Whether it's still going. A paused sound counts as playing. |
| `setBusGain(bus, gain)` | Sets one bus's volume, or everything's with `.master`. Use it for volume sliders. |
| `setListener(position, forward, up)` | Places the listener yourself, in scenes with no `AudioListener` and no active camera. |
| `hold(true)` / `hold(false)` | Holds every sound at once, for a pause menu. |

Once a voice ends, calls on it do nothing and `isPlaying` returns false. Every sound stops
when you press Play or Stop, and when the editor reloads your code.

Up to 64 sounds play at once. Past that, `play` returns `error.TooManyVoices`. Fix a file
that won't decode (`error.UnreadableSound`) by exporting it again as WAV or Ogg Vorbis.

If the computer has no audio device, the game still runs. Calls still work, but nothing
can be heard.
