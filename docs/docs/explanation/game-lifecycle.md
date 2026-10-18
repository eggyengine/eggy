---
sidebar_position: 1
title: How a game runs
---

# How a game runs

Eggy builds a game package into a runtime for players and a desktop editor for working
on the game. Both run the same `Game` and plugins. The runtime can also target the web,
subject to the [current platform limits](../reference/feature-support.md#capability-support).

## The game is the first plugin

`src/main.zig` declares `pub const Game`. A reusable package declares `pub const Plugin`
in `src/root.zig`. Both are Zig types with optional hooks, components, preferences, and
editor declarations. The game runs first, followed by plugins in build-list order.

Plugins are compiled into the game. A package can expose a plugin while using it in its
own game, and dependencies share the game's Eggy. There is no runtime plugin discovery
or separate inheritance interface for games.

## The App belongs to the host

Each hook receives the current `*eggy.App`, or an editor context containing it.
There is no global current world or player.

| App field | Role |
| --- | --- |
| `window` | Window adapter; `app.window.window` is the borrowed SDL window |
| `graphics` | GPU device and the main window's swapchain |
| `world` | ECS world, using `eggy.ecs` |
| `input` | Routed keyboard/mouse state and named input maps for this frame |
| `time` | Gameplay clocks, delta, and frame count |
| `process_init` | Zig's `std.process.Init`: arguments, environment, arena, allocator, and I/O |

`app.process_init` remains valid for the run. For example,
`app.process_init.environ_map.get("MY_GAME_LEVEL")` reads an environment variable.
The App and plugin instances may move; a hook's pointers are not permanent handles.
See [Ownership, Play, and reload](ownership-and-reload.md).

Eggy re-exports libraries through `eggy.ecs` (Clutch), `eggy.math` (Eggenvector),
`eggy.ui` (Weeoui), and `eggy.vit` (Vitellus). Those libraries retain their own APIs.
`eggy.sdl_adapter.sdl` is the SDL3 binding used by the engine.

## Startup

The runtime chooses and loads its startup scene before starting plugins. Preferences
and enabled plugins' input maps are registered before `init`, so initialization can
find scene entities and read settings.

Each enabled plugin's `init` constructs its value and can register ECS systems. Once
all plugins have started, Eggy runs the world's Init stages. A failed `init` unwinds
already-started plugins and prevents startup.

Scene selection is a build decision; the
[configuration reference](../reference/project-configuration.md#startup-scene-selection)
lists its precedence.

## Running frames

Input reaches UI before gameplay. Weeoui may consume it, then custom `uiEvent` hooks
may consume it before gameplay events. Gameplay polling uses the routed frame state;
games must not poll SDL's event queue themselves.

During a running frame, plugin `update` hooks run before ECS Update systems. Rendering
draws the scene, then `draw`, then `gameUi`. The supplied draw target and UI context
belong to that frame; Eggy owns frame submission.

Gameplay clocks and input edges follow the rules in
[Input and gameplay time](input-and-time.md). Hook signatures and dispatch order are
listed in [Plugin hooks and declarations](../reference/plugin-hooks.md#hooks).

## The editor has editing and playing states

While editing, `editorUpdate` runs instead of gameplay updates. Play starts gameplay
against the scene and runs its systems and events. Pause stops gameplay updates while
keeping game UI and drawing available; editor tools can still run.

The editor hosts the game in a shared library, which it can rebuild independently.
The editor UI and layout survive a game-library swap, while plugin state restarts.
The Build window suspends editor updates and game rendering during the build.

The [Play and reload explanation](ownership-and-reload.md) describes what survives,
what is restored on Stop, and which values become invalid.

## Shutdown and errors

Started plugins stop in reverse order through `deinit`, releasing resources they own.
The host tears down the App, world, and engine resources.

The runtime treats uncaught hook errors as fatal. The editor reports running
game-library hook failures and keeps the editor usable; a failed game initialization
prevents that game instance from starting. Recovery within a hook is described in
[Diagnose and handle errors](../how-to/handle-errors.md).
