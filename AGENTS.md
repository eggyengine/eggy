# Repository Guidelines

## Project Structure & Module Organization

Eggy is a Zig 0.16 game engine that games use as a package: they `zig fetch` it, call `addGame` from their `build.zig`, and `@import("eggy")`. It publishes three modules:

- `src/core/` (`eggy`, every platform): the engine games and plugins import. `app.zig` owns SDL, the window and `Graphics`; `graphics.zig` renders through Vitellus and splits each frame into `beginFrame`/`endFrame`; `viewport3d.zig` draws the 3D scene; `plugins.zig` defines the plugin hooks and runs them; `entry.zig` provides the SDL main callbacks and fatal-error reporting both executables use. Shader sources live in `src/core/shaders/`.
- `src/runtime/` (`eggy_runtime`, every platform including the web): `Runtime(project)` runs a game and its plugins.
- `src/editor/` (`eggy_editor`, desktop only): `Editor(project)` runs a game with Weeoui tooling drawn over it. Never add it to the web build.
- `src/resources/` (`eggy_template`): the new-project template in `template/`, and `template.zig`, which embeds it and fills in its placeholders (`eggy_template_name`, the fingerprint, and the `eggy_template_engine` dependency) for the editor. Keep the template valid Zig as written; when you add a file to it, add it to `template.files`.

`build.zig`'s public `addGame` builds a game: it generates an `eggy_project` module (the game's name and plugin types) and compiles `src/runtime/main.zig` and `src/editor/main.zig` against it. This repo builds its own sandbox game from `examples/sandbox/` through the same path, so keep the sandbox working as the reference game.

An Eggy package follows Zig's layout: `src/main.zig` is a game (`pub const Game`, built with `addGame`) and `src/root.zig` is a plugin or library (`pub const Plugin`, published with `addPlugin`). `addGame` and `addPlugin` must request eggy with identical arguments (see `eggyDependency`) so a package's game and plugin share one engine; do not give either helper extra eggy options.

Code both executables need belongs in `eggy`; keep it free of editor-only dependencies. The game is the first plugin: keep game and plugin hooks one interface, and document any new hook in `plugins.zig`. Plugins are static (compiled in through `addGame`) for now.

`build.zig.zon` pins Vitellus, weeoui, humpty and clutch by git URL and commit, because Zig's package manager does not fetch submodules. `src/vitellus`, `src/humpty`, `src/weeoui` and `src/clutch` are Git submodules for local work: build against them with `--fork=src/<name>`. Commit and push changes in their own repositories, then re-pin Eggy with `zig fetch --save=<name> git+https://github.com/eggyengine/<name>#<commit>` and update the submodule pointer to the same commit. weeoui must pin the same Vitellus commit as Eggy, or `--fork=src/vitellus` fails with two Vitellus packages. Likewise humpty must pin clutch with the same package hash as Eggy (Zig identifies packages by hash, so commits that differ only outside clutch's `.paths` still match): humpty's physics runs on the world `App` owns, re-exported as `eggy.ecs`.

## README Files

Every `README.md` in this repository and its submodules is off limits to agents. Do not create, edit, reformat, or delete one unless a human explicitly asks for that change, and then change only what they asked for. Never update a README as a side effect of other work, even to document something you just built: put that in code comments, doc comments, or this file instead, and mention in your reply that the README may need a human's update.

When a human does ask for a README change, keep it short and clean. Write for the people who use the project. No changelogs, no implementation details, no status notes, and no repeated content.

## Build, Test, and Development Commands

- `git submodule update --init --recursive`: populate the submodule checkouts after cloning.
- `zig build all`: build the sandbox's runtime and editor (`sandbox`, `sandbox_editor`) into `zig-out/bin/` without running them.
- `zig build runtime` / `zig build editor`: build one executable without running it.
- `zig build run`: build and launch the editor. On the web, where there is no editor, it opens the runtime in a browser.
- `zig build run-runtime`: build and launch the runtime.
- `zig build test`: run every test. `zig build test-core`, `test-runtime` and `test-editor` run one part's tests.
- `zig build test-template`: render the template into a new project and build it against this checkout. Slow (it builds eggy from scratch), so it is not part of `test`; run it after changing the template, `addGame`, or the plugin hooks.
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
