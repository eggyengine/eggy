# eggy

_eggy_ is a game engine written in Zig. it's built from a handful of in-house libraries, each living in its own repo:

- **[vitellus](https://github.com/eggyengine/vitellus)**: the rendering hardware interface (vulkan, dx12, webgpu)
- **[weeoui](https://github.com/eggyengine/weeoui)**: the immediate-mode UI, with docking panels and screen-reader support
- **[humpty](https://github.com/eggyengine/humpty)**: physics

eggy itself comes in three parts:

| module | what it is | platforms |
|---|---|---|
| `eggy` | the engine your game imports: window, renderer, scene, plugins | all, including the web |
| `eggy_runtime` | runs your game as players see it | all, including the web |
| `eggy_editor` | your game with editor tooling over it | desktop only |

## make a game
requires zig `0.16.0`

add eggy to your project:
```bash
zig fetch --save git+https://github.com/eggyengine/eggy
```

then in `build.zig`:
```zig
const std = @import("std");
const eggy = @import("eggy");

pub fn build(b: *std.Build) void {
    eggy.addGame(b, .{
        .name = "my_game",
        .game = b.createModule(.{ .root_source_file = b.path("src/game.zig") }),
    });
}
```

and your game, in `src/game.zig`:
```zig
const eggy = @import("eggy");

pub const Game = struct {
    frames: u64 = 0,

    pub fn update(self: *Game, app: *eggy.App) !void {
        _ = app;
        self.frames += 1;
    }

    pub fn editorUi(self: *Game, ui: *eggy.ui.Context) void {
        ui.label("Frames: {d}", .{self.frames});
    }
};
```

`zig build run` opens your game in the editor, and `zig build run-runtime` runs it on its own. `zig build all` builds `my_game` and `my_game_editor` into `zig-out/bin/`; with `-Dtarget=wasm32-emscripten`, `zig build run` opens it in a browser instead.

every hook is optional: `init`, `deinit`, `update`, `event` and `editorUi`. see [`plugins.zig`](src/core/plugins.zig) for their signatures, and [`examples/sandbox`](examples/sandbox) for a working game.

### plugins
a plugin uses the same hooks as your game, and runs after it each frame. it's a module that declares `pub const Plugin`:

```zig
const std = @import("std");
const eggy = @import("eggy");

pub const Plugin = struct {
    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Plugin {
        _ = gpa;
        _ = app;
        std.log.info("hello from a plugin", .{});
        return .{};
    }
};
```

plugins can live in your project, or come from their own package through `zig fetch`. hand them to `addGame` in the order they should run:
```zig
eggy.addGame(b, .{
    .name = "my_game",
    .game = b.createModule(.{ .root_source_file = b.path("src/game.zig") }),
    .plugins = &.{
        b.createModule(.{ .root_source_file = b.path("src/hello_plugin.zig") }),
        b.dependency("cool_plugin", .{}).module("cool_plugin"),
    },
});
```

`addGame` gives your game and each plugin `@import("eggy")`.

## work on eggy
```bash
git clone --recursive https://github.com/eggyengine/eggy
cd eggy
zig build run
```

this repo builds a sandbox game from [`examples/sandbox`](examples/sandbox), the same way `addGame` builds yours.

| command | what it does |
|---|---|
| `zig build all` | build `sandbox` and `sandbox_editor` into `zig-out/bin/` |
| `zig build runtime` / `zig build editor` | build just one of them |
| `zig build run` | build and launch the editor (on the web, the runtime) |
| `zig build run-runtime` | build and launch the runtime |
| `zig build test` | run every test |
| `zig build test-core` / `test-runtime` / `test-editor` | run one part's tests |
| `zig build -Dtarget=wasm32-emscripten run` | build the runtime for the browser and open it (uses `$EMSDK`, or `-Demsdk=<path>`) |

eggy pins vitellus, weeoui and humpty by commit in `build.zig.zon`. the submodules under `src/` are local checkouts of them: to build against your changes there, add `--fork` for each one:

```bash
zig build run --fork=src/vitellus --fork=src/weeoui --fork=src/humpty
```

once those changes are pushed, re-pin eggy with `zig fetch --save=<name> git+https://github.com/eggyengine/<name>#<commit>`.

### linux packages
fatal errors pop up a native dialog through [nvdialog](https://github.com/tseli0s/nvdialog), which needs GTK3 and DBus headers. accessibility needs `libunwind`. on debian:

```bash
sudo apt install libgtk-3-dev libdbus-1-dev libunwind-dev
```

everything else (SDL3, nvdialog, AccessKit) is fetched and linked by `zig build`. windows builds ship `accesskit.dll` beside the executables.
