---
slug: /guides/timers
sidebar_position: 6
title: Use timers and time scaling
---

Add a cooldown or delay with `eggy.Timer`, and change how quickly gameplay time
advances with `app.time.setScale`. Timers use counted gameplay time, so they
follow time scaling and editor pause.

## Choose the action to delay

Use an existing game or plugin that imports `eggy` and has an `update` hook.
The cooldown example calls `fire(app)`, which is your game's own operation.
Keep the timer in the game or component state that owns the delayed action.

## 1. Start a cooldown {#start-and-observe-a-timer}

Store an optional timer, check it before allowing the action, and start a new
timer after the action succeeds:

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

`finished` stays true once the deadline is reached. Clear the optional or start
another timer when you consume it, as this example does.

## 2. Inspect or cancel a delay

For a delay that does not block the rest of `update`, query the value where you
need it. These are the operations available on a timer:

```zig
var delay = try app.time.startTimer(0.5);
if (try delay.finished(app.time)) doSomething();
const seconds_left = try delay.remainingSeconds(app.time);
try app.time.cancelTimer(&delay);
```

Retain `delay` in state between frames if it must outlive the current hook call.
`doSomething()` is your own action.

`timer.status(app.time)` returns `.running`, `.finished`, or `.cancelled`.
`remainingSeconds` returns a nonnegative number, or zero for a finished/cancelled timer.
A zero duration is immediately finished. Negative, NaN, and infinite durations return
`error.InvalidDuration`.

### Cancel a stored timer {#cancel-explicitly}

```zig
if (self.cooldown) |*timer| {
    try app.time.cancelTimer(timer);
}
```

Cancellation mutates the value you pass, so it takes a pointer. Repeated cancellation
is safe. A cancelled timer does not report `finished`. There is no cleanup or
destructor to call. Timers allocate nothing and retain no callbacks. Cancelling
one copy leaves other copies unchanged.

## 3. Scale movement and timers {#scale-gameplay-time}

Use `app.time.delta_s` for movement that should follow the gameplay clock:

```zig
const step_m = speed_m_per_s * app.time.delta_s;
transform.translate(.init(step_m, 0, 0));
```

Here `transform` is the object's transform and `speed_m_per_s` is its speed.
Change the scale when gameplay needs to slow down, freeze, or resume:

```zig
try app.time.setScale(0.5); // half-speed counted time
try app.time.setScale(0);   // freeze counted time
try app.time.setScale(1);   // normal speed
```

The multiplier applies on subsequent host ticks. It does not change an
already-counted frame or stop hooks and systems. Negative, NaN, and infinite
multipliers are rejected, leaving the previous scale intact.

Unscaled frame steps are capped at 0.1 seconds before multiplication. A timer follows this
same counted clock, including the clamp, scale, and editor pause. Use a different
clock for real-world deadlines. UI tools should use their host-supplied UI clock
for animation.

## 4. Restart timers after resets {#resets-and-reloads}

World resets invalidate old timer values. Querying or cancelling one against the
current clock returns `error.StaleTimer`. Keep timers in the plugin's current
state so they can be started again after reset.

For saved games and scenes, store a duration or remaining time and start a fresh
timer after loading. Do not persist a clock generation or absolute gameplay
deadline. [Clock lifetimes](../explanation/input-and-time.md#timer-lifetimes)
explains how Play and world reload affect timers.

## Check the cooldown and scale

Run the game and press Space to fire. Pressing it again before 0.5 counted gameplay
seconds have passed should not call `fire` again. After that interval, a new
press should fire.

With scale `0.5`, movement driven by `delta_s` and the cooldown should advance at
half speed. At scale `0`, those timers and movements should stop advancing,
although hooks still run. Restore scale `1` to resume. To check cancellation,
cancel a stored timer and confirm that `finished` remains false.

## Clock behavior and support

- [Input and gameplay time](../explanation/input-and-time.md#counted-gameplay-time) explains the clock fields, frame clamp, and pause behavior.
- [Game lifecycle](../explanation/game-lifecycle.md) covers when gameplay runs.
- [Feature support](../reference/feature-support.md) covers `timer_support` and `scaling_support`, both `.available`.

Timers and scaling do not introduce or modify a fixed-step or physics scheduler.
