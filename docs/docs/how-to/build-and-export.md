---
slug: /guides/project-settings-and-builds
sidebar_position: 2
title: Build and distribute a game
---

# Build and distribute a game

Build a standalone runtime, select its startup scene, and export the directory or ZIP
that players need.

## Before you start

Use a game package that calls `eggy.addGame`, with a saved scene under `resources/`.
Run `eggy_editor doctor --project .` if the Zig toolchain or dependencies need checking.
See [Set up a project](set-up-project.md) for creation and toolchain repairs.

For a game built entirely in code, use the
[code-only tutorial](../tutorials/code-only-games.md). Export currently requires a
startup scene even when ordinary runtime builds can start without one.

## Steps {#build-and-export}

### Choose the startup scene

Open File > Project Settings in the editor and choose the default scene. Set the
player-visible title, version, and executable metadata there if needed.

For a one-off build, pass the scene without changing the saved default:

```sh
zig build runtime -Dscene=resources/scene/start.scene.zon
```

Use a path to an existing project scene. The
[configuration reference](../reference/project-configuration.md#startup-scene-selection)
lists runtime fallbacks and export requirements.

### Run the standalone game

From the project root, run:

```sh
zig build run-runtime
```

Check the startup scene and game UI outside the editor. Use `zig build all` to build
the runtime and desktop editor without opening either one.

### Export for the target platform

File > Export lists the platforms down the left, with the chosen one's settings beside
them and the scene the game starts in above. It asks for that scene first only when the
project has no default scene; changing it there changes the default. Each platform offers:

- **Architecture**: x86-64 or ARM64 for Windows and Linux, Apple silicon or Intel
  for macOS.
- **C library**, for Linux: glibc for most desktop distributions, or musl for Alpine and
  other small systems. A musl build has no screen reader support and can't compile shaders
  while it runs.
- **Optimize for**: Speed (`fast`), Size (`small`), Speed with safety checks
  (`safe`), or Debugging (`debug`).
- **Tune for this computer**, on this computer's own system: faster here, but the game may
  not start on older processors.
- **ZIP archive**, on desktop platforms: whether to zip the folder as well.
- **macOS SDK**, for macOS from another system: the MacOSX.sdk folder to build with; type
  its path or choose it with the folder button. On a Mac, Eggy uses the SDK Xcode or its Command Line Tools installed.

Plugins can add platforms and settings; see [Export platforms](../reference/plugin-hooks.md#export-platforms).
Export shows a progress bar for the whole build and the step under way, with Zig's
output a click away. From the package directory, the equivalent build step is:

```sh
zig build export
```

The step builds a `fast` runtime and packages resources and libraries. `-Dtarget`
selects a platform, `-Dexport-optimize` the optimization (default `fast`),
`-Dexport-zip=false` skips the ZIP, and `--sysroot` names a macOS SDK. Ordinary builds'
`-Doptimize` doesn't apply to export.

For interactive terminal export, run `eggy_editor export`. It lists scenes and common
target triples. To skip prompts, supply the answers:

```sh
eggy_editor export --project ./space_game --scene resources/scene/main.scene.zon --target native --non-interactive
```

The CLI leaves the saved default scene unchanged. The GUI export dialog saves its scene
selection. Web and Android exports set up missing SDKs automatically; see
[Targets and SDKs](../reference/editor-cli.md#targets-and-sdks).

### Export for Web or Android

Choose **Web** in File > Export. Android comes from the **Android** plugin, which ships
with Eggy: install it in Edit > Plugins..., and **Android** joins the platforms in File >
Export. Or use:

```sh
zig build export -Dtarget=wasm32-emscripten
zig build export -Dtarget=aarch64-linux-android.35
```

Python 3.12 or newer is required for automatic setup. The first export downloads
official tools into Eggy's SDK cache; later exports reuse them. Setup output and
errors appear in the export window. Cancel stops the build and SDK installers on
Linux and macOS; completed SDK downloads remain available for the next attempt.

Web setup installs emsdk 4.0.14 and prepares its WebGPU port. An installed SDK set
through `EMSDK`, or an installation in `~/emsdk`, takes precedence. Browser builds
preload the game's scenes and converted assets into their packaged filesystem;
distribute the generated `.data` file together with the HTML, JavaScript and WebAssembly.
The page shows the game across the whole browser window, with a progress bar while it
downloads and any error that stops it shown over the game. Serve the folder from a web
server (any static host, such as GitHub Pages, works): browsers won't load the `.data`
file from a page opened straight from disk. The host must serve it over HTTPS (or `localhost`), as WebGPU needs a secure page; see
[Put your game on the web](../guides/web-deploy.md).

For Android, pick the **Android version**: the oldest Android the game runs on, from
Android 13 (API 33) to Android 16 (API 36), Android 15 (API 35) unless you set another in
Edit > Preferences under Android. The number after `android.` in `-Dtarget` is the same API
level. Pick ARM64 for phones and tablets, or x86-64 for emulators.

Android export currently requires a Linux x86-64 or macOS host, `sh`, and `patch`.
It installs missing Android command-line tools, the platform for the API level chosen,
build-tools 36.0.0, an NDK (27.1.12297006, or 30.0.16248370 for API 36) and, if no JDK is
installed, Temurin JDK 17. **Starting an Android
export accepts Google's Android SDK licenses.** An existing `ANDROID_HOME` or
`ANDROID_SDK_ROOT` is reused; `JAVA_HOME`, `JDK_HOME`, or `javac` on PATH selects
an installed JDK. The setup may need several gigabytes of disk space.

The Android result is `zig-out/export/<name>-aarch64-linux-android-test.apk`.
Install it on a device running the Android version chosen or later, with Vulkan 1.3, for
example with
`adb install -r <file>.apk`. Its scene, converted models and textures are inside
the APK. The runtime pauses rendering when backgrounded and recreates its surface
when foregrounded.

**APKs are test-signed**, not signed for a store release. The generated test key
lives in the build cache, not your source tree; clearing that cache can change
the key and require uninstalling the old app before reinstalling it. Store signing,
Android App Bundles and multi-ABI APKs are not part of this export.

### Distribute the whole export

The default output is `zig-out/export/<name>-<target>/` and a ZIP beside it. Ship the
directory or archive, including `data/` and shared libraries. Copying just the executable
loses assets and runtime dependencies.

Keep the installed `bin/` and `lib/` layout intact. Desktop distributions include
shared SDL3; Windows DLLs are installed beside the executable. Browser builds have no
editor and require browser WebGPU support, so check
[feature support](../reference/feature-support.md#capability-support) before choosing web.

## Verify

Extract the ZIP or copy the exported directory outside the source tree. Launch the
runtime from that copy and check its startup scene, textures, UI, and required libraries.
Do not rely on files still present in your development checkout.

If the build fails, use [Diagnose and handle errors](handle-errors.md) to inspect the
Console or Build window output.

## Related reference

- [CLI options and build commands](../reference/editor-cli.md)
- [Project configuration and startup scene precedence](../reference/project-configuration.md)
- [Assets, scenes, and packaging](../explanation/assets-and-scenes.md)
