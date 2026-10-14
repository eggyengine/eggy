# Repository Guidelines

## Project Structure & Module Organization

Eggy is a Zig 0.16 desktop application. `src/main.zig` handles SDL entry points, `src/game.zig` owns the window and game loop, `src/graphics.zig` renders through Vitellus, and `src/root.zig` exports the application module. Shader sources and compiled SPIR-V live together in `src/shaders/`. Android packaging and platform code live on the `android` branch. `src/vitellus`, `src/humpty`, and `src/weeoui` are Git submodules; commit changes in their own repositories before updating Eggy's submodule pointers.

## Build, Test, and Development Commands

- `git submodule update --init --recursive`: populate the pinned submodule revisions after cloning.
- `zig build`: build the desktop executable in `zig-out/bin/`.
- `zig build run`: build and launch the desktop application.
- `zig build test`: compile and run Eggy's workspace tests.
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

Place small Zig `test "behavior"` blocks beside the code they exercise. Name each test after the behavior it checks, and keep its decisive inputs and expected outcomes visible in the test. Run `zig build test` for code changes and `zig build run` when changing windowing or graphics. For visual changes, check the desktop window when available. There is no repository-wide coverage threshold.

## Commit Guidelines

Use [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`.

- **type**: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`, `chore`, or `release`.
- **scope**: the module or area touched, such as `graphics`, `game`, `shaders`, `build`, `vitellus`, `weeoui`, or `humpty`. Omit it only when the change is genuinely repo-wide.
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
