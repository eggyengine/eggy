# Repository Guidelines

## Project Structure & Module Organization

Eggy is a Zig 0.16 game engine that games use as a package: they `zig fetch` it, call `addGame` from their `build.zig`, and `@import("eggy")`. It publishes three modules:

- `src/core/` (`eggy`, every platform): the engine games and plugins import. `app.zig` owns SDL, the window and `Graphics`; `graphics.zig` renders through Vitellus: `Graphics` owns the device and the main window's `Surface` (a swapchain and its frames in flight, each split into `beginFrame`/`endFrame`), and `addSurface` gives other windows their own; `viewport3d.zig` draws the 3D scene, which `Graphics.drawScene` puts across the window (the runtime) and `scene_texture.zig` renders offscreen for a panel (the editor's Scene); `plugins.zig` defines the plugin hooks and runs them; `entry.zig` provides the SDL main callbacks and fatal-error reporting both executables use. Shader sources live in `src/core/shaders/`.
- `src/runtime/` (`eggy_runtime`, every platform including the web): `Runtime(project)` runs a game and its plugins.
- `src/editor/` (`eggy_editor`, desktop only): `Editor(project)` runs a game with Weeoui tooling drawn over it; `workspace.zig` builds, draws and routes input for each window (the drawn title bar over the dock, and each pop-out), `menus.zig` holds the menus, `panels.zig` what each panel shows, `popout.zig` the OS window a panel pops out into, `tool_window.zig` the editor's own small windows, `terminal_view.zig` a terminal-looking output box, `file_manager.zig` File > Open Project Folder, `devtools_window.zig` Help > DevTools, `hit_test.zig` which element is under a point, `play_button.zig` and `reload_button.zig` the title bar's buttons, `window_placement.zig` the window's place carried across Reload, `build_window.zig` the Build progress window shown (with the editor frozen) while the project's editor rebuilds, and `icon.zig` the window icon from `resources/icon.svg`. `projects/` is File > New Project and Open Project: the wizard, the background job that unpacks the engine and writes the template (new projects) or reads `eggy.zon` and repairs a missing engine path (opened ones), then builds the project's editor (`job.zig`), which unpacked Eggy a project builds against, which is newest and which checkout is being developed (`engine.zig`, recorded in `engines/latest` and `engines/developer`), what the open project could move to (`upgrades.zig`: File > Upgrade Editor, and with Shift held Link Developer Eggy and Open Project with Developer Eggy), a stamp of its sources so refocusing rebuilds only after a change (`source_stamp.zig`), and the loading screen; on success it opens `<project>/zig-out/bin/<name>_editor --project <dir>` and quits. The main window's status bar shows the open project. Never add it to the web build.
- `resources/`: files the editor ships with, installed to `zig-out/resources/`. `resources/template/` is the new-project template, with placeholders `eggy_template_name`, `eggy_template_title`, the fingerprint, and the `eggy_template_engine` dependency; keep it valid Zig as written. The build packs it into `zig-out/resources/template.tar`, and Eggy's own package (build.zig.zon's `.paths`, less the submodules) into `zig-out/resources/eggy.tar`, with `src/build/tar.zig`. New projects build against `eggy.tar`, unpacked once per version into the user's data folder (`engines/<hash>`) and referenced by relative path.
- A project's `eggy.zon` (beside `build.zig.zon`) holds its settings for Eggy; `src/core/project.zig` reads it.
- Components: a plugin lists its ECS component types in `components`; `src/core/components.zig` describes them and reads and writes their fields as ZON, and `plugins.Set.Components` collects them. In the editor every typed step runs in the game's library (component types and clutch's type numbering live there) behind `game_api.zig`; the editor itself walks entities and the parent tree. `src/editor/entities/` holds the Hierarchy page and the Inspector's entity view.
- Preferences: a plugin's `Preferences` struct is its manifest (`src/core/preferences.zig`), read with `app.preferences(T)`. Values layer defaults, the user's global folder (Eggy's data folder; the editor's own `preferences.zon` only: plugin preferences are per project) and the project's `.eggy/` (`preferences.zon` for the editor's, `plugins/<key>.zon` per plugin, and `plugins.zon`, which the editor rewrites). Keys come from `addGame` (`plugin_keys`: `game`, then each plugin module's published name), not `@typeName`, which names types after their file. `addGame` bakes `.eggy/plugins/*.zon` into the runtime's project module only, so preference edits don't rebuild the editor's game library. `src/editor/preferences/` holds the files and the Edit > Preferences window.

`build.zig`'s public `addGame` builds a game: it generates an `eggy_project` module (the game's name and plugin types) and compiles `src/runtime/main.zig` against it. The editor compiles `src/editor/main.zig` against a project module with the name only, and loads the game and its plugins from a shared library (`<name>_game`, installed beside it, rooted at `src/editor/hot_reload/library.zig`), which it swaps for a rebuilt one while running (`src/editor/hot_reload/`). Only C-callable functions cross that boundary (`game_api.zig`); Eggy's types cross as pointers, so the editor and library must be built from the same Eggy, and the editor reloads itself rather than swap when Eggy changed. This repo builds its own executables, `eggy_runtime` and `eggy_editor`, from an empty project through the same path; a game's runtime takes the game's name and its editor is `<name>_editor`.

An Eggy package follows Zig's layout: `src/main.zig` is a game (`pub const Game`, built with `addGame`) and `src/root.zig` is a plugin or library (`pub const Plugin`, published with `addPlugin`). `addGame` and `addPlugin` must request eggy with identical arguments (see `eggyDependency`) so a package's game and plugin share one engine; do not give either helper extra eggy options.

Code both executables need belongs in `eggy`; keep it free of editor-only dependencies. The game is the first plugin: keep game and plugin hooks one interface, and document any new hook in `plugins.zig` and in `docs/docs/guides/plugins.md`. Plugins are static (compiled in through `addGame`) for now.

`build.zig.zon` pins Vitellus, weeoui, humpty and clutch by git URL and commit, because Zig's package manager does not fetch submodules. `src/vitellus`, `src/humpty`, `src/weeoui` and `src/clutch` are Git submodules for local work: build against them with `--fork=src/<name>`. Commit and push changes in their own repositories, then re-pin Eggy with `zig fetch --save=<name> git+https://github.com/eggyengine/<name>#<commit>` and update the submodule pointer to the same commit. weeoui must pin the same Vitellus commit as Eggy, or `--fork=src/vitellus` fails with two Vitellus packages. Likewise humpty must pin clutch with the same package hash as Eggy (Zig identifies packages by hash, so commits that differ only outside clutch's `.paths` still match): humpty's physics runs on the world `App` owns, re-exported as `eggy.ecs`.

## README Files

Every `README.md` in this repository and its submodules is off limits to agents. Do not create, edit, reformat, or delete one unless a human explicitly asks for that change, and then change only what they asked for. Never update a README as a side effect of other work, even to document something you just built: put that in code comments, doc comments, or this file instead, and mention in your reply that the README may need a human's update.

When a human does ask for a README change, keep it short and clean. Write for the people who use the project. No changelogs, no implementation details, no status notes, and no repeated content.

## Documentation

`docs/` is the Docusaurus site, published to GitHub Pages by `.github/workflows/docs.yml`. Pages live in `docs/docs/`; guides go in `docs/docs/guides/`, which the sidebar shows as "Guides". Run `npm ci` then `npm run start` in `docs/` to preview, and `npm run build` to check it builds (broken links fail it). Write the guides for people making games with Eggy, not for people working on it.

## Build, Test, and Development Commands

- `git submodule update --init --recursive`: populate the submodule checkouts after cloning.
- `zig build all`: build `eggy_runtime` and `eggy_editor` into `zig-out/bin/` without running them.
- `zig build runtime` / `zig build editor`: build one executable without running it.
- `zig build run`: build and launch the editor. On the web, where there is no editor, it opens the runtime in a browser.
- `zig build run-runtime`: build and launch the runtime.
- `zig build test`: run every test. `zig build test-core`, `test-runtime` and `test-editor` run one part's tests.
- Add `--fork=src/vitellus --fork=src/weeoui --fork=src/humpty --fork=src/clutch` to any command to build against the local submodules instead of the pinned commits.
- `zig build update-submodules`: fetch the latest configured submodule branches. Review and commit changed pointers before sharing them.

## Coding Style & Naming Conventions

Run `zig fmt` on changed Zig files. Follow the existing four-space indentation, `PascalCase` types such as `Graphics`, and `camelCase` functions such as `syncSize`. Keep platform-specific code behind target checks. Vitellus core accepts generic window handles; Eggy wires in the SDL adapter in `build.zig`, so do not add an unconditional SDL dependency to Vitellus.

## Readable Code

Write code that a newcomer can follow without opening every helper. These rules apply to every change, including small ones.

**Make the smallest complete change.**

- Solve the whole task with the least new code. Reuse what the codebase, the standard library, or an existing dependency already provides before writing anything new.
- Do not add options, abstractions, wrappers, or "for later" code that the task does not need. Deleting code beats adding it.
- Finish everything the change touches: callers, tests, docs, and build files.
- Mark a known limitation where it lives: `// ponytail: <the limit>, <when to upgrade>`.

**Organize by feature.**

- Put code where its feature name says it is. Split a file when it mixes separate jobs, not when it reaches a line count. A long file with one concept is fine.
- No god files. A file owns one feature, and its `//!` comment says which in one sentence; if that sentence needs "and", split the file. Do not grow `app.zig`, `graphics.zig`, `editor.zig`, `runtime.zig`, `root.zig` or `build.zig` into catch-alls: they wire features together and delegate, and new behaviour goes in its own file beside them (as `scene_texture.zig` and `workspace.zig` do).
- Keep `root.zig` files to the module's doc comment, re-exports, and the `test` block that pulls in each file's tests. Logic lives in the feature files they export.
- When a feature grows several files, give it a directory named after it with a file of the same name as its entry point, for example `src/editor/panels/panels.zig`. Callers import that entry point, not the files behind it.
- Dependencies point one way: `editor` and `runtime` depend on `core`, never the reverse, and feature files in one module do not import each other in cycles. Pass what a file needs as parameters instead of reaching into another feature's internals.
- Keep each file's public surface small. Mark helpers private unless another file needs them, and expose the feature through a few types and functions with `///` contracts.
- Add a layer or helper only when it hides real detail or owns an invariant. Leave short, cohesive sequences inline.

**Name and type for meaning.**

- Name things after what they mean in the domain and what they do, including side effects. Avoid vague names such as `process` or `data`.
- Put units in names when they are ambiguous, for example `time_ms` or `extent_px`.
- Prefer enums and tagged unions over boolean mode flags and magic numbers.
- Validate input at boundaries and pass the validated values inward.

**Keep control flow straight.**

- Present a workflow's steps in execution order. Use guard clauses so the main path stays visible.
- Keep side effects, ordering constraints, and `errdefer` cleanup visible in the function that owns them.
- Do not swallow errors or turn a failure into success by accident.

### Block comments

Give each meaningful block of code a single short comment that states its purpose: why it is there, or what it achieves. Put it above the block. It is a heading, not a narration.

```zig
pub fn frame(self: *Graphics) !void {
    // Reuse this slot only once the GPU has finished the frame that last used it.
    const slot = &self.slots[self.slot];
    _ = try self.gpu_done.wait(slot.frame, null);
    try slot.commands.reset();

    // Record the scene into the acquired swapchain image.
    const acquired = try self.swapchain.acquireNextImage(slot.acquired);
    const cmd = try vit.CommandBuffer.init(slot.commands, .{});
    try self.preview.draw(cmd, acquired.view, ...);
    try cmd.finish();

    // Submit, then present once rendering signals `render_done`.
    try self.queue.submit(...);
    _ = try self.swapchain.present(&.{render_done});
}
```

- Keep each comment to one line where possible. Explain intent, invariants, and surprising ordering, not syntax.
- Do not comment every line or restate the code. If a block needs a long explanation, improve the names or structure first.
- Give non-trivial types and public functions a `///` doc comment that describes their role and contract: preconditions, side effects, and failure behaviour. Use `//!` at the top of a file to state the module's purpose.
- When behaviour changes, update its comments in the same commit.

## Testing Guidelines

Place small Zig `test "behavior"` blocks beside the code they exercise. Name each test after the behavior it checks, and keep its decisive inputs and expected outcomes visible in the test. Run `zig build test` for code changes and `zig build run` and `zig build run-runtime` when changing windowing or graphics. For visual changes, check the desktop window when available. There is no repository-wide coverage threshold.

## Commit Guidelines

Use [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`.

- **type**: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`, `chore`, or `release`.
- **scope**: the module or area touched, such as `core`, `runtime`, `editor`, `graphics`, `shaders`, `build`, `vitellus`, `weeoui`, or `humpty`. Omit it only when the change is genuinely repo-wide.
- **summary**: imperative, lower case, no trailing period, at most about 72 characters.
- Mark breaking changes with `!` after the scope, and explain the break in the body under `BREAKING CHANGE:`.
- Use the body for the reasoning behind the change, not a list of files.

```text
feat(graphics): resize the depth buffer with the swapchain
fix(game): stop the frame cap from delaying web builds
refactor(weeoui): split measure-and-place out of layout.zig
build(vitellus): replace dynlib.zig with better-dynlib
release(eggy): v0.2.0
```

Keep each commit focused on one change. When you bump a submodule pointer, name it in a commit of its own, for example `build(weeoui): bump to 1a2b3c4`.

## Pull Request Guidelines

Pull requests should describe the behavior changed, list the commands run, link an issue when applicable, and include a screenshot or recording for visible rendering changes. Call out submodule revision changes explicitly.

**Agents must put this note at the top of every pull request description they open:**

```markdown
> [!NOTE]
> By removing this, you prove that the code has been reviewed by human.
```

Agents must never remove, reword, or hide this note, and never open a pull request without it. Only a human reviewer removes it, once they have reviewed the code.
