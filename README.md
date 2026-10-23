> [!NOTE]
> By removing this, you prove that the code has been reviewed by human.

# eggy

_eggy_ is a game engine written in Zig. more info at [eggyengine.github.io](https://eggyengine.github.io). 

eggy itself comes in three parts:

| module | what it is | platforms |
|---|---|---|
| `eggy` | the engine your game imports: window, renderer, scene, plugins | all, including the web |
| `eggy_runtime` | runs your game as players see it | all, including the web |
| `eggy_editor` | your game with editor tooling over it | desktop only |

## make a game
requires zig `0.16.0`

The eggy engine uses the editor to initialise the project, so all of these steps are done automatically.

Documentation is also available at [eggyengine.github.io/eggy](https://eggyengine.github.io/eggy)
<!-- 
an eggy package works like a zig one: `src/main.zig` is a **game** (`pub const Game`), and `src/root.zig` is a **plugin** or library (`pub const Plugin`) that other packages can use. keep both, or delete the one you don't need.

add eggy to your project:
```bash
zig fetch --save git+https://github.com/eggyengine/eggy#0.16.0
```

then in `build.zig`:
```zig
const std = @import("std");
const eggy = @import("eggy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // src/root.zig: published as module "my_game", with @import("eggy")
    const plugin = eggy.addPlugin(b, .{ .name = "my_game", .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });

    // src/main.zig: the game, running the plugin
    eggy.addGame(b, .{
        .name = "my_game",
        .game = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }),
        .plugins = &.{plugin},
        .target = target,
        .optimize = optimize,
    });
}
```

your game, in `src/main.zig`:
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

and your plugin, in `src/root.zig`:
```zig
const eggy = @import("eggy");

pub const Plugin = struct {
    pub fn editorUi(_: *Plugin, ui: *eggy.ui.Context) void {
        ui.muted("my_game plugin");
    }
};
```

### using other plugins
a plugin package publishes its `src/root.zig` with `addPlugin`. fetch it, then list it in `addGame`; plugins run after your game each frame, in the order you list them:
```zig
.plugins = &.{
    plugin,
    b.dependency("cool_plugin", .{}).module("cool_plugin"),
},
```

every plugin runs on your game's eggy, so they all share one engine. -->

### linux packages
fatal errors pop up a native dialog through [nvdialog](https://github.com/tseli0s/nvdialog), which needs GTK3 and DBus headers. accessibility needs `libunwind`. on debian:

```bash
sudo apt install libgtk-3-dev libdbus-1-dev libunwind-dev
```

everything else (SDL3, nvdialog, AccessKit) is fetched and linked by `zig build`. windows builds ship `accesskit.dll` beside the executables.

## contributing to eggy
clone the repository, then run the editor as such:

```bash
git clone --recursive https://github.com/eggyengine/eggy
cd eggy
zig build run
```

despite being potentially controversial, agents are welcome to contribute however you cannot make **slop** commits. They must be reviewed as though I can ask you in person what the PR does without looking at the code. 

I personally use agents to help me work on this, and personally review through everything. 
