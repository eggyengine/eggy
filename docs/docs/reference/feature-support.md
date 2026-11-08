---
title: Feature support
sidebar_position: 4
sidebar_label: Feature support
---

What works on each platform, and which declared services still have no backend. Function
signatures, ownership contracts and errors are in the [API reference](pathname:///api/).

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
touch gameplay input, [named input maps](../input/map-input.md), value timers, and gameplay
time scaling are implemented. Resource reads, model imports and image decoding have
owned asynchronous requests with polling, progress and cooperative cancellation.
Native requests use bounded worker threads; browser builds defer decoding of already-preloaded
data until polling. `Scenes.stream` loads a scene over several frames behind a loading screen
([Stream a scene](../scenes/load-assets.md#stream-a-scene-behind-a-loading-screen)). `Scenes.replace`
stages synchronous scene replacement for the end of the gameplay update.

| Surface | Desktop | Web |
| --- | --- | --- |
| Native ECS/math, keyboard/mouse, frame time, static graphics | Implemented | Same core APIs |
| Value timers and gameplay time scaling | Implemented | Same allocation-free API |
| Named input maps, priorities, modifiers, hold/tap/chord triggers | Implemented; project editor included | Shared runtime API |
| Controllers, rumble, and touch contacts | SDL3; hardware-dependent | SDL3/browser-dependent |
| Synchronous project/packaged resource and scene providers | Implemented | Packaged assets preloaded at startup |
| [Translated text](../ui/translate-text.md): `app.localization` | A `.zon` table per locale, with regional locales falling back to their language | Same API |
| [Game-save slots](../game-code/save-games.md) | Atomic versioned saves in project-specific user data | Persistent browser localStorage; quota/availability errors are explicit |
| Weeoui game UI and custom draw hooks | Implemented | Shared runtime API; no editor import |
| [UI scenes](../ui/ui-scenes.md): `UiScreen` HUDs and `UiBillboard` world panels | Implemented; UI Designer panel, animated GIFs, plugin widgets | Same runtime API |
| Materials and directional/point scene lights | Implemented; Inspector components and reusable material assets | Shared renderer, up to sixteen lights |
| [Debug drawing and CPU profiling](../game-code/debug-and-profile.md) | World-space overlays, named samples/counters; DevTools Game tab | Same frame-owned collectors and drawing |
| [World sprites, text and particles](../rendering/world-drawing.md) | Depth-tested atlas sprites, camera-facing glyphs, and particles that fly and fade on game time | Same scene renderer |
| [Sound and 3D audio](../audio.md): `AudioSource`, `AudioListener`, `app.audio()` | WAV, FLAC, MP3 and Ogg Vorbis through miniaudio; buses; Asset Preview playback | Same API |
| [Animation](../animation/animation-reference.md): `Animator`, `app.animation()` | Authored `.clip.zon` clips and imported model clips (bones, blend shapes, baked frames), with blending; Animation panel | Same API; packaged models keep their rigs |
| [Post-processing and shaders](../rendering/post-processing-and-shaders.md): `PostProcess`, Slang `.slang` files | HDR rendering, tone mapping, bloom and grading; project post passes and material surface shaders, compiled while the editor runs | Same; shaders compiled when the game is built |
| [2D](../rendering/make-a-2d-game.md): `Sprite`, `SpriteAnimator`, `Tilemap` | 2D Scene panel with handles, sprite-sheet preview and tile painting | Same API |
| [Physics](../physics/use-physics.md): `Collider`, `RigidBody`, `CollidingEntities` | 2D or 3D, `f32` or `f64`, at a fixed step; collider wireframes in the editor | Same API |
| [Cutscenes](../animation/cutscenes.md) and rendering them to video | Camera cuts, letterbox, takeover; the Render menu writes PNG frames and, with ffmpeg, an MP4 | Cutscenes play; no Render menu |
| [Dev console](../game-code/dev-console.md) | Eggy's commands and your own | Same |
| Editor context, panels, commands, actions | Desktop only | Not run or linked |
| Missing-backend contracts listed above | `NotImplemented` | `NotImplemented` |

See [Play sound and 3D audio](../audio.md) for sound.
Browser builds preload packaged resources through Emscripten, then read them synchronously
through SDL. Keep the generated `.data` file beside the WebAssembly, JavaScript and HTML.
Android APKs contain the same packaged data and read it through SDL's AssetManager adapter;
APK export targets Android 13 (API 33) through Android 16 (API 36) devices with Vulkan 1.3,
through the Android plugin.

Rebuild the editor and game library together after updating Eggy: their ABI is checked, not
mixed across revisions. [Ownership, Play, and reload](../game-code/ownership-and-reload.md#engine-changes-replace-the-editor)
explains what happens when Eggy changes under an open editor.
