---
sidebar_position: 17
title: Input mappings
---

# Input mappings

Name what the player does, then read that intent in game code. Raw key/mouse polling
still works; a map adds device-independent controls, modifiers, and triggers.

## Declare a map

```zig
const eggy = @import("eggy");

const PlayerInput = eggy.input.Map(enum { jump, move, look, charge, tap, sprint, dash }, .{
    .key = "player",
    .controls = &.{
        .{ .control = .jump, .bindings = &.{
            .{ .key = .space },
            .{ .controller = .{ .button = .south } },
        } },
        .{ .control = .move, .kind = .vector, .bindings = &.{
            .{ .keys_2d = .{} },
            .{ .controller_stick = .{} },
        } },
        .{ .control = .look, .kind = .vector, .bindings = &.{
            .{ .mouse_delta = .{ .scale = .{ 0.2, -0.2 } } },
        } },
        .{ .control = .charge, .trigger = .{ .hold = 0.5 }, .bindings = &.{.{ .key = .r }} },
        .{ .control = .tap, .trigger = .{ .tap = 0.2 }, .bindings = &.{.{ .key = .t }} },
        .{ .control = .sprint, .bindings = &.{.{ .key = .left_shift }} },
        .{ .control = .dash, .trigger = .{ .chord = "sprint" }, .bindings = &.{.{ .key = .f }} },
    },
});

pub const Game = struct {
    pub const input_maps = .{PlayerInput};

    pub fn update(_: *Game, app: *eggy.App) !void {
        const player = app.input.map(PlayerInput);
        if (try player.pressed(.jump)) {
            // Start a jump.
        }
        const move = try player.vector(.move);
        _ = move.x;
        _ = move.y;
    }
};
```

Games and plugins declare `input_maps` identically. Eggy registers enabled plugins' maps
before `init`. The stable settings owner is the published plugin key plus the map key:
`game/player` for this example. Keep both the map key and control enum tags stable when
you want existing project edits to survive a rename of the Zig type.

Read buttons with `pressed`, `held`, `released`, or `button`; scalars with `axis`; vectors
with `vector` (`eggy.math.Vec2`, with `.x`/`.y`). Reading the wrong kind returns
`WrongControlKind`; a map not registered with this host returns `UnknownControl`.
Borrow the map view inside a hook instead of retaining an App/input pointer across reload.

## Sources and modifiers

| Kind | Sources |
| --- | --- |
| Button | `key`, `mouse`, `controller` button |
| Axis | `key_axis` (negative/positive keys), `controller_axis`, `mouse_wheel` |
| Vector | `keys_2d`, `controller_stick`, `mouse_delta` |

Multiple bindings select the greatest magnitude, rather than adding keyboard and controller
movement together. An aggregated button releases only when all its sources release.
Equal magnitudes keep the first binding/device result.

Mapped vectors use **right/down positive**. The older raw `Input.direction` uses right/up
positive. `keys_2d` defaults to WASD and normalizes diagonals; set `normalize = false` to
keep independent digital axes. Controller sticks use a radial `dead_zone` (default 0.15);
controller axes use a scalar one. The remaining range is rescaled to full travel. Dead zones
must be finite and in `[0, 1)`; scales must be finite. Negative scales invert an axis.
Mouse movement is logical points per frame, not a velocity: do not multiply it by delta time.

Controller bindings select any connected device by default. A `device` ID can target one
controller for a session-only setup; project-persisted bindings reject these transient IDs.
Touch contacts remain a direct snapshot API, not a map binding.

## Contexts and priority

A map has `priority` (default 0), `enabled` (true), and `consume` (true) code defaults.
You can declare a menu map with a higher priority and `enabled = false`, then switch it:

```zig
try app.input.map(MenuInput).setEnabled(menu_open);
try app.input.map(PlayerInput).setPriority(0);
```

These setters are temporary gameplay state, not developer settings writes. Higher enabled
consuming maps reserve overlapping physical sources, even when their trigger is not active.
Equal-priority maps share input; `consume = false` lets lower maps read those sources too.
Priority affects mapped controls, not raw polling or event hooks.

Activation, rebinding, and priority changes do not manufacture button edges. A button already
held when a map gains it must be released before a fresh press can activate it.
Project configuration reload/undo restores map startup defaults and cancels trigger progress.

## Triggers

| Trigger | Behavior |
| --- | --- |
| `.immediate` | Press on down, held while down, release on up |
| `.{ .hold = seconds }` | Press once after the threshold; held until released |
| `.{ .tap = seconds }` | Press/release pulse on up within the threshold; never held |
| `.{ .chord = "control" }` | Active only while the named button in the same map is held |

A chord can also use a tap control's one-frame pulse. Unknown references, non-button
targets, cycles, and triggers on non-button controls are rejected. Hold/tap durations must
be finite and nonnegative; the threshold is inclusive.

Hold/tap timing uses counted **unscaled gameplay seconds**. Time scaling does not change
the gesture; editor pause stops advancement, and the ordinary frame clamp still applies.
Focus loss releases input. UI capture cancels it without creating a release/tap action.
Edges last one gameplay frame, so multiple systems can observe the same edge.

## Edit and ship developer settings

Open **Edit > Input Mappings**, select a map/control, and add, capture, edit, or remove a
binding. Keyboard and controller-button capture have an Escape cancel. Scales, dead zones,
normalization, triggers, startup activation, and priority have explicit Save/Reset controls.
Reset restores code defaults. Edits participate in the editor's undo/redo history.

The project-root `controls.zon` belongs in version control. It is developer-authored
configuration, **not player preferences or saved-game storage**. The runtime embeds it at
build time; shipping a changed file beside an already-built executable does not rebind it.
An absent file means code defaults. Editor refocus rereads it; malformed external edits are
reported and leave the last working configuration active.

You can author the same file without the editor:

```zig
.{
    .version = 1,
    .maps = .{
        .{ .owner = "game/player", .priority = 2, .enabled = true },
    },
    .controls = .{
        .{
            .owner = "game/player",
            .name = "jump",
            .bindings = .{ .{ .key = .j }, .{ .controller = .{ .button = .south } } },
            .trigger = .immediate,
        },
    },
}
```

Overrides for unloaded plugins remain in the file for later registration. Unknown controls
do not invent runtime controls. Incompatible kinds/trigger graphs fail when that map registers.

Code can also call `player.rebind(.jump, binding)`, `setBindings`, `setTrigger`, and
`resetBindings`. In a project editor these save through the host; in a runtime, changes
are session-only. A failed save leaves the active mappings unchanged. With no project
open, the editor explicitly labels its changes session-only.
