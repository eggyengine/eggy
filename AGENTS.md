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

## Testing Guidelines

Place small Zig `test "behavior"` blocks beside the code they exercise. Run `zig build test` for code changes and `zig build run` when changing windowing or graphics. For visual changes, check the desktop window when available. There is no repository-wide coverage threshold.

## Commit & Pull Request Guidelines

Recent commits use short, action-oriented subjects, for example `Supply SDL adapter from Eggy`. Keep each commit focused. Pull requests should describe the behavior changed, list the commands run, link an issue when applicable, and include a screenshot or recording for visible rendering changes. Call out submodule revision changes explicitly.
