# Repository Guidelines

## Project Structure

Eggy is a Zig 0.17 game engine that games use as a package: they `zig fetch` it, call `addGame` from their `build.zig`, and `@import("eggy")`. It publishes three modules:

- `src/core/` (`eggy`, every platform): the engine games and plugins import. `app.zig` owns SDL, the window and `Graphics`; `graphics.zig` renders through Vitellus (`Graphics` owns the device and the main window's `Surface`, `addSurface` gives other windows theirs); `viewport3d.zig` draws the scene in HDR, graded by `scene_post.zig` with `post_process.zig`'s settings, across the window (`Graphics.drawScene`) or offscreen for a panel (`scene_texture.zig`); `plugins.zig` defines and runs the plugin hooks; `entry.zig` is the SDL main callbacks and fatal-error reporting, `log/` the desktop log and crash report, `process_init.zig` the `std.process.Init` handed to `App`.
- `src/runtime/` (`eggy_runtime`, every platform including the web): `Runtime(project)` runs a game and its plugins.
- `src/editor/` (`eggy_editor`, desktop only; never add it to the web build): `Editor(project)` runs a game with Weeoui tooling over it. Find a feature by its file name: `workspace.zig` (windows, dock, title bar), `workspace_tabs.zig`/`tab_*.zig`/`scene_tabs.zig` (tabs), `scene_view/` and `scene_2d/` (Scene panels, gizmo, 2D handles, tile brush), `entities/` (Hierarchy, Inspector, multi-select), `assets/` (Assets panel, file operations, descriptors), `asset_preview.zig`, `ui_designer/`, `export/`, `plugin_manager/` (Edit > Plugins, installs, auto-update), `projects/` (New/Open Project, the build job, engines, upgrades), `build_progress.zig` (the build view the loading screen and the hot-reload Build window share), `preferences/` (Edit > Settings, with `project_settings.zig`), `hot_reload/`, `crash_recovery.zig` with `recovery_prompt.zig`.

Feature notes that the code doesn't make obvious:

- `resources/template/` is the new-project template (placeholders `eggy_template_name`, `eggy_template_title`, the fingerprint and `eggy_template_engine`; keep it valid Zig). The build packs it into `zig-out/resources/template.tar` and Eggy's package into `eggy.tar` (`src/build/tar.zig`); new projects build against `eggy.tar` unpacked into the data folder's `engines/<hash>`.
- A project's `eggy.zon` holds its Eggy settings (`src/core/project.zig`); `.plugins` lists installed plugins, which `addGame` builds in (`src/build/game_plugins.zig`), with the modules their manifests name in `.libraries`; every module a game builds with gets Eggy's Vitellus, Weeoui, Clutch, Eggenvector and Humpty (`src/build/shared_libraries.zig`). Dev plugins are left out with `-Ddev-plugins=false`, as `zig build export` does.
- Assets: `src/core/assets/` (`eggy_assets`) stays free of the engine so tools can use it. Every file and folder in `resources/` has a `<name>.eggy` descriptor that moves with it (`src/editor/assets/descriptors.zig`, `file_ops.zig`). Models and images import through the `eggy_assimp` shared library (`src/model_import/`). `addGame` packages resources into `<prefix>/data/` named by descriptor id, with `data/manifest.zon` (`src/build/resources.zig`).
- Hot reload: the editor loads the game from a shared library (`<name>_game`, `src/editor/hot_reload/library.zig`) and swaps it when rebuilt. Only C-callable functions cross (`game_api.zig`); Eggy's types cross as pointers, so the editor and library must be built from the same Eggy, and the editor reloads itself when Eggy changed. Every typed component step runs in the game library. The editor compiles no asset catalog: it takes the library's (`eggy.asset_catalog`) on load, so asset changes rebuild only the library. Builds the editor starts share `<data folder>/.zig-cache` (`projects/job.zig`). Game-made audio voices are ended (`App.resetWorld`) before a reload unloads their code.
- Splash: a project editor starts itself again with `--splash` (`src/editor/splash/`), a process drawn with SDL's 2D renderer so it is up at once and keeps moving while the editor's main thread works. The editor sends it each startup step down its stdin and closes it after the first frame; until then `eggy.fatal_dialog.presenter` shows fatal errors on it.
- Launcher: Eggy's own `eggy_editor`, the one the nightly ships, is the launcher alone (`launcher_main.zig`, `launcher_app.zig`): `projects/launcher.zig` over a hidden window that owns the GPU, plus New/Open Project and the CLI, without `Editor(project)`, `App` or a game library. It lists `projects/recent.zig`'s `recent_projects.zon` in the data folder, which every project editor tops up when it opens. The full editor still compiles against the empty project as `zig build check-editor` (part of `test`); `-Dapi-demo` builds it in place of the launcher.
- Inspector tooltips: Zig can't reflect `///`, so `src/build/field_docs.zig` parses Eggy's, Humpty's, the game's and its plugins' sources while configuring and hands the game library an `eggy_field_docs` module of `@"Type.field"` strings; `library.zig` puts them on each field's `Part.doc` (nested struct fields by their `Part.type_name`).
- Settings: pages in sidebar groups (this computer, the project, its plugins), searched by row. `eggy.setting_rows` marks a row that differs from its baseline and resets it; the graphics form takes that baseline (`Options.baseline`), and a preferences struct's `pub const groups` splits its fields into cards.
- Scene watching: `src/editor/file_watch.zig` watches `resources/` (inotify on Linux, `ReadDirectoryChangesW` on Windows, FSEvents on macOS); `Editor.pickUpSceneChanges` polls it each frame, skips the editor's own writes by `OpenScene.changedOutside`, reopens the open scene as an undo step unless it has unsaved changes, and remakes scene instances.
- Rebuilds: refocusing rebuilds only after `source_stamp.zig` sees a change. For a linked Eggy checkout, `projects/eggy_update.zig` measures breaking commits (`!`, `BREAKING CHANGE:`) and semver, and `eggy_update_prompt.zig` asks before rebuilding onto them.
- Plugins: a plugin's folder has an `eggy.zon` with a `.plugin` section and a `README.md` (`src/core/plugin_manifest.zig`). `plugins/` holds the built-in ones (Git, Frame Stats, Project Stats, Player Controller, Android); new projects install Player Controller through `resources/template/eggy.zon`, published by `src/build/builtin_plugins.zig`; their `eggy.zon` names Eggy's fingerprint and `.package = "eggy"`. Preference keys come from `addGame` (`plugin_keys`), not `@typeName`; plugin preferences are per project, and `addGame` bakes them into the runtime only.
- Dev console (`src/core/dev_console/`): Buzz is built from its sources by `src/build/buzz.zig`, never through Buzz's own build.zig, with its natives' `export`s made private; on the web and Android it is a stub. Weeoui moves focus on Tab before a frame, so hosts hand Tab to `Prompt.takeTab` at the event.
- GPU memory: Vitellus sub-allocates through VMA (`src/vitellus/src/backends/vulkan/vma.cpp`) and D3D12MA (`dx12/d3d12ma.cpp`), each behind a small C shim; render targets get their own allocation. Compiled shaders are kept in `<data folder>/shader-cache/` (`src/core/compiled_shader_cache.zig`, `vit.ShaderDiskCache`): DX12's SPIR-V→DXIL translations and the editor's Slang output, keyed by a hash of source and compiler version.
- Cutscenes: an entity whose `Animator` plays an authored clip; tracks may name any scene entity (`/bee`) and set cameras, UI text and visibility, camera cuts (a `camera` track whose keys name shot cameras, blended by `src/core/camera_cuts.zig`, which hosts use in place of `camera.find`), sprite frames, sounds and `event`s (the `animationEvent` hook, `src/core/animation.zig`). `Animator.takes_over` makes it hold input and hide unanimated screens, and `Animator.letterbox` adds bars (`src/core/cutscene.zig`, hosts call `app.cutscene.event`/`draw`). The Animation panel keys them, with Record (`src/editor/animation_dock/`), and the Render menu renders one offscreen at a fixed step into the Render window, as Blender does (`src/core/film.zig`, `src/editor/film/`, PNG frames and `ffmpeg` when installed).
- Physics: humpty (`src/humpty`) simulates in 2D or 3D, `f32` or `f64` (`Physics(dim, T)`), and never imports Eggy; its `ecs.zig` runs it as a clutch plugin (components, `PhysicsStage` after `.Update`, a `Deinit` teardown) over a host type, and `debug_draw.zig` hands wireframes to any `line(from, to, color)` sink. `src/core/physics.zig` is that host (Transform with parents, Time, `Mesh` as collider shapes) and lists the components `plugins.zig` appends to `builtin_components`; `App.updateWorld` calls `physics.install` once per world, taking the dimension from the scene root's `SceneRoot.dimension` and the precision from `eggy.zon`'s `.physics` (Edit > Settings > Physics, `App.physics_precision`). The root (`src/core/scene_root.zig`) also carries `PhysicsSettings`; `scene_file.zig` adds one to scenes without it (2D when made from a 2D tab), and the Hierarchy lists it first under the scene's name, never deleted, renamed or moved; the Inspector shows it as the scene's settings, with no Add Component. Collider wireframes: the editor draws the selection's through the `draw_colliders` game API, and `App.physics_debug` (console `physics debug on`, Buzz `physicsDebug`) draws every collider and contact. Guide: `docs/docs/physics/use-physics.md`; standalone reference: `docs/docs/physics/humpty.md`.
- Shaders: a project `.slang` does `#include "eggy.slang"` (bare `"eggy"` still builds); `src/core/shaders/compose.zig` inlines `eggy.slang` into the wrapper for its role (`post_pass.slang` or `mesh.slang`). For code editors, `src/editor/slang_search_path.zig` writes the library to `.eggy/shaders/eggy.slang` and adds its absolute folder to `.vscode/settings.json` (slangd takes neither relative paths nor `${workspaceFolder}`).

`addGame` generates an `eggy_project` module and compiles `src/runtime/main.zig` against it; this repo builds `eggy_runtime` from an empty project the same way, and `eggy_editor` as the launcher. A package's `src/main.zig` is a game (`addGame`) and `src/root.zig` a plugin (`addPlugin`); both must request eggy with identical arguments (`eggyDependency`), so give neither extra eggy options.

Code both executables need belongs in `eggy`, free of editor-only dependencies. The game is the first plugin: keep game and plugin hooks one interface, and document any new hook in `plugins.zig` and `docs/docs/reference/plugin-hooks.md`.

## Submodules

`build.zig.zon` pins Vitellus, weeoui, humpty and clutch by git URL and commit; `src/<name>` are submodules for local work (`--fork=src/<name>`). Commit and push in their own repositories, re-pin with `zig fetch --save=<name> git+https://github.com/eggyengine/<name>#<commit>`, and point the submodule at the same commit. weeoui must pin Eggy's Vitellus commit, and humpty Eggy's clutch package hash, or forks fail with duplicate packages.

## README Files

Every `README.md` here and in submodules is off limits to agents, except the pull request review note below. Change one only when a human explicitly asks, and only what they asked; never as a side effect. Document new work in code comments or this file instead, and mention that the README may need a human's update. When asked, keep it short and written for users: no changelogs, implementation details or status notes.

## Documentation

`docs/` is the Docusaurus site (`.github/workflows/docs.yml` publishes it), written for people making games with Eggy. Pages are grouped by topic, one folder each under `docs/docs/` (`getting-started`, `editor`, `scenes`, `rendering`, `animation`, `physics`, `input`, `ui`, `plugins`, `game-code`, `scripting`, `shipping`, `reference`), with a `_category_.json` for its sidebar label, order and card description; put a new page in its feature's folder with `sidebar_position` and `description`. A page's URL is its path, so moving one needs a line in `docs/redirects.js`. In `docs/`: `npm ci`, `npm run start` to preview, `npm run build` to check (broken links and anchors fail it).

## Commands

- `git submodule update --init --recursive` after cloning.
- `zig build all` (or `runtime`, `editor`) builds; `zig build run` launches the launcher (a game's `zig build run`, its editor), `zig build run-runtime` the runtime.
- `zig build test` runs every test; `test-core`, `test-runtime`, `test-editor` one part's. `EGGY_GPU_TEST=1` adds the GPU tests.
- Add `--fork=src/vitellus --fork=src/weeoui --fork=src/humpty --fork=src/clutch` to build against local submodules.
- `zig build update-submodules` fetches submodule branches; review pointers before committing.
- `scripts/get-started.sh` / `get-started.ps1` install Zig and the launcher from GitHub Releases (the latest release or the `nightly` prerelease, which `.github/workflows/nightly.yml` publishes), for the user or system-wide.

## Coding Style

Run `zig fmt` on changed files. `PascalCase` types, `camelCase` functions, four-space indent. Keep platform code behind target checks; don't add an unconditional SDL dependency to Vitellus.

- Make the smallest complete change: reuse before writing, no speculative options or wrappers, and finish callers, tests, docs and build files. Mark a known limit as `// ponytail: <the limit>, <when to upgrade>`.
- Write every module and function to be reused: one job behind a small `pub` surface that takes what it needs as parameters (allocator, `Io`, paths, fonts, theme) instead of reaching into `App`, `Editor` or other host state, so another feature, plugin or tool can call it unchanged. Before writing a helper, look for one (`page_style.zig`, `icon.zig`, `eggy.assets`, Weeoui); when one nearly fits, generalize it in place rather than copying it, and when callers span modules, move it down to the lowest one they all import (`core` before `editor`, Weeoui or Vitellus for what isn't Eggy's). No near-duplicate code: a second copy is a cue to extract.
- Organize by feature: one feature per file, stated in its `//!` comment in one sentence. Don't grow `app.zig`, `graphics.zig`, `editor.zig`, `runtime.zig`, `root.zig` or `build.zig` into catch-alls; `root.zig` holds only docs, re-exports and the test block. A multi-file feature gets a directory with an entry file of the same name.
- Dependencies point one way (`editor`, `runtime` → `core`), with no cycles between feature files. Keep public surfaces small, with `///` contracts.
- Name for meaning, with units where ambiguous (`time_ms`). Prefer enums and tagged unions to bool flags. Validate at boundaries.
- Keep control flow straight: steps in order, guard clauses, `errdefer` visible, no swallowed errors.
- Give each meaningful block one short comment above it saying why; no narration. Update comments with behaviour.
- No subheaders: don't break editor panels, docs guides or messages into titled sections or bold run-in labels. Group with spacing and plain sentences; add a heading only when the content is long enough to need navigating.
- No filler text in the UI: no lede under a page title, no heading that repeats the tab, panel or sidebar item it sits in, no hint on how to use a control ("Drag to turn it"), no line on how long something takes or what happens behind the scenes, and no row note that restates its title. Say something only when people can't tell it from the control: a constraint ("Lower case, digits and _"), a consequence ("The game may not start on older processors") or a state ("No plugins installed yet"), in one short sentence. Errors say what failed and, when it isn't obvious, what to do.

## Testing

Put `test "behavior"` blocks beside the code, named for what they check, with decisive inputs visible. Run `zig build test` for code changes; for windowing or graphics, also run the editor and runtime and look at the window.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`, where type is `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`, `chore` or `release`; scope is the area (`core`, `editor`, `graphics`, `weeoui`…); the summary is imperative, lower case, no period, about 72 characters at most. Mark breaks with `!` and a `BREAKING CHANGE:` body. Use the body for reasoning. Keep commits focused, and bump each submodule pointer in its own commit (`build(weeoui): bump to 1a2b3c4`).

## Pull Requests

Describe the behaviour changed, list the commands run, link an issue when there is one, add a screenshot for visible rendering changes, and call out submodule bumps.

**Agents must write this note at the very top of the root `README.md`, as a commit on the pull request's branch, for every pull request they open** (the description alone does not count):

```markdown
> [!NOTE]
> By removing this, you prove that the code has been reviewed by human.
```

Agents must never remove, reword or hide it, nor open a pull request without it. Only a human reviewer removes it.
