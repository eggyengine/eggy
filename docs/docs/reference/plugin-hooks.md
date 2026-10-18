---
sidebar_position: 1
title: Plugin hooks and declarations
---

# Plugin hooks and declarations

`Game` and `Plugin` have the same interface. Eggy finds public declarations by name
with `@hasDecl`; omit any hook you do not need. Declare them inside `pub const Game`
in `src/main.zig`, or `pub const Plugin` in `src/root.zig`.

## Hooks

`Self` means the enclosing type. This is a signature reference; replace `{ ... }`
with an implementation:

```zig
const std = @import("std");
const eggy = @import("eggy");

pub const Plugin = struct {
    const Self = @This();

    frames: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Self { ... }
    pub fn deinit(self: *Self) void { ... }
    pub fn event(self: *Self, app: *eggy.App, event: eggy.Event) !void { ... }
    pub fn update(self: *Self, app: *eggy.App) !void { ... }
    pub fn gameUi(self: *Self, app: *eggy.App, ui: *eggy.ui.Context) !void { ... }
    pub fn draw(self: *Self, app: *eggy.App, target: eggy.DrawContext) !void { ... }
    pub fn uiEvent(self: *Self, app: *eggy.App, event: eggy.Event) !bool { ... }
    pub fn editorUpdate(self: *Self, editor: *eggy.editor.Context) !void { ... }
    pub fn editorUi(self: *Self, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void { ... }

    pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .key = "stats", .title = "Stats" }};
    pub fn editorPanelUi(self: *Self, panel: usize, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void { ... }
    pub const editor_commands = [_]eggy.plugins.EditorCommand{.{ .key = "reset", .title = "Reset" }};
    pub fn editorCommand(self: *Self, command: usize, editor: *eggy.editor.Context) !void { ... }
};
```

| Hook | When it runs |
| --- | --- |
| `init` | After scene loading, preference registration, and input-map registration. Returns the instance. Without it, Eggy uses `.{}`, so fields need defaults. Register ECS systems and acquire owned resources here. |
| `deinit` | Before a started instance is discarded, including shutdown, restarts, and reloads. Release the instance's resources; Eggy owns the App and world. |
| `event` | Gameplay input not consumed by UI, plus platform/window events. In the editor, only while playing and not paused. |
| `update` | Each running frame, before ECS Update systems and rendering. In the editor, only while playing and not paused. |
| `draw` | After the scene and before `gameUi`, including paused editor Play. The borrowed target is outside a render pass; Eggy submits the frame. |
| `gameUi` | After scene/custom drawing, including paused editor Play. Builds Weeoui game content. |
| `uiEvent` | After built-in game UI, before gameplay. Return `true` to consume the event. Also runs during paused editor Play. |
| `editorUpdate` | While editing or paused. Use it for editor tools, not simulation. |
| `editorUi` | Builds the project's Inspector content when no entity is selected. Separate dock tabs use `editorPanelUi`. |
| `editorPanelUi` | Builds a declared panel. `panel` is the zero-based index in this type's `editor_panels`. |
| `editorCommand` | Invokes a declared View-menu command. `command` is the zero-based index in this type's `editor_commands`. |

Keep the parameter order and return types above, including error unions on hooks that
currently cannot fail. `init` has no `self`; it constructs the instance. Use `_` for
unused parameters.

Editor hooks never run in the runtime. Their `eggy.editor.Context` is borrowed;
`editor.app` provides the App. UI contexts and draw targets are also borrowed for their
hook only. The Build window suspends editor updates and game rendering.

### Dispatch order and failures

Hooks normally follow the plugin list, with the game first. `deinit` runs in reverse
order. `uiEvent` runs in reverse visual order and stops at the first `true`.

If `init` fails, Eggy stops the instances that already started and aborts startup.
An error ends the current hook dispatch, skipping later plugins in that dispatch.
Uncaught runtime hook errors are fatal; the editor logs game-library hook errors and
keeps running. See [Diagnose and handle errors](../how-to/handle-errors.md).

## Optional declarations

| Declaration | Meaning |
| --- | --- |
| `pub const components = .{ Health, Spin };` | Component types available to scene serialization and the Inspector |
| `pub const input_maps = .{PlayerInput};` | Typed input maps registered before `init` for enabled plugins |
| `pub const Preferences = struct { volume: f32 = 0.8 };` | Defaulted settings read with `app.preferences(Preferences)` |
| `pub const editor_panels = [_]eggy.plugins.EditorPanel{...};` | Dock-panel metadata paired with `editorPanelUi` |
| `pub const editor_commands = [_]eggy.plugins.EditorCommand{...};` | View-menu metadata paired with `editorCommand` |
| `pub const editor_file_types = [_]eggy.plugins.EditorFileType{...};` | Templates in both Assets New menus |

Disabling a plugin skips its instance and hooks. Its component types and preferences
remain known so scene and setting values are retained. The game is always enabled.

## Components

| Field type | Inspector control |
| --- | --- |
| Numbers | Drag horizontally, or click to type; Enter or Escape finishes |
| Two-to-four-number arrays, vectors, `x`/`y`/`z`/`w` structs, and `eggy.math.Vec2`/`Vec3`/`Vec4` | Axis boxes labelled X, Y, Z, W in red, green, blue, purple |
| `eggy.Color`, `r`/`g`/`b`/optional `a` structs, or three/four numbers named `color`, `colour`, or ending `_color` | Swatch and channel boxes; the picker has a wheel, sliders, hex codes, and presets |
| `eggy.math.Quat`, or three floats named with `rotation`, `orientation`, or `euler` | Rotation control with degree/radian Euler, quaternion, or axis-angle display |
| Bools, enums, tagged unions | Switch, dropdown, or variant dropdown with the active variant's fields |
| Nested structs, arrays, optionals | Nested rows; optionals have a set/clear switch |
| Pointers and strings | Display only |

Rotation fields use degrees unless their name ends `_rad`. Changing the rotation
display preserves the field's stored type. Clicking outside the colour picker keeps
the colour; Cancel restores it. Controls read world values every frame.

Add component offers types whose fields all have defaults. A component's `dependencies`
are added with it when editing or loading a scene; the Inspector prevents removing a
component still needed by another. `Mesh`, `Camera`, and `SceneInstance` depend on
`Transform`.

Reference slots accept matching entities/files by drag-and-drop; the x clears a slot.
`EntityRef(T)` requires component `T`, `EntityRef(void)` accepts any entity, and
`AssetRef(kind)` accepts the named file kind. Reference fields also work inside tagged
unions. See [Find entities safely](../how-to/render-scene.md#find-entities-safely).

## Editor panels

```zig
pub const Plugin = struct {
    clicks: u32 = 0,

    pub const editor_panels = [_]eggy.plugins.EditorPanel{
        .{ .key = "clicker", .title = "Clicker" },
        .{ .key = "about", .title = "About" },
    };

    pub fn editorPanelUi(self: *Plugin, panel: usize, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void {
        _ = editor;
        switch (panel) {
            0 => {
                if (ui.button("Click me")) self.clicks += 1;
                ui.label("Clicked {d} times", .{self.clicks});
            },
            else => ui.muted("Made with Eggy."),
        }
    }
};
```

Each panel builds Weeoui content every frame and has its own scroll, focus, and hover
state. Panels can dock, float, or pop out into an OS window. New panels open beside the
Inspector; the Window menu restores closed panels.

`title` appears on the tab, Window menu item, and pop-out window. `key` is the stable
layout identity, scoped to the published plugin name. Omit it to use the title.
Duplicate keys fail compilation; dock-ID hash collisions are reported. Keep a key
unchanged when renaming a panel or reordering declarations.

## File templates

```zig
pub const editor_file_types = [_]eggy.plugins.EditorFileType{.{
    .key = "material",
    .title = "Material",
    .extension = ".material.zon",
    .contents = ".{ .roughness = 0.5 }\n",
}};
```

This declaration adds a template under the plugin's name in both Assets New menus.
Eggy's built-in kinds are Scene, Input Map, and Folder.

| Field | Contract |
| --- | --- |
| `key` | Scoped to the published plugin name, like command keys |
| `title` | Display name; must not contain path separators |
| `extension` | Suffix; must not contain path separators |
| `contents` | Initial file bytes; omit for an empty file |

The example creates `Material.material.zon` in the chosen folder, adding a number if
the name exists. Templates remain available when the plugin is disabled. File creation
participates in Undo/Redo. Code/text files open in the configured editor; `.inmap.zon`
opens Eggy's Input Map editor.

For panel, command, and file-editing workflows, use [Extend the editor](../how-to/extend-editor.md).
