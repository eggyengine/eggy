---
slug: /guides/developer-api
sidebar_position: 4
title: Feature support and migration
---

# Feature support and migration

Use the API reference in the navigation bar for function signatures, ownership contracts,
errors, and examples. The tables here distinguish implemented features from declarations
that still need a backend.

## Capability support

These App services have no backend yet. Their `support` value
is `.not_implemented`, and every operation returns `error.NotImplemented`. They allocate
no output devices, threads, sessions, files, fake handles, or successful empty results.

| App service | Requests |
| --- | --- |
| `audio` | play, pause/unpause, stop, voice/bus gain, listener placement |
| `animation` | play, blend, pause, stop, seek a named model clip |
| `draw2d` | sprites and world-space text |
| `materials`, `lighting` | material assignment, light descriptions, render effects |
| `particles` | emission and stopping |
| `network` | connection, listening, messages, polling, disconnection |
| `navigation` | paths and destinations; no physics or collision access |
| `localization` | locale selection and translated-text lookup |
| `debug_draw`, `profiling` | debug primitives, samples, and counters |

`eggy.audio.support` reports support without an App. Components can store sound references;
`try app.audio.play(sound, .{})` returns `error.NotImplemented`. Animation references do
not add skeletons or clips to `.eggmodel`. These contracts do not add components to the
Inspector.

Working low-level graphics (`eggy.vit`), UI (`eggy.ui`), math (`eggy.math`), ECS
(`eggy.ecs`), scene formats, and asset formats remain available directly. SDL controllers,
touch gameplay input, [named input maps](../how-to/map-input.md), value timers, and gameplay
time scaling are implemented. Streaming and async resource loading are not:
`Resources.readAsync`/`cancel` and `Scenes.stream` fail explicitly. `Scenes.replace`
stages synchronous scene replacement for the end of the gameplay update.

| Surface | Desktop | Web |
| --- | --- | --- |
| Native ECS/math, keyboard/mouse, frame time, static graphics | Implemented | Same core APIs |
| Value timers and gameplay time scaling | Implemented | Same allocation-free API |
| Named input maps, priorities, modifiers, hold/tap/chord triggers | Implemented; project editor included | Shared runtime API |
| Controllers, rumble, and touch contacts | SDL3; hardware-dependent | SDL3/browser-dependent |
| [Game-save slots](../how-to/save-games.md) | Atomic versioned saves in project-specific user data | Persistent browser localStorage; quota/availability errors are explicit |
| Synchronous project/packaged resource and scene providers | Implemented | Packaged assets preloaded at startup |
| Weeoui game UI and custom draw hooks | Implemented | Shared runtime API; no editor import |
| Editor context, panels, commands, actions | Desktop only | Not run or linked |
| Missing-backend contracts listed above | `NotImplemented` | `NotImplemented` |

See [Audio and animation contracts](audio-and-animation.md) for request syntax and working alternatives
to those unimplemented playback contracts.
Browser builds preload packaged resources through Emscripten, then read them synchronously
through SDL. Keep the generated `.data` file beside the WebAssembly, JavaScript and HTML.
Android APKs contain the same packaged data and read it through SDL's AssetManager adapter;
APK export currently targets Android 15+ devices with Vulkan 1.3.

## Migrating existing code

| Older code | Current code |
| --- | --- |
| `AssetRef(kind).init(runtime_path)` | `try AssetRef(kind).parse(runtime_path)`; `init` is for literals |
| `editorUpdate(self, app)` | `editorUpdate(self, editor)`; use `editor.app` |
| `editorUi(self, ui)` | `editorUi(self, editor, ui) !void` |
| `editorPanelUi(self, panel, ui)` | `editorPanelUi(self, panel, editor, ui) !void` |
| Custom cache loader returning `?Model`/`?Texture` | Return an error union; author resource access uses the C-safe bridge |
| Manually feeding `Input.handle(event)` | `try Input.handle(event)`; device/host failures are explicit |

Rebuild the editor and game library together after updating the engine. Their ABI is
checked, not mixed across revisions. Native World/query APIs, transforms, simple polling,
preferences, `addGame`/`addPlugin`, and physics are not renamed or wrapped.

For state and pointer lifetimes during that rebuild, see
[Ownership, Play, and reload](../explanation/ownership-and-reload.md).
