# Repository Guidelines

## Project Structure

Eggy is a Zig 0.17 game engine that games use as a package: they `zig fetch` it, call `addGame` from their `build.zig`, and `@import("eggy")`. It publishes three modules:

- `src/core/` (`eggy`, every platform): the engine games and plugins import. `app.zig` owns SDL, the window and `Graphics`; `graphics.zig` renders through Vitellus (`Graphics` owns the device and the main window's `Surface`, `addSurface` gives other windows theirs); `viewport3d.zig` draws the scene in HDR, graded by `scene_post.zig` with `post_process.zig`'s settings, across the window (`Graphics.drawScene`) or offscreen for a panel (`scene_texture.zig`); `plugins.zig` defines and runs the plugin hooks; `entry.zig` is the SDL main callbacks and fatal-error reporting, `log/` the desktop log and crash report, `process_init.zig` the `std.process.Init` handed to `App`.
- `src/runtime/` (`eggy_runtime`, every platform including the web): `Runtime(project)` runs a game and its plugins.
- `src/editor/` (`eggy_editor`, desktop only; never add it to the web build): `Editor(project)` runs a game with Weeoui tooling over it. Find a feature by its file name: `workspace.zig` (windows, dock, title bar), `workspace_tabs.zig`/`tab_*.zig`/`scene_tabs.zig` (tabs), `scene_view/` and `scene_2d/` (Scene panels, gizmo, 2D handles, tile brush), `entities/` (Hierarchy, Inspector, multi-select), `assets/` (Assets panel, file operations, descriptors), `asset_preview.zig`, `ui_designer/`, `export/`, `plugin_manager/` (Edit > Plugins, installs, auto-update), `projects/` (New/Open Project, the build job, engines, upgrades), `preferences/`, `hot_reload/`, `crash_recovery.zig` with `recovery_prompt.zig`.

Feature notes that the code doesn't make obvious:

- `resources/template/` is the new-project template (placeholders `eggy_template_name`, `eggy_template_title`, the fingerprint and `eggy_template_engine`; keep it valid Zig). The build packs it into `zig-out/resources/template.tar` and Eggy's package into `eggy.tar` (`src/build/tar.zig`); new projects build against `eggy.tar` unpacked into the data folder's `engines/<hash>`.
- A project's `eggy.zon` holds its Eggy settings (`src/core/project.zig`); `.plugins` lists installed plugins, which `addGame` builds in (`src/build/game_plugins.zig`), with the modules their manifests name in `.libraries`; every module a game builds with gets Eggy's Vitellus, Weeoui, Clutch and Eggenvector (`src/build/shared_libraries.zig`). Dev plugins are left out with `-Ddev-plugins=false`, as `zig build export` does.
- Assets: `src/core/assets/` (`eggy_assets`) stays free of the engine so tools can use it. Every file and folder in `resources/` has a `<name>.eggy` descriptor that moves with it (`src/editor/assets/descriptors.zig`, `file_ops.zig`). Models and images import through the `eggy_assimp` shared library (`src/model_import/`). `addGame` packages resources into `<prefix>/data/` named by descriptor id, with `data/manifest.zon` (`src/build/resources.zig`).
- Hot reload: the editor loads the game from a shared library (`<name>_game`, `src/editor/hot_reload/library.zig`) and swaps it when rebuilt. Only C-callable functions cross (`game_api.zig`); Eggy's types cross as pointers, so the editor and library must be built from the same Eggy, and the editor reloads itself when Eggy changed. Every typed component step runs in the game library. Game-made audio voices are ended (`App.resetWorld`) before a reload unloads their code.
- Rebuilds: refocusing rebuilds only after `source_stamp.zig` sees a change. For a linked Eggy checkout, `projects/eggy_update.zig` measures breaking commits (`!`, `BREAKING CHANGE:`) and semver, and `eggy_update_prompt.zig` asks before rebuilding onto them.
- Plugins: a plugin's folder has an `eggy.zon` with a `.plugin` section and a `README.md` (`src/core/plugin_manifest.zig`). `plugins/` holds the built-in ones (Git, Frame Stats, Project Stats, Android), published by `src/build/builtin_plugins.zig`; their `eggy.zon` names Eggy's fingerprint and `.package = "eggy"`. Preference keys come from `addGame` (`plugin_keys`), not `@typeName`; plugin preferences are per project, and `addGame` bakes them into the runtime only.
- Dev console (`src/core/dev_console/`): Buzz is built from its sources by `src/build/buzz.zig`, never through Buzz's own build.zig, with its natives' `export`s made private; on the web and Android it is a stub. Weeoui moves focus on Tab before a frame, so hosts hand Tab to `Prompt.takeTab` at the event.
- Shaders: a project `.slang` does `#include "eggy.slang"` (bare `"eggy"` still builds); `src/core/shaders/compose.zig` inlines `eggy.slang` into the wrapper for its role (`post_pass.slang` or `mesh.slang`). For code editors, `src/editor/slang_search_path.zig` writes the library to `.eggy/shaders/eggy.slang` and adds its absolute folder to `.vscode/settings.json` (slangd takes neither relative paths nor `${workspaceFolder}`).

`addGame` generates an `eggy_project` module and compiles `src/runtime/main.zig` against it; this repo builds `eggy_runtime` and `eggy_editor` from an empty project the same way. A package's `src/main.zig` is a game (`addGame`) and `src/root.zig` a plugin (`addPlugin`); both must request eggy with identical arguments (`eggyDependency`), so give neither extra eggy options.

Code both executables need belongs in `eggy`, free of editor-only dependencies. The game is the first plugin: keep game and plugin hooks one interface, and document any new hook in `plugins.zig` and `docs/docs/reference/plugin-hooks.md`.

## Submodules

`build.zig.zon` pins Vitellus, weeoui, humpty and clutch by git URL and commit; `src/<name>` are submodules for local work (`--fork=src/<name>`). Commit and push in their own repositories, re-pin with `zig fetch --save=<name> git+https://github.com/eggyengine/<name>#<commit>`, and point the submodule at the same commit. weeoui must pin Eggy's Vitellus commit, and humpty Eggy's clutch package hash, or forks fail with duplicate packages.

## README Files

Every `README.md` here and in submodules is off limits to agents, except the pull request review note below. Change one only when a human explicitly asks, and only what they asked; never as a side effect. Document new work in code comments or this file instead, and mention that the README may need a human's update. When asked, keep it short and written for users: no changelogs, implementation details or status notes.

## Documentation

`docs/` is the Docusaurus site (`.github/workflows/docs.yml` publishes it). Guides go in `docs/docs/guides/`, written for people making games with Eggy. In `docs/`: `npm ci`, `npm run start` to preview, `npm run build` to check (broken links fail it).

## Commands

- `git submodule update --init --recursive` after cloning.
- `zig build all` (or `runtime`, `editor`) builds; `zig build run` launches the editor, `zig build run-runtime` the runtime.
- `zig build test` runs every test; `test-core`, `test-runtime`, `test-editor` one part's. `EGGY_GPU_TEST=1` adds the GPU tests.
- Add `--fork=src/vitellus --fork=src/weeoui --fork=src/humpty --fork=src/clutch` to build against local submodules.
- `zig build update-submodules` fetches submodule branches; review pointers before committing.
- `scripts/get-started.sh` / `get-started.ps1` set up a new game from the template.

## Coding Style

Run `zig fmt` on changed files. `PascalCase` types, `camelCase` functions, four-space indent. Keep platform code behind target checks; don't add an unconditional SDL dependency to Vitellus.

- Make the smallest complete change: reuse before writing, no speculative options or wrappers, and finish callers, tests, docs and build files. Mark a known limit as `// ponytail: <the limit>, <when to upgrade>`.
- Organize by feature: one feature per file, stated in its `//!` comment in one sentence. Don't grow `app.zig`, `graphics.zig`, `editor.zig`, `runtime.zig`, `root.zig` or `build.zig` into catch-alls; `root.zig` holds only docs, re-exports and the test block. A multi-file feature gets a directory with an entry file of the same name.
- Dependencies point one way (`editor`, `runtime` → `core`), with no cycles between feature files. Keep public surfaces small, with `///` contracts.
- Name for meaning, with units where ambiguous (`time_ms`). Prefer enums and tagged unions to bool flags. Validate at boundaries.
- Keep control flow straight: steps in order, guard clauses, `errdefer` visible, no swallowed errors.
- Give each meaningful block one short comment above it saying why; no narration. Update comments with behaviour.
- No subheaders: don't break editor panels, docs guides or messages into titled sections or bold run-in labels. Group with spacing and plain sentences; add a heading only when the content is long enough to need navigating.

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
