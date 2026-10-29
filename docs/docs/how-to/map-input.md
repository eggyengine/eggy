---
slug: /guides/input-mappings
sidebar_position: 4
title: Map player controls
---

Give gameplay actions names such as `jump`, `move`, and `look`, bind them to
devices, and read those controls in your game or plugin. You can keep defaults
in an input-map asset or in Zig, then ship project overrides in `controls.zon`.

## Choose where to author bindings

Use an Eggy game or plugin with an `update` hook. To author bindings visually,
open the project in the editor. To work without the editor, use the
[code-defined map](#declare-a-map-in-code) and
[text settings](#edit-and-ship-developer-settings) examples below.

## 1. Create an input-map asset {#create-an-input-map-asset}

In Assets, choose New > Input > Input Map (or right-click a folder and choose the same
submenu). Rename the new file to something like `player.inmap.zon`. Double-click it
to open the Input Map editor.

Add named controls, choose button, axis, or vector, then add their input
bindings. Keys and controller buttons can be captured; scales, dead zones, normalized
movement, and hold/tap/chord triggers each have their own controls.
Apply each binding or trigger edit, then press Save file. Set map priority, startup
activation, and consumption here too if the map needs them.

Use separate `.inmap.zon` files for contexts such as player movement and menus.
Each file owns its defaults. Editing one does not modify the running game; saved
defaults load on the next Play or game reload.

For the asset example below, save `resources/input/player.inmap.zon` with a
`jump` button and a `move` vector. Bind `jump` to Space and the controller's south
button, and `move` to WASD and the left stick. Create
`resources/input/menu.inmap.zon` with `accept` and `back` buttons too.

Saved changes support Undo/Redo. Closing an unsaved map asks whether to save or
discard it. Revert reads the file again, and Save refuses to overwrite changes
made outside the editor.

## 2. Register the map and read its controls {#use-asset-maps-in-a-game-or-plugin}

Declare a typed reference and list it in `input_maps`. The bindings live in the
asset. This example registers both a player map and a menu map; create both files
if you use it:

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
then [enable it when the menu opens](#contexts-and-priority).

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

### Use code-defined defaults instead {#declare-a-map-in-code}

Use `eggy.input.Map` when you want to keep the defaults in Zig:

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

Eggy registers enabled plugins' maps before `init`. The stable settings owner is
the published plugin key plus the map key:
`game/player` for this example. Keep both the map key and control enum tags stable when
you want existing project edits to survive a rename of the Zig type.

Read buttons with `pressed`, `held`, `released`, or `button`; scalars with `axis`; vectors
with `vector` (`eggy.math.Vec2`, with `.x`/`.y`). Reading the wrong kind returns
`WrongControlKind`; a map not registered with this host returns `UnknownControl`.
Borrow the map view inside a hook instead of retaining an App/input pointer across reload.

## 3. Choose sources and modifiers {#sources-and-modifiers}

| Kind | Sources |
| --- | --- |
| Button | `key`, `mouse`, `controller` button |
| Axis | `key_axis` (negative/positive keys), `controller_axis`, `mouse_wheel` |
| Vector | `keys_2d`, `controller_stick`, `mouse_delta` |

Mapped vectors use right/down-positive axes. Raw `Input.direction` uses right/up
positive, so check the sign when changing an existing movement implementation.
`keys_2d` defaults to WASD and normalizes diagonals; set `normalize = false` to
keep independent digital axes.

Set a controller stick's radial `dead_zone` to ignore small movements (default
0.15). Controller axes use a scalar dead zone. Dead zones must be finite and in
`[0, 1)`; scales must be finite. Use a negative scale to invert an axis.
Mouse movement is logical points per frame: do not multiply it by delta time.
See [source resolution](../explanation/input-and-time.md#mapped-source-resolution)
for how multiple bindings combine and dead zones rescale the remaining range.

Controller bindings select any connected device by default. A `device` ID can target one
controller for a session-only setup; project-persisted bindings reject these transient IDs.
Read touch contacts through the [direct snapshot API](../how-to/read-input.md#controllers-touch-and-rebinding);
they cannot be used as map bindings.

## 4. Switch input contexts {#contexts-and-priority}

A map has `priority` (default 0), `enabled` (true), and `consume` (true) defaults.
You can declare a menu map with a higher priority and `enabled = false`, then switch it:

```zig
try app.input.map(MenuInput).setEnabled(menu_open);
try app.input.map(PlayerInput).setPriority(0);
```

These setters change temporary gameplay state without writing developer settings.
Higher enabled consuming maps reserve overlapping physical sources.
Equal-priority maps share input; set `consume = false` to let lower maps read
the same sources. Priority affects mapped controls only; raw polling and event
hooks remain unaffected.

Release a held button before testing a newly enabled or rebound control. These
changes do not manufacture a press. Configuration reload and Undo restore
startup defaults and cancel trigger progress.
[Map activation](../explanation/input-and-time.md#map-activation-and-gestures)
explains how consumption and button edges interact.

## 5. Set button triggers {#triggers}

| Trigger | Behavior |
| --- | --- |
| `.immediate` | Press on down, held while down, release on up |
| `.{ .hold = seconds }` | Press once after the threshold; held until released |
| `.{ .tap = seconds }` | Press/release pulse on up within the threshold; never held |
| `.{ .chord = "control" }` | Active only while the named button in the same map is held |

A chord can also use a tap control's one-frame pulse. Use button controls for
triggers and chord targets. Hold/tap durations must be finite and nonnegative;
the threshold is inclusive. Invalid references and cycles are rejected.

Hold/tap timing uses counted unscaled gameplay seconds, so time scaling does not
change a gesture. Editor pause stops its timing, and the frame clamp still
applies. UI capture cancels it without producing a release or tap. See
[input and gameplay time](../explanation/input-and-time.md#map-activation-and-gestures)
for the timing and cancellation rules.

## 6. Save and ship project overrides {#edit-and-ship-developer-settings}

Project overrides live in `controls.zon` at the project root. They take precedence
over `.inmap.zon` and code defaults and do not rewrite the asset. To change a map's
defaults instead, edit its asset in the Input Map editor.

Keep the project-root `controls.zon` in version control. It stores developer
configuration. Use separate storage for player preferences or saved games.
The runtime embeds it at build time; rebuild the runtime to ship binding changes.
Placing a changed file beside an already-built executable does not rebind it.

With no `controls.zon`, the asset/code defaults apply. Editor refocus rereads the
file; malformed external edits are reported and leave the last working
configuration active.

Write the file by hand:

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

## Check the bindings

Connect the named controls to your gameplay actions, then enter Play. With the
sample defaults, Space and the controller's south button should activate the same
jump action. WASD and the left stick should both drive `move`.

Change the jump binding in `controls.zon`, refocus the editor, and check the action
with the new binding. Rebuild and run the runtime to verify that the project
override ships. If an asset edit appears to have no effect, check for an override
in `controls.zon` and start a new Play session or reload the game to load saved
asset defaults.

To inspect the active bindings in code, use
`player.getBindings(.jump, buffer)` to copy into caller storage without allocating.
For a complete caller-owned slice, supply an allocator:

```zig
const bindings = try player.getBindingsAlloc(gpa, .jump);
defer gpa.free(bindings);
```

For controls registered directly with `registerControls`, use
`app.input.getBindingsAlloc(gpa, Controls.jump)`. Both allocating variants include
overrides, return an empty slice for an unbound control, and propagate allocation
or unknown-control errors.

## Mapping reference and related tasks

- [Game and plugin hooks](../reference/plugin-hooks.md#hooks) covers the optional `input_maps` declaration.
- [Project configuration](../reference/project-configuration.md) covers project settings files.
- [Input and gameplay time](../explanation/input-and-time.md) explains physical input, routing, and gesture timing.
- [Read player input](../how-to/read-input.md) covers direct device snapshots.
