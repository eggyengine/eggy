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
| `network` | connection, listening, messages, polling, disconnection |
| `navigation` | paths and destinations; no physics or collision access |

`eggy.network.support` and `eggy.navigation.support` report support without an App. These contracts do
not add components to the Inspector.

Working low-level graphics (`eggy.vit`), UI (`eggy.ui`), math (`eggy.math`), ECS
(`eggy.ecs`), scene formats, and asset formats remain available directly. SDL controllers,
touch gameplay input, [named input maps](../how-to/map-input.md), value timers, and gameplay
time scaling are implemented. Resource reads, model imports and image decoding have
owned asynchronous requests with polling, progress and cooperative cancellation.
Native requests use bounded worker threads; browser builds defer decoding of already-preloaded
data until polling. `Scenes.stream` loads a scene over several frames behind a loading screen
([Stream a scene](../how-to/load-assets.md#stream-a-scene-behind-a-loading-screen)). `Scenes.replace`
stages synchronous scene replacement for the end of the gameplay update.

| Surface | Desktop | Web |
| --- | --- | --- |
| Native ECS/math, keyboard/mouse, frame time, static graphics | Implemented | Same core APIs |
| Value timers and gameplay time scaling | Implemented | Same allocation-free API |
| Named input maps, priorities, modifiers, hold/tap/chord triggers | Implemented; project editor included | Shared runtime API |
| Controllers, rumble, and touch contacts | SDL3; hardware-dependent | SDL3/browser-dependent |
| Synchronous project/packaged resource and scene providers | Implemented | Packaged assets preloaded at startup |
| [Translated text](../how-to/translate-text.md): `app.localization` | A `.zon` table per locale, with regional locales falling back to their language | Same API |
| [Game-save slots](../how-to/save-games.md) | Atomic versioned saves in project-specific user data | Persistent browser localStorage; quota/availability errors are explicit |
| Weeoui game UI and custom draw hooks | Implemented | Shared runtime API; no editor import |
| [UI scenes](../guides/ui-scenes.md): `UiScreen` HUDs and `UiBillboard` world panels | Implemented; UI Designer panel, animated GIFs, plugin widgets | Same runtime API |
| Materials and directional/point scene lights | Implemented; Inspector components and reusable material assets | Shared renderer, up to sixteen lights |
| [Debug drawing and CPU profiling](../how-to/debug-and-profile.md) | World-space overlays, named samples/counters; DevTools Game tab | Same frame-owned collectors and drawing |
| [World sprites, text and particles](../how-to/world-drawing.md) | Depth-tested atlas sprites, camera-facing glyphs, and particles that fly and fade on game time | Same scene renderer |
| [Sound and 3D audio](../guides/play-sound.md): `AudioSource`, `AudioListener`, `app.audio()` | WAV, FLAC, MP3 and Ogg Vorbis through miniaudio; buses; Asset Preview playback | Same API |
| [Animation](audio-and-animation.md#animation): `Animator`, `app.animation()` | Authored `.clip.zon` clips and imported model clips (bones, blend shapes, baked frames), with blending; Animation panel | Same API; packaged models keep their rigs |
| [Post-processing and shaders](../guides/post-processing-and-shaders.md): `PostProcess`, Slang `.slang` files | HDR rendering, tone mapping, bloom and grading; project post passes and material surface shaders, compiled while the editor runs | Same; shaders compiled when the game is built |
| [2D](../guides/make-a-2d-game.md): `Sprite`, `SpriteAnimator`, `Tilemap` | 2D Scene panel with handles, sprite-sheet preview and tile painting | Same API |
| Editor context, panels, commands, actions | Desktop only | Not run or linked |
| Missing-backend contracts listed above | `NotImplemented` | `NotImplemented` |

See [Play sound and 3D audio](../guides/play-sound.md) for sound.
Browser builds preload packaged resources through Emscripten, then read them synchronously
through SDL. Keep the generated `.data` file beside the WebAssembly, JavaScript and HTML.
Android APKs contain the same packaged data and read it through SDL's AssetManager adapter;
APK export targets Android 13 (API 33) through Android 16 (API 36) devices with Vulkan 1.3,
through the Android plugin.

## Migrating existing code

| Older code | Current code |
| --- | --- |
| `AssetRef(kind).init(runtime_path)` | `try AssetRef(kind).parse(runtime_path)`; `init` is for literals |
| `editorUpdate(self, app)` | `editorUpdate(self, editor)`; use `editor.app` |
| `editorUi(self, ui)` | `editorUi(self, editor, ui) !void` |
| `editorPanelUi(self, panel, ui)` | `editorPanelUi(self, panel, editor, ui) !void` |
| Custom cache loader returning `?Model`/`?Texture` | Return an error union; author resource access uses the C-safe bridge |
| Manually feeding `Input.handle(event)` | `try Input.handle(event)`; device/host failures are explicit |
| `app.materials.assign(...)`, `app.lighting.setLight(...)` | `app.materials().assign(...)`, `app.lighting().setLight(...)`; borrowed current-world services |
| `app.audio.play(...)` | `app.audio().play(...)`; buses are now `master`, `music`, `effects`, `dialogue` and `ui` |
| `app.materials().applyEffect(...)` | Set the `Environment`'s `post`, or a camera's `PostProcess` |
| `app.animation.play(entity, .{ .model, .name }, ...)` | `app.animation().play(entity, .{ .imported = ... }, ...)`; a clip is an `AssetRef(.animation)`, not a name |

Rebuild the editor and game library together after updating the engine. Their ABI is
checked, not mixed across revisions. Native World/query APIs, transforms, simple polling,
preferences, `addGame`/`addPlugin`, and physics are not renamed or wrapped.

For state and pointer lifetimes during that rebuild, see
[Ownership, Play, and reload](../explanation/ownership-and-reload.md).
