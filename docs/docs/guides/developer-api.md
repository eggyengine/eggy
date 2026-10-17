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

## Design references

Eggy's API is its own, built around Zig's ownership and ECS model. The distinction between
input intent and device state is also useful in [Unity's input actions](https://docs.unity3d.com/Packages/com.unity.inputsystem@1.17/manual/Actions.html)
and [Unreal's Enhanced Input](https://dev.epicgames.com/documentation/en-us/unreal-engine/enhanced-input-in-unreal-engine).
Their object hierarchies and naming conventions are not required by Eggy.
