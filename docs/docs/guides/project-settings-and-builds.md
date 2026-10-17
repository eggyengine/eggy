---
sidebar_position: 9
title: Project settings and builds
---

# Project settings and builds

A game package has `src/main.zig` with `pub const Game`; a reusable plugin/library has
`src/root.zig` with `pub const Plugin`. Use `addGame` and `addPlugin` as shown in
[Plugins](plugins.md). They share the same engine and native ECS types.

## Project configuration

`eggy.zon` lives beside `build.zig.zon`:

```zig
.{
    .name = "my_game",
    .title = "My Game",
    .version = "0.1.0",
    .default_scene = "resources/scene/start.scene.zon",
    .metadata = .{
        .company = "Example Studio",
        .description = "A small game",
    },
}
```

`name` is the package/build name. Players see `title`. File > Project Settings edits the
same configuration, including executable metadata and the startup scene.
The runtime is named after the game and the editor is `<name>_editor`.

## Build and export

| Command | Result |
| --- | --- |
| `zig build all` | Runtime and desktop editor, without launching |
| `zig build runtime` / `editor` | One executable |
| `zig build run` | Editor on desktop; runtime browser app on web |
| `zig build run-runtime` | Standalone game |
| `zig build runtime -Dscene=resources/scene/start.scene.zon` | Choose this build's startup scene |
| `zig build export` | ReleaseFast runtime, packaged resources/libraries, and ZIP |

Export needs `.default_scene` or `-Dscene`. File > Export asks for a startup scene when
necessary. Distribute the exported directory or archive, not just the executable: resource
manifests, converted models/images, and required libraries belong with it.

The build honors `-Dtarget` and `-Doptimize`. The editor is desktop only. Browser builds
use Emscripten and the shared runtime; the default browser resource provider remains
unsupported. See the [support table](developer-api.md#capability-support) for limitations.

## Preferences are not save games

A plugin declares `Preferences` as a struct with defaulted bool, integer, float, or enum
fields. Read values through `app.preferences(Preferences)`. In editor tools use
`editor.app.preferences(Preferences)` directly so changes appear without caching them.

Plugin preferences belong to the project in `.eggy/plugins/<published-name>.zon`;
the game's key is `game`. The runtime bakes in project preferences.
The editor's own settings can additionally have global defaults.

Do not use preferences as a gameplay save format. `app.storage` is a separate, currently
unsupported contract; writing it returns `NotImplemented` rather than claiming persistence.

## Rebuilds and editor tools

The editor rebuilds changed game code when it regains focus. Game-library replacement
keeps scene data but restarts plugin fields and systems. A changed engine requires the
editor itself to reload. Keep no references to old plugin instances or component storage.

Plugins can call `editor.requestBuild()` or `requestReload()`. They queue existing
workflows until the current hook returns. `showExport`, `showNewProject`, and
`showOpenProject` likewise open the normal editor workflow rather than pretending to
complete it synchronously. Errors and progress use the Console and Build window.

Scene/file tools and undo groups are covered in [Editor tools](editor-tools.md).
Logging uses `std.log.scoped`, which the editor routes to its Console; no separate logger
is needed.
