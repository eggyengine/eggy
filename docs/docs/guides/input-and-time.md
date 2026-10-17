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

A long stall counts for at most 0.1 seconds. This prevents a breakpoint or window drag
from producing an enormous movement step. Editor Play starts the gameplay clock afresh;
pausing does not update gameplay systems. UI animation uses its own host-supplied clock.

World systems receive `eggy.ecs.Res(eggy.Input)` and `Res(eggy.Time)`. These are read-only
pointers, so use `input.pressed(.space)` and `time.delta_s` directly. Hook code should use
App's fields instead of assuming a world resource exists before the first update.

## Controllers, touch, rebinding, and timers

These are public contracts, not implemented input backends:

| Contract | Support query |
| --- | --- |
| `controllers`, `controllerState`, `rumble` | `eggy.input.controller_support` |
| `touches` | `eggy.input.touch_support` |
| `rebind` | `eggy.input.rebinding_support` |
| `Time.startTimer`, `cancelTimer` | `eggy.time.timer_support` |
| `Time.setScale` | `eggy.time.scaling_support` |

Each query is `.not_implemented`; each operation returns `error.NotImplemented`.
Controller/touch enumeration does not return an empty successful list. Rebinding accepts
a game-owned enum value and a typed `Binding`, not a string action asset.
No fixed-step or physics scheduler is introduced by these contracts.
