---
sidebar_position: 11
title: Extend the editor
slug: /guides/editor-tools
---

Add a plugin panel that edits the selected entity with undo support, then expose
commands or use host services for scene and project operations.

## Prepare an editor plugin

Use a [registered plugin](../how-to/create-plugins.md) with an editor panel. The
[hook reference](../reference/plugin-hooks.md#hooks) lists current signatures and
call order. Editor hooks receive a borrowed `*eggy.editor.Context`, available only
during the hook. Do not store it, App pointers, or live component pointers for a later
call. `editor.app` is the same App that game hooks receive.

Scene and file mutations require editing mode. Selection is available in both editing
mode and Play. List an edited component in the plugin's `components` so scenes can
store it; pointer-containing components cannot be snapshotted with `changeComponent`.

Custom importer, inspector, and scene-tool registration currently return
`error.NotImplemented`. They do not retain callbacks or register an extension.
Weeoui's custom widgets and layouts remain usable in panels.

## Edit the selected entity

In `editorPanelUi`, copy the current value, edit the copy, and pass both values to
`changeComponent`:

```zig
pub fn editorPanelUi(
    self: *Plugin,
    panel: usize,
    editor: *eggy.editor.Context,
    ui: *eggy.ui.Context,
) !void {
    _ = self;
    _ = panel;
    if (!ui.button("Raise selection")) return;
    const entity = try editor.selection() orelse return;
    const transform = editor.app.world.get(entity, eggy.Transform) orelse return;
    var after = transform.*;
    after.position[1] += 1;
    try editor.changeComponent(entity, eggy.Action(eggy.Transform){
        .before = transform.*,
        .after = after,
    });
}
```

`changeComponent` validates the entity, checks the expected before-state, applies the value,
marks the component changed, and records the scene in host-owned history. Do not also
assign the component or call `markChanged`. A value that has no serialized scene
change is rejected and restored.
Fields are preflighted against the existing 4 KiB serialized-field and 16 KiB parse budgets.
Oversized or over-complex values fail before mutation, which prevents an incomplete undo.
Undo restores serialized scene data, not arbitrary runtime-only world state.

Errors propagate to the editor's Console without closing the editor.

### Action values

`Action(T)` holds `before` and `after` values. `value(.undo)` selects `before`;
`value(.redo)` selects `after`:

```zig
const change = eggy.Action(f32){ .before = 0.5, .after = 0.8 };
volume = change.value(.redo);
volume = change.value(.undo);
```

An action does not allocate, deep-copy pointers, or own borrowed slices. Do not store live
component pointers in history. Use `changeComponent` or the other host services to validate,
apply, and record a change; an action value alone does not create an undo entry.

## Group changes

```zig
var group = try editor.beginAction("Arrange selection");
defer group.deinit();
try editor.changeComponent(entity, transform_change);
try editor.changeComponent(entity, mesh_change);
try group.commit();
```

Commit makes the children one undo step. Leaving an uncommitted group reverts its children
in reverse order. Nested groups are rejected. If cleanup itself fails, it is logged; inspect
the Console rather than assuming the group committed. History stores data, not callbacks
into your plugin, so unloading its library cannot leave a callable stale undo function.
Undo/redo of scene snapshots reconstructs entities: reacquire their IDs and components.

## Add commands

```zig
pub const editor_commands = [_]eggy.plugins.EditorCommand{
    .{ .key = "reset", .title = "Reset Tool State" },
};

pub fn editorCommand(self: *Plugin, command: usize, editor: *eggy.editor.Context) !void {
    _ = editor;
    switch (command) {
        0 => self.clicks = 0,
        else => unreachable,
    }
}
```

Commands appear in View. The key is scoped by the published plugin name; titles can
change. The host copies metadata and dispatches to the currently loaded plugin instance,
not to a stored function pointer from its previous library.

## Use host workflows for files and project changes {#scenes-files-and-project-settings}

When a tool changes files, use `createFolder`, `renameFile`, `duplicateFile`, `moveFile`,
`copyFile`, `importFile`, or `deleteFile`. These services preserve asset descriptors
and record undo history. Deletion moves files into the project's trash. Move and copy
do not depend on keyboard modifiers. Pass project-relative paths, except for the source
passed to `importFile`.

Use `selection` and `select` to read or change selection, and `openScene` and `saveScene`
to use the editor's scene workflow.

`projectSettings(arena)` returns `eggy.project.Config`, with strings owned by your arena.
`setDefaultScene(path)` changes the project's startup scene as an undoable setting.
Plugin preference values remain available through `editor.app.preferences(Preferences)`.

### Queue builds and project workflows

Use `editor.requestBuild()` or `editor.requestReload()` to queue the existing
Build/Reload workflow until the current hook returns. `showExport`, `showNewProject`,
and `showOpenProject` queue the normal editor workflow, window, or picker; they do
not complete the operation synchronously. A project transition runs after the hook
returns so it cannot unload code that is still executing.

A successful request means queued, not completed. Check the Console and Build
window for errors and progress; unsaved-change prompts use the normal editor UI.
Only one lifecycle request may be pending, and one cannot be queued inside an action group.
Use the [Console controls](../how-to/handle-errors.md#inspect-the-console) to filter
and inspect diagnostics.

## Check the edit and its undo

In editing mode, select an entity with a Transform, press Raise selection, and check
that its Y position increases by one. Undo and redo the edit. A committed action group
should appear as one undo step. Reacquire entity IDs and components after either operation.
Inspect the Console if a change, group cleanup, or queued request fails.

### Navigate the test scene {#scene-navigation}

A mouse wheel zooms; right-drag looks around and flies with WASD, Alt+left-drag orbits,
and middle-drag pans. On a touchpad, two-finger scrolling orbits the focus point on both
axes; hold Shift to pan or Ctrl to zoom. The Scene panel distinguishes mouse and
touchpad input on each scroll, so both can be used together. Native pinch gestures zoom
where the desktop exposes them through SDL. Gestures start only over the Scene, outside
its floating toolbar and other panels. SDL has no native twist-rotation event; use
horizontal two-finger scrolling to rotate around the scene.

Enter Play to check mode restrictions. The Scene toolbar, gizmo, and orientation widget
are hidden, and an accent border marks the game viewport as playing.

## Migrating older hooks

See [Migrating existing code](../reference/feature-support.md#migrating-existing-code)
for older signatures, [plugin hooks](../reference/plugin-hooks.md#hooks) for current
ones, and [ownership and reload](../explanation/ownership-and-reload.md) for library
boundaries. [Project configuration](../reference/project-configuration.md) covers
settings and preferences. The [API reference](pathname:///api/) lists editor service
contracts.
