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

File > Export opens the editor workflow and asks for a scene when one is needed.
From the package directory, the equivalent build step is:

```sh
zig build export
```

The step builds a ReleaseFast runtime and packages resources and libraries. `-Dtarget`
selects a platform; ordinary builds also accept `-Doptimize`, but export uses
ReleaseFast regardless of the current debug build.

For interactive terminal export, run `eggy_editor export`. It lists scenes and common
target triples. To skip prompts, supply the answers:

```sh
eggy_editor export --project ./space_game --scene resources/scene/main.scene.zon --target native --non-interactive
```

The CLI leaves the saved default scene unchanged. The GUI export dialog saves its scene
selection. Target SDKs must already be installed; see
[Targets and SDKs](../reference/editor-cli.md#targets-and-sdks).

### Distribute the whole export

The default output is `zig-out/export/<name>-<target>/` and a ZIP beside it. Ship the
directory or archive, including `data/` and shared libraries. Copying just the executable
loses assets and runtime dependencies.

Keep the installed `bin/` and `lib/` layout intact. Desktop distributions include
shared SDL3; Windows DLLs are installed beside the executable. Browser builds have no
editor and the default browser resource provider is unavailable, so check
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
