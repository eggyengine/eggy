---
sidebar_position: 6
title: Input and time
---

# Input and time

Read `app.input` and `app.time` in game/plugin hooks. The host updates both; game code
does not poll SDL or advance the frame clock itself.

## Buttons, axes, and directions

```zig
if (app.input.pressed(.space)) jump();
if (app.input.held(.left_shift)) sprint();
if (app.input.released(.space)) finishJump();

const sideways = app.input.axis(.a, .d);
const across, const ahead = app.input.direction(.{});
```

`pressed` means a transition this frame, not a repeated key-down event. `held` survives
frames; `released` lasts one frame. Pressing both sides of an axis gives zero.
`direction(.{})` reads A/D horizontally and S/W vertically. Supply `DirectionKeys`
to choose other physical keys.

Directions are two independent axes, not normalized vectors. If diagonal movement should
be no faster, normalize it yourself using `eggy.math` or divide by its nonzero length.

Keys name physical positions: `.w` means the W position on a US layout. Use text-input
widgets for typed text rather than converting physical keys into characters.

## Mouse input

`mouseHeld`, `mousePressed`, and `mouseReleased` take `.left`, `.middle`, `.right`,
`.x1`, or `.x2`. `mouse_position` is in logical window points, from the top-left;
game input in the editor uses Scene-viewport-local points.

`mouse_delta` accumulates movement during a frame, with right/down positive.
`wheel` accumulates vertical wheel notches, away from you positive.
Multiply movement by the appropriate sensitivity, not by the physical pixel scale.

```zig
if (app.input.mouseHeld(.right)) {
    transform.rotation_deg[1] -= app.input.mouse_delta[0] * sensitivity_deg_per_point;
}
```

Losing window focus releases held input. When UI takes ownership, gameplay input is
cancelled without synthesizing release actions. A UI-consumed event does not also reach
the game's `event` hook. See [Game UI](game-ui.md) for custom consumers.

## Frame-independent movement

```zig
const step_m = speed_m_per_s * app.time.delta_s;
transform.translate(.{ step_m, 0, 0 });
```

| Field | Meaning |
| --- | --- |
| `delta_s` | Gameplay seconds counted for the last frame; zero on the first frame |
| `elapsed_s` | Sum of counted gameplay deltas, not wall-clock time |
| `frame` | Number of gameplay frames counted |

A long stall counts for at most 0.1 unscaled seconds, before the gameplay multiplier.
`try app.time.setScale(0.5)` makes subsequent counted deltas half as large; zero freezes
the gameplay clock, not the execution of hooks/systems. Negative, NaN, and infinite scales
are rejected. `unscaled_delta_s` and `unscaled_elapsed_s` ignore the multiplier but still
use the frame clamp; they are not wall-clock measurements.

Editor Play starts the gameplay clock afresh; pausing does not update gameplay systems.
UI animation uses its own host-supplied clock.

World systems receive `eggy.ecs.Res(eggy.Input)` and `Res(eggy.Time)`. These are read-only
pointers, so use `input.pressed(.space)` and `time.delta_s` directly. Hook code should use
App's fields instead of assuming a world resource exists before the first update.

## Value timers

```zig
var delay = try app.time.startTimer(0.5);
if (try delay.finished(app.time)) doSomething();
const seconds_left = try delay.remainingSeconds(app.time);
try app.time.cancelTimer(&delay);
```

A timer is a small value you keep in game/component state. It allocates nothing and retains
no callbacks. Query it against the explicit clock; `status` is `.running`, `.finished`, or
`.cancelled`. Cancellation is idempotent, and a cancelled timer does not report `finished`.
Zero duration finishes immediately; negative/non-finite durations return `InvalidDuration`.

Timers use scaled gameplay seconds and stop advancing when that clock stops. The
`timer_support` and `scaling_support` queries are `.available`.
Resetting the world invalidates old timer values with `StaleTimer`. Do not save absolute
timer deadlines in scene files: save a duration/remaining time and start a fresh timer after
loading. See [Timers](timers.md) for a complete example.

## Controllers, touch, and rebinding

SDL3 supplies controller hotplug, button/axis snapshots, rumble, and touch contacts.
The `controller_support`, `touch_support`, and `rebinding_support` queries are `.available`.
Hardware availability is separate: zero connected controllers or contacts is ordinary absence.

```zig
var controllers: [8]eggy.input.Controller = undefined;
for (try app.input.controllers(&controllers)) |controller| {
    const state = try app.input.controllerState(controller);
    if (state.buttons_pressed.contains(.south)) jump();
}
```

Enumeration copies into caller storage; `BufferTooSmall` never silently truncates. Query
`controllerCount` or `touchCount` when sizing your own buffer, or let `controllersAlloc(gpa)`
and `touchesAlloc(gpa)` allocate complete lists:

```zig
const controllers = try app.input.controllersAlloc(gpa);
defer gpa.free(controllers);
for (controllers) |controller| {
    const state = try app.input.controllerState(controller);
    if (state.buttons_pressed.contains(.south)) jump();
}
```

The allocator is required; free each returned slice with the same allocator. Empty lists
are successful results, and allocation failures return `OutOfMemory`. The existing buffer
APIs still allocate nothing. A disconnected controller
returns `ControllerDisconnected`. Controller IDs are session-local, not save-file identities.
Sticks use -1..1 with right/down positive; triggers use 0..1. Raw snapshots have no dead zone.
`rumble(controller, low, high, duration_s)` takes finite strengths in 0..1 and seconds;
unsupported hardware returns `UnsupportedDeviceFeature`. Zero strength/duration stops rumble.

`touches(buffer)` returns stable contact IDs, logical `position_points`/`delta_points`,
pressure, and `.began`, `.stationary`, `.moved`, `.ended`, or `.cancelled` phases.
Ended/cancelled contacts remain until the frame ends, including a down/up between updates.
Editor contacts are Scene-local. The default game UI consumes contacts on its controls;
SDL's synthetic mouse events do not create duplicate gameplay actions.

For gameplay, prefer [Input mappings](input-mappings.md): name controls such as `jump`,
`move`, and `look`, then bind them to keys, mouse, or controllers. Developer edits in
**Edit > Input Mappings** persist in the project's `controls.zon` and ship in the built runtime.

Timers and scaling do not introduce or modify a fixed-step/physics scheduler.
