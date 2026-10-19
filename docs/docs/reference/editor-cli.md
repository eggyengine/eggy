---
slug: /guides/editor-cli
sidebar_position: 3
title: Editor CLI and build commands
---

# Editor CLI and build commands

Run `eggy_editor`, or your game's `<name>_editor`, without arguments to open the GUI.
`--project <directory>` explicitly opens a project in that GUI.
The following subcommands run without a window or graphics device:

| Command | Result |
| --- | --- |
| `doctor` | Check the Zig toolchain and project dependencies; offer repairs |
| `new` | Create a project and build its editor |
| `export` | Package a ReleaseFast runtime as a directory and ZIP |

For a project-creation walkthrough, use [Set up a project](../how-to/set-up-project.md).
For distribution steps, use [Build and distribute a game](../how-to/build-and-export.md).

## Prompts and automation

Every command prompts for missing answers. Supply options to skip individual questions,
or add `--non-interactive` to never read input. Unattended commands use documented
defaults and fail when a required answer is missing. EOF cancels an unanswered prompt.

```sh
eggy_editor --help
eggy_editor doctor --help
eggy_editor new --help
eggy_editor export --help
```

## `doctor` {#check-the-toolchain}

```sh
eggy_editor doctor
eggy_editor doctor --project . --fix=false --non-interactive
```

Doctor checks the supported Zig version on `PATH`, the standard library, a real compiler
invocation, cache write access, and the project's build configuration and dependencies.
The directory defaults to `.`; without a `build.zig`, only toolchain checks run.
Normal dependency checks may fetch missing packages into Zig's cache.

| Option | Default |
| --- | --- |
| `--project <DIR>` | Current directory |
| `--fix[=true\|false]` | Ask before repairs; decline in unattended mode |
| `--non-interactive` | Off |

Eggy recommends [zvm](https://www.zvm.app) for Zig version management. If Zig is missing
or incompatible, doctor offers to run `zvm install` and `zvm use` for Eggy's required
version. Install zvm first and keep its `bin` directory first on `PATH`.

| Option | Repair policy |
| --- | --- |
| No `--fix` | Ask before repair/prefetch; unattended mode declines |
| `--fix` | Approve toolchain repairs and prefetch all project dependencies |
| `--fix=false` | Decline repairs and optional dependency prefetch |

Selecting Zig changes the active zvm version. Doctor does not delete caches or
install zvm, system SDKs, graphics drivers, or language servers.

## `new` {#create-a-project}

```sh
eggy_editor new
eggy_editor new --title "Space Game" --name space_game --directory ./space_game --non-interactive
```

| Option | Default |
| --- | --- |
| `--title` | Required |
| `--name` | Zig package name derived from the title |
| `--directory` | Package name, relative to the current directory |
| `--open` | Off; add it to launch the GUI after the build |
| `--non-interactive` | Off |

The destination must be absent or empty; existing files are never overwritten.
Creation uses the same bundled engine and template as **File > New Project**, then
builds the project's editor. Without `--open`, it finishes in the terminal.

## `export` {#export-a-game}

```sh
eggy_editor export
eggy_editor export --project ./space_game --scene resources/scene/main.scene.zon --target native --non-interactive
```

| Option | Default |
| --- | --- |
| `--project` | Current directory |
| `--scene` | `eggy.zon`'s `.default_scene`; required if none is saved |
| `--target` | `native` |
| `--non-interactive` | Off |

Interactive mode lists scenes and common target triples. Any valid Zig target triple
can be supplied, including `x86_64-windows-gnu`, `aarch64-macos`, and
`wasm32-emscripten` and `aarch64-linux-android.35`.

The scene must exist under `resources/`. This command leaves the saved default scene
unchanged; the GUI's export dialog saves its selection. The command writes
the directory and ZIP under the project's `zig-out/export/`, or a test-signed APK
when targeting Android.

Distribute the complete directory, including `data/` and shared libraries, not only the
executable.

## Build commands

Run these from the game's package directory. The package must call `eggy.addGame`.

| Command | Result |
| --- | --- |
| `zig build all` | Runtime and desktop editor, without launching |
| `zig build runtime` | Runtime only |
| `zig build editor` | Desktop editor only |
| `zig build run` | Editor on desktop; runtime in a browser on web |
| `zig build run-runtime` | Standalone game |
| `zig build runtime -Dscene=resources/scene/start.scene.zon` | Runtime with the selected startup scene |
| `zig build export` | ReleaseFast runtime directory and ZIP under `zig-out/export/` |

`-Dtarget` selects the target and `-Doptimize` selects optimization for ordinary builds.
Export builds the runtime in ReleaseFast unless `-Dexport-optimize` says otherwise, and
skips the ZIP with `-Dexport-zip=false`. It needs a scene from `-Dscene` or
`eggy.zon`'s `.default_scene`; it does not use the editor's last-open scene.
See [Startup scene selection](project-configuration.md#startup-scene-selection).

## Targets and SDKs

| Target | Requirements and limits |
| --- | --- |
| `native` | Uses the host platform and its native dependencies |
| `aarch64-linux-gnu`, `x86_64-linux-musl` | Linux for another architecture or C library; fatal errors are logged, not shown in a dialog. musl builds have no screen reader support or run-time shader compiling |
| `x86_64-windows-gnu` | Builds a Windows desktop runtime; keep its bundled DLLs |
| `aarch64-macos` | Uses Xcode's SDK on a Mac; elsewhere requires a macOS SDK through `--sysroot` |
| `wasm32-emscripten` | Automatic emsdk/WebGPU-port setup; packaged assets preload into the browser; no editor |
| `aarch64-linux-android.35` | Test-signed APK; automatic Android SDK/NDK/JDK setup on Linux x86-64 and macOS hosts |

Automatic Web/Android setup requires Python 3.12+. It reuses configured SDKs or caches
pinned official distributions in `$XDG_CACHE_HOME/eggy/sdks` (default
`~/.cache/eggy/sdks`), `~/Library/Caches/Eggy/SDKs` on macOS, or
`%LOCALAPPDATA%/Eggy/SDKs` on Windows (Web only). Starting an Android export accepts
Google's Android SDK licenses. SDK downloads and installation errors appear in build output.

The CLI exposes no SDK flags: set `EMSDK`, `ANDROID_HOME`/`ANDROID_SDK_ROOT` and
`JAVA_HOME`/`JDK_HOME` to reuse installed tools. Web also checks `~/emsdk`.
Eggy's own checkout accepts `-Demsdk` and `-Dandroid-sdk` overrides.
macOS builds on a Mac use the SDK `xcrun` reports. Elsewhere they require `--sysroot`
(or `-Dmacos-sdk` in Eggy's own checkout) and default to `~/SDKs`; that SDK is not downloaded.
See [Android and Web export details](../how-to/build-and-export.md#export-for-web-or-android).
See [Feature support](feature-support.md#capability-support) before choosing a web target.
