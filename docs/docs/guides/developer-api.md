---
sidebar_position: 3
title: Developer API
---

# Developer API

Eggy uses ordinary Zig values, explicit context, and error unions. The game and its plugins
receive the same `*eggy.App`; there is no global current world or player. Types use
`PascalCase`, functions use `camelCase`, and fields use `snake_case`. Units appear in names
such as `delta_s`, `rotation_deg`, and `mouse_position`.

## Work with the world

`app.world` is the native `eggy.ecs.World`. Use its queries, resources, events, and schedules
directly. Components are data, not classes with a hidden lifecycle. A component pointer
is borrowed from its storage: do not keep it across structural changes or an editor reload.
After editing a component through `world.get`, call `world.markChanged(entity, Component)`
when systems need to observe the change.

An `EntityRef(T)` checks both the entity's generation and its required component:

```zig
const target = orbit.around.get(&app.world) orelse return;
target.position[1] += app.time.delta_s;
app.world.markChanged(orbit.around.entity.?, eggy.Transform);
```

Here `around` is an `eggy.EntityRef(eggy.Transform)`. `EntityRef(void).get` instead returns
a live entity ID. An unset, deleted, or incompatible target resolves to `null`.

## Read input and time

```zig
const movement = app.input.direction(.{}); // A/D, S/W; each axis is -1, 0 or 1
const arrows = app.input.direction(.{
    .left = .left,
    .right = .right,
    .down = .down,
    .up = .up,
});
if (app.input.pressed(.space)) jump();
```

Directions are not normalized: normalize a diagonal when it should have the same speed as
an axis. `held`, `pressed`, `released`, `axis`, and the mouse methods remain available.
Physical keys do not change with the keyboard layout. Gameplay sees frame edges once;
UI capture cancels gameplay state without manufacturing a release action.

Use `app.time.delta_s` for movement and `elapsed_s` for gameplay time. The first delta is
zero and a stalled frame counts for at most 0.1 seconds. Editor UI has its own clock.

## Reference assets

`AssetRef(kind)` holds a project-relative path by value. Its `init` constructor checks a
literal at compile time:

```zig
const sound = eggy.AssetRef(.audio).init("resources/sounds/jump.ogg");
```

Use `try eggy.AssetRef(.audio).parse(path)` for runtime text. It rejects traversal,
absolute paths, backslashes, paths longer than 256 bytes, and files of the wrong kind.
An empty path is an unset reference. Constructing a reference does not load the file or
mean that its kind has a playback/rendering implementation.

## Read resources and instantiate scenes

The executable installs its providers before your plugin's `init`. The editor reads the
project's files; a packaged runtime resolves the same references through its manifest.

```zig
const notes = eggy.AssetRef(.text).init("resources/notes.txt");
const text = try app.resources().read(gpa, notes);
defer gpa.free(text);

var image = try app.resources().loadImage(gpa, texture);
defer image.deinit(gpa);

const root = try app.scenes().instantiate(
    .init("resources/scene/rat.scene.zon"),
    .{ .parent = parent },
);
```

`loadModel` likewise returns caller-owned CPU data, not a borrowed GPU cache entry.
Loading failures return errors; importer diagnostics supply more detail. Web resource
reads are unsupported until a browser resource provider is implemented.

Instantiation creates a scene-instance root and its immediate entities before returning.
The world owns them. Nested instances populate at the normal scene-sync point. Scene
components or fields that no longer exist are logged and skipped, as when opening a
scene in the editor. A failed read or allocation removes entities created by that call.
Borrow service views only for the operation: do not store them across world resets.

## Describe a reversible value

`eggy.Action(T)` contains `before` and `after`. `value(.undo)` and `value(.redo)` select
the state to apply, so both directions can use one application function:

```zig
const change = eggy.Action(f32){ .before = 0.5, .after = 0.8 };
volume = change.value(.redo);
volume = change.value(.undo);
```

This value does not allocate, clone pointers, or own slices. A history owner must copy
borrowed values before their source expires. Do not store live component pointers in history.

## Capability support

The following namespaces expose contracts but have no backend yet. Their `support` value
is `.not_implemented`, and every operation returns `error.NotImplemented`. They allocate
no output devices, threads, sessions, files, fake handles, or successful empty results.

| App service | Requests |
| --- | --- |
| `audio` | play, pause/unpause, stop, voice/bus gain, listener placement |
| `animation` | play, blend, pause, stop, seek a named model clip |
| `draw2d` | sprites and world-space text |
| `materials`, `lighting` | material assignment, light descriptions, render effects |
| `particles` | emission and stopping |
| `network` | connection, listening, messages, polling, disconnection |
| `navigation` | paths and destinations; no physics or collision access |
| `storage` | game-save bytes by slot, separate from preferences |
| `localization` | locale selection and translated-text lookup |
| `debug_draw`, `profiling` | debug primitives, samples, and counters |

For example, `eggy.audio.support` reports support independently of an App. A sound reference
can be stored in a component today, but `try app.audio.play(sound, .{})` returns an error
until playback exists. Animation references do not imply that `.eggmodel` contains a
skeleton or clips. These contracts do not add unsupported components to the Inspector.

Working low-level graphics (`eggy.vit`), UI (`eggy.ui`), math (`eggy.math`), ECS
(`eggy.ecs`), scene formats, and asset formats remain available directly. Controllers,
touch gameplay input, streaming, async resource loading, and advanced timing are not
implemented; keyboard/mouse polling and existing frame time are not placeholders.

## Design references

Eggy's API is its own, built around Zig's ownership and ECS model. The distinction between
input intent and device state is also useful in [Unity's input actions](https://docs.unity3d.com/Packages/com.unity.inputsystem@1.17/manual/Actions.html)
and [Unreal's Enhanced Input](https://dev.epicgames.com/documentation/en-us/unreal-engine/enhanced-input-in-unreal-engine).
Their object hierarchies and naming conventions are not required by Eggy.
