---
sidebar_position: 4
title: Input and gameplay time
---

Eggy's host collects input and advances time before gameplay reads them.
Games and plugins read the current state through `app.input` and `app.time`;
they do not poll SDL or advance the frame clock themselves.

World systems receive read-only `eggy.ecs.Res(eggy.Input)` and `Res(eggy.Time)`
pointers. Hooks use App's fields, because a world resource may not exist before
the first update.

## Physical keys and frame edges

Key names describe physical positions. `.w` means the W position on a US keyboard
layout, regardless of the character a user's layout assigns to that position.
Text-input widgets handle typed text; physical-key state cannot replace text
input.

`pressed` and `released` describe transitions during a gameplay frame. A repeated
key-down event does not produce another `pressed` edge. `held` continues across
frames until the input ends. An edge lasts one gameplay frame, so several systems
can observe the same press without consuming it.

A raw axis subtracts its negative key from its positive key, so holding both
directions gives zero. Raw `Input.direction` gives two independent right/up-positive
axes: A/D horizontally and S/W vertically. It does not normalize diagonals.
Mapped vectors use right/down-positive axes, and the default `keys_2d` binding
normalizes diagonal movement.

## UI routing and cancellation

Gameplay input respects UI ownership. An event consumed by UI does not also
reach the game's `event` hook. When UI takes ownership, Eggy cancels gameplay
input without creating release actions. That prevents an interrupted tap or
release gesture from firing an action after a control takes focus.

Losing window focus releases held input. UI capture is a cancellation, so code
that tracks a multi-frame action should account for that path too. The default
game UI consumes touch contacts on its controls, and SDL's synthetic mouse
events do not create duplicate gameplay actions.

Mouse coordinates are logical window points measured from the top-left. During
editor gameplay, mouse and touch positions are local to the Scene viewport.
Mouse deltas accumulate within a frame, with right/down positive. They describe
distance moved, so multiplying them by delta time would make sensitivity depend
on frame duration. Vertical wheel input accumulates notches, with motion away
from the user positive.

SDL controls such as relative mouse mode affect window or device behavior.
Continuing to read gameplay through `app.input` preserves UI capture and editor
routing.

## Mapped source resolution

A named control can have several bindings. Eggy chooses the greatest magnitude,
so keyboard and controller movement do not add together. Equal magnitudes keep
the first binding/device result. A button bound to several sources releases
only after all of them release.

Controller sticks use a radial dead zone, with a default of 0.15. Controller axes
use a scalar dead zone. The remaining range is rescaled to full travel. Dead
zones must be finite and in `[0, 1)`; scales must be finite. Negative scales
invert an axis.

Raw controller snapshots have no dead zone. Their stick values use -1..1 with
right/down positive, and triggers use 0..1. A map's modifiers apply when resolving
its controls, leaving raw polling available for code that needs the device state.

Controller bindings select any connected device by default. A session-local
device ID can restrict a binding to one controller, but project-persisted
bindings reject those transient IDs. Touch contacts use the direct snapshot API
and cannot be bound to mapped controls.

## Map activation and gestures

Maps default to priority `0`, enabled `true`, and consume `true`. A higher-priority
enabled consuming map reserves overlapping physical sources, even while its
trigger is inactive. Equal-priority maps share input. A map with `consume = false`
allows lower-priority maps to read those sources too.

Priority affects mapped controls; it does not block raw polling or event hooks.
Runtime activation and priority setters change temporary gameplay state without
writing developer settings.

Activation, rebinding, and priority changes do not create button edges. If a
button is already held when a map gains access to it, the user must release it
before a fresh press can activate the control. Project configuration reload and
Undo restore startup defaults and cancel trigger progress.

Immediate button triggers follow down and up edges. A hold trigger presses once
after its threshold and stays held until release. A tap emits a press/release
pulse when released within its threshold and is never held. A chord is active
while its named button in the same map is held; that target can also be a tap's
one-frame pulse.

Chord targets must exist and be button controls. Unknown references, non-button
targets, cycles, and triggers on non-button controls are rejected. Hold and tap
durations must be finite and nonnegative, with inclusive thresholds.

Hold and tap timing uses counted unscaled gameplay seconds. Changing the time
scale does not change the gesture threshold. Editor pause stops gesture
advancement, and the frame clamp still applies. Focus loss releases input; UI
capture cancels a gesture without creating a release or tap action.

## Counted gameplay time

The gameplay clock measures the time counted for simulation:

| Field | Meaning |
| --- | --- |
| `delta_s` | Gameplay seconds counted for the last frame; zero on the first frame |
| `elapsed_s` | Sum of counted gameplay deltas, not wall-clock time |
| `frame` | Number of gameplay frames counted |
| `unscaled_delta_s` | Counted frame seconds before applying the gameplay scale |
| `unscaled_elapsed_s` | Sum of counted frame seconds before applying the scale |

The host caps each unscaled frame step at 0.1 seconds, then applies the gameplay
multiplier. This limits how much simulation time a long stall contributes.
The unscaled fields ignore the multiplier but retain the clamp, so they are
also unsuitable for measuring wall-clock time.

`setScale(0.5)` makes subsequent counted deltas half as large. A scale of zero
freezes the clock without stopping hooks or systems. Scale changes do not
retroactively alter a frame already counted. Negative, NaN, and infinite values
are rejected, leaving the previous scale intact.

Editor Play starts the gameplay clock afresh. Pausing in the editor stops
gameplay systems from updating. UI animation uses its own host-supplied clock.
Neither time scaling nor value timers introduce or modify a fixed-step or
physics scheduler.

## Timer lifetimes

A timer stores a deadline in scaled gameplay seconds. It is a small value kept
in game or component state, queried against an explicit `eggy.Time`. It allocates
nothing and retains no callbacks, so unloading a plugin library cannot leave
a callable timer behind.

Its status is `.running`, `.finished`, or `.cancelled`. A finished timer continues
to report `finished` until the caller replaces or discards it. Cancellation
mutates the value passed by pointer and is idempotent; a cancelled timer does not
report `finished`. Copies are independent values, so cancelling one does not
cancel another.

Zero-duration timers finish immediately. Negative or non-finite durations return
`InvalidDuration`. Remaining time is nonnegative and is zero for finished or
cancelled timers. Timers stop advancing whenever the scaled gameplay clock stops.
They cannot be used as alarms for real-world deadlines.

The clock tags each timer with its generation. A world reset invalidates old
values; querying or cancelling one against the current clock returns
`StaleTimer`. Play resets the gameplay clock, while a world reload can invalidate
timers without rewinding the elapsed time.

Persist a duration or remaining time in a saved game or scene, then start a fresh
timer after loading. An absolute gameplay deadline or clock generation belongs
to the old clock lifetime.

## Apply these rules

- [Read player input](../how-to/read-input.md) for direct keyboard, mouse, controller, and touch queries.
- [Map player controls](../how-to/map-input.md) for named actions, binding assets, and project overrides.
- [Use timers and time scaling](../how-to/timers.md) for cooldowns and scaled movement.
- [Game lifecycle](game-lifecycle.md) for execution and editor Play.
