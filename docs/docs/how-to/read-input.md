---
slug: /guides/input-and-time
sidebar_position: 3
title: Read player input
---

Read keyboard, mouse, controller, or touch state from `app.input` in a game or
plugin. For configurable actions such as jump or move,
[map player controls](../how-to/map-input.md) instead of binding gameplay directly
to physical devices.

## Prepare an update hook

Use an existing game or plugin with an `update` hook. The snippets below belong
inside a hook with access to `app: *eggy.App`; operations such as `jump()` are
your game's own functions. The host updates input and time, so do not poll SDL
or advance the frame clock yourself.

## 1. Read buttons and movement keys {#buttons-axes-and-directions}

```zig
if (app.input.pressed(.space)) jump();
if (app.input.held(.left_shift)) sprint();
if (app.input.released(.space)) finishJump();

const sideways = app.input.axis(.a, .d);
const across, const ahead = app.input.direction(.{});
```

Use `pressed` for a one-frame action, `held` for an action that continues while a
key is down, and `released` for its one-frame release. Key repeat does not create
another press.

`axis(.a, .d)` returns a negative value for A and a positive value for D. Pressing
both gives zero. `direction(.{})` reads A/D horizontally and S/W vertically.
Supply `DirectionKeys` to choose other physical keys.

Raw directions have independent axes. Normalize with `eggy.math` or divide by the
nonzero length if diagonal movement should have the same speed as movement along
one axis.

Keys name physical positions; `.w` is the W position on a US layout. Use text-input
widgets for typed text. See [input semantics](../explanation/input-and-time.md#physical-keys-and-frame-edges)
for frame edges and keyboard layouts.

## 2. Read the mouse {#mouse-input}

`mouseHeld`, `mousePressed`, and `mouseReleased` take `.left`, `.middle`, `.right`,
`.x1`, or `.x2`. `mouse_position` is in logical window points, from the top-left;
game input in the editor uses Scene-viewport-local points.

`mouse_delta` accumulates movement during a frame, with right/down positive.
`wheel` accumulates vertical wheel notches, away from you positive.
Multiply movement by the appropriate sensitivity. Do not multiply it by delta
time or the physical pixel scale.

```zig
if (app.input.mouseHeld(.right)) {
    transform.rotation_deg[1] -= app.input.mouse_delta[0] * sensitivity_deg_per_point;
}
```

Losing window focus releases held input. UI capture cancels gameplay input without
creating release actions. Account for cancellation when an action spans frames.
[UI routing](../explanation/input-and-time.md#ui-routing-and-cancellation) explains
this behavior; [game UI](../how-to/game-ui.md) covers custom consumers.

### SDL mouse and window control

Use `eggy.sdl_adapter.sdl` for relative mouse mode, cursor visibility, capture and grabs.
The [SDL3 mouse and windows guide](../how-to/sdl3.md) explains the differences, release/cleanup,
backend limits and examples. SDL controls window/device behavior; continue reading
gameplay input through `app.input` so UI capture and editor routing remain respected.

## 3. Read controllers and touch contacts {#controllers-touch-and-rebinding}

SDL3 supplies controller hotplug, button/axis snapshots, rumble, and touch contacts.
The `controller_support`, `touch_support`, and `rebinding_support` queries are `.available`.
An empty device or contact list is a successful result. Connect a controller before
trying the controller examples:

```zig
var controllers: [8]eggy.input.Controller = undefined;
for (try app.input.controllers(&controllers)) |controller| {
    const state = try app.input.controllerState(controller);
    if (state.buttons_pressed.contains(.south)) jump();
}
```

Enumeration copies into caller storage and returns `BufferTooSmall` if it will not
fit. Query `controllerCount` or `touchCount` to size your buffer. To allocate a
complete list, use `controllersAlloc(gpa)` or `touchesAlloc(gpa)` with an allocator
available in your code:

```zig
const controllers = try app.input.controllersAlloc(gpa);
defer gpa.free(controllers);
for (controllers) |controller| {
    const state = try app.input.controllerState(controller);
    if (state.buttons_pressed.contains(.south)) jump();
}
```

Free each returned slice with the same allocator. Allocation failures return
`OutOfMemory`; the buffer APIs allocate nothing. Handle `ControllerDisconnected`
if a device disappears, and do not save session-local controller IDs in save files.
Sticks use -1..1 with right/down positive; triggers use 0..1. Raw snapshots have
no dead zone.

For vibration, call `rumble(controller, low, high, duration_s)` with finite strengths
in 0..1 and a duration in seconds. Unsupported hardware returns
`UnsupportedDeviceFeature`. Zero strength or duration stops rumble.

`touches(buffer)` returns stable contact IDs, logical `position_points`/`delta_points`,
pressure, and `.began`, `.stationary`, `.moved`, `.ended`, or `.cancelled` phases.
Ended/cancelled contacts remain until the frame ends, including a down/up between updates.
Editor contacts are Scene-local. The default game UI consumes contacts on its
controls, and SDL's synthetic mouse events do not create duplicate gameplay actions.

## Check input in the game

Run the runtime or enter Play in the editor. With the first snippet connected to
your game's actions, tapping Space should call `jump()` once and `finishJump()`
on release. Holding Space should not create repeated presses. Hold Shift to
check the continuous action.

For mouse turning, hold the right button over the game view and move the mouse.
In the editor, test over Scene rather than an editor panel. For controllers, a
south-button press should take the same jump path in the controller example.
An empty controller list without a connected device is expected.

## Use frame time for movement {#frame-independent-movement}

Multiply a movement speed by `app.time.delta_s` so it stays in units per second.
[Use timers and time scaling](../how-to/timers.md#scale-gameplay-time)
shows the movement calculation and clock controls.

World systems receive read-only `eggy.ecs.Res(eggy.Input)` and `Res(eggy.Time)`
pointers, so use `input.pressed(.space)` and `time.delta_s` directly. In hooks,
use App's fields: a world resource may not exist before the first update.

## Add delayed actions {#value-timers}

Keep a value timer in game or component state for delays and cooldowns.
[Use timers and time scaling](../how-to/timers.md) covers starting, querying, and
cancelling them, including what to do after a world reset.

## Input reference and related tasks

- [Game and plugin hooks](../reference/plugin-hooks.md#hooks) lists hook signatures.
- [Feature support](../reference/feature-support.md) covers capability queries.
- [Input and gameplay time](../explanation/input-and-time.md) explains routing and counted time.
- [Map player controls](../how-to/map-input.md) adds named controls and bindings saved in `controls.zon`.
