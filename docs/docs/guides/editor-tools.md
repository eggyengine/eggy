---
sidebar_position: 4
title: Editor tools
---

# Editor tools

Editor hooks receive a borrowed `*eggy.editor.Context`. It is available only during the
hook: do not store it, App pointers, or live component pointers for a later call.
`editor.app` is the same App that game hooks receive.

## Scene navigation

The Scene toolbar's touchpad button switches between **Mouse** (the default) and
**Touchpad** navigation. In Touchpad mode, two-finger scrolling orbits the focus point
on both axes; hold **Shift** to pan, or **Ctrl** to zoom. Native pinch gestures zoom
where the desktop exposes them through SDL. Fractional scroll motion and momentum are
preserved. Gestures start only over the Scene, not its floating toolbar or another panel.

Mouse mode keeps wheel zoom, right-drag look and WASD flight, Alt+left-drag orbit,
and middle-drag pan. Those button/drag controls also work in Touchpad mode.
SDL does not expose a native twist-rotation event; use horizontal two-finger scrolling
to rotate around the scene. Desktop-reserved gestures remain controlled by the OS.

## Edit the selected entity

Use a typed `Action(T)` instead of applying a change and separately constructing its undo:

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
marks the component changed, and records the scene in host-owned history. You do not also
assign the component or call `markChanged`. Pointer-containing components cannot be
snapshotted this way. List your component in the plugin's `components` so scenes can store
it. A value that has no serialized scene change is rejected and restored.
Fields are preflighted against the existing 4 KiB serialized-field and 16 KiB parse budgets;
oversized/over-complex values fail before mutation rather than producing an incomplete undo.
Undo restores serialized scene data, not arbitrary runtime-only world state.

Scene/file mutations require editing mode, not Play. Selection is available in either mode.
Errors propagate to the editor's Console without closing the editor.

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

Commands appear in **View**. The key is scoped by the published plugin name; titles can
change. The host copies metadata and dispatches to the currently loaded plugin instance,
not to a stored function pointer from its previous library.

## Scenes, files, and project settings

`selection` and `select` read/change selection. `openScene` and `saveScene` use the editor's
scene workflow. `createFolder`, `renameFile`, `duplicateFile`, `moveFile`, `copyFile`,
`importFile`, and `deleteFile` use descriptor-aware file operations and undo history;
deletion moves files into the project's trash. Move/copy do not depend on keyboard modifiers.
Paths are project-relative except the source passed to `importFile`.

`projectSettings(arena)` returns `eggy.project.Config`, with strings owned by your arena.
`setDefaultScene(path)` changes the project's startup scene as an undoable setting.
Plugin preference values remain available through `editor.app.preferences(Preferences)`.

`requestBuild` and `requestReload` queue the existing Build/Reload workflow.
`showExport`, `showNewProject`, and `showOpenProject` queue the corresponding editor
window or picker. They run after your hook returns, so a project transition never unloads
code that is still executing. A successful request means **queued**, not finished;
progress, errors, and unsaved-change prompts appear through the normal editor UI.
Only one lifecycle request may be pending, and one cannot be queued inside an action group.

Custom importer, inspector, and scene-tool registration currently return
`error.NotImplemented`. These contracts do not retain callbacks or pretend to register a
working extension. Weeoui's existing custom widgets and layouts remain usable in panels.

## Migrating older hooks

`editorUpdate` now takes `editor`, not `app`; use `editor.app`. `editorUi` and
`editorPanelUi` now take `editor` before their UI context and return `!void`. Gameplay hooks,
the native ECS World, and physics are unchanged.
