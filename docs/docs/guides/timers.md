---
sidebar_position: 11
title: Timers
---

# Timers

Timers are ordinary values, queried against `eggy.Time`. They do not allocate or register
callbacks, so moving a plugin or unloading its library cannot leave a callable timer behind.

## Start and observe a timer

```zig
pub const Game = struct {
    cooldown: ?eggy.Timer = null,

    pub fn update(self: *Game, app: *eggy.App) !void {
        if (self.cooldown) |timer| {
            if (!try timer.finished(app.time)) return;
            self.cooldown = null;
        }
        if (app.input.pressed(.space)) {
            try fire(app);
            self.cooldown = try app.time.startTimer(0.5);
        }
    }
};
```

Here `fire` is the game's own operation. The timer observes counted gameplay seconds,
not wall-clock time. `finished` stays true once its deadline is reached, so clear the
optional or start another timer when you consume it.

`timer.status(app.time)` returns `.running`, `.finished`, or `.cancelled`.
`remainingSeconds` returns a nonnegative number, or zero for a finished/cancelled timer.
A zero duration is immediately finished. Negative, NaN, and infinite durations return
`error.InvalidDuration`.

## Cancel explicitly

```zig
if (self.cooldown) |*timer| {
    try app.time.cancelTimer(timer);
}
```

Cancellation mutates the value you pass, which is why it takes a pointer. Copies are
independent values; cancelling one copy does not change another. A cancelled timer does
not report `finished`. There is no cleanup or destructor to call.

## Scale gameplay time

```zig
try app.time.setScale(0.5); // half-speed counted time
try app.time.setScale(0);   // freeze counted time
try app.time.setScale(1);   // normal speed
```

The multiplier applies on subsequent host ticks. It does not retroactively change an
already-counted frame, stop hooks/systems, or introduce a physics scheduler.
Rejecting invalid multipliers leaves the previous scale intact.

Unscaled frame steps are capped at 0.1 seconds before multiplication. A timer follows this
same counted clock, including the clamp, scale, and editor pause. It is not an alarm for
real-world deadlines. UI tools should use their host-supplied UI clock for animation.

## Resets and reloads

The clock tags timers with its current generation. World resets invalidate old timer
values; querying/cancelling one against the current clock returns `error.StaleTimer`.
Play resets the gameplay clock, while a world reload can invalidate timers without
rewinding the clock's elapsed time.

Keep timer values in the plugin's current state. For saved games/scenes, store a duration
or remaining time and start a fresh timer after loading. Do not persist a clock generation
or absolute gameplay deadline.
