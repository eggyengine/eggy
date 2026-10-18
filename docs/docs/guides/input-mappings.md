---
sidebar_position: 17
title: Input mappings
---

# Input mappings

Name what the player does, then read that intent in game code. Raw key/mouse polling
still works; a map adds device-independent controls, modifiers, and triggers.

## Create an input-map asset

In Assets, choose **New > Input Map** (or right-click a folder and choose the same
submenu). Rename the new file to something like `player.inmap.zon`. Double-click it
to open the Input Map editor.

Add named controls, choose **button**, **axis**, or **vector**, then add their input
bindings. Keys and controller buttons can be captured; scales, dead zones, normalized
movement, and hold/tap/chord triggers use the same controls as Edit > Input Mappings.
Apply each binding or trigger edit, then press **Save file**. Map priority, startup
activation, and consumption are editable too.

You can create as many `.inmap.zon` files as you need: player, menus, vehicles, and so
on. Each file owns its defaults. Editing one does not modify the running game; saved
defaults load on the next Play or game reload. Saved changes support Undo/Redo.
Closing an unsaved map asks whether to save or discard it. Revert reads the file
again, and Save refuses to overwrite changes made outside the editor.

## Use asset maps in a game or plugin

Keep a short typed reference in code; the bindings themselves live in the asset:

```zig
const eggy = @import("eggy");

const PlayerInput = eggy.input.FileMap(enum { jump, move }, .{
    .key = "player",
    .file = "resources/input/player.inmap.zon",
});
const MenuInput = eggy.input.FileMap(enum { accept, back }, .{
    .key = "menu",
    .file = "resources/input/menu.inmap.zon",
});

pub const Game = struct {
    pub const input_maps = .{ PlayerInput, MenuInput };

    pub fn update(_: *@This(), app: *eggy.App) !void {
        const player = app.input.map(PlayerInput);
        if (try player.pressed(.jump)) {
            // Start a jump.
        }
        const movement = try player.vector(.move);
        _ = movement;
    }
};
```

Paths are project-relative and include `resources/`. The enum must name exactly
the controls in that file; their order does not matter. When adding or renaming a
control in the editor, update this enum too. A mismatch reports the map and file
instead of registering a partially working map.

Games and plugins both list maps in `input_maps`. Asset maps and code-defined maps
can coexist in that tuple. Distinct `.key` values give maps separate identities,
even if they use the same asset. Files under `resources/` are packaged automatically.
For a menu context, give its map a higher priority and disable startup activation,
then enable it when the menu opens, as described below.

The files are ordinary ZON and can also be edited as text:

```zig
.{
    .version = 1,
    .controls = .{
        .{ .name = "jump", .bindings = .{
            .{ .key = .space },
            .{ .controller = .{ .button = .south } },
        } },
        .{ .name = "move", .kind = .vector, .bindings = .{
            .{ .keys_2d = .{} },
            .{ .controller_stick = .{} },
        } },
    },
}
```

## Declare a map in code

The original `eggy.input.Map` API remains available when keeping defaults in Zig is
more convenient:

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

`player.getBindings(.jump, buffer)` copies bindings into your buffer without allocating.
Use `player.getBindingsAlloc(gpa, .jump)` for a complete caller-owned slice:

```zig
const bindings = try player.getBindingsAlloc(gpa, .jump);
defer gpa.free(bindings);
```

For controls registered directly with `registerControls`, the equivalent is
`app.input.getBindingsAlloc(gpa, Controls.jump)`. Both variants copy the current bindings,
including overrides, return an empty slice for an unbound control, and propagate allocation
or unknown-control errors.

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

A map has `priority` (default 0), `enabled` (true), and `consume` (true) defaults.
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
Reset restores the registered map's defaults, from its asset or code. These project
overrides take precedence over `.inmap.zon` defaults and do not rewrite the asset.
Edits participate in the editor's undo/redo history.

The project-root `controls.zon` belongs in version control. It is developer-authored
configuration, **not player preferences or saved-game storage**. The runtime embeds it at
build time; shipping a changed file beside an already-built executable does not rebind it.
An absent file means the map's asset/code defaults. Editor refocus rereads it; malformed external edits are
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
