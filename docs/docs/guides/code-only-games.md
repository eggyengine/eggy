---
sidebar_position: 18
title: Code-only games
---

# Code-only games

The editor and scene files are optional. A game can create its world in `Game.init`,
read named input in `update`, and draw a HUD in `gameUi`.

## Set up the package

Use an Eggy game package with `src/main.zig`, `build.zig`, and `build.zig.zon`.
If you already created one with the editor, keep its build files and replace `src/main.zig`
with the example below. A plugin in `src/root.zig` is optional; remove its `addPlugin`
call and its entry in `addGame.plugins` if you do not need it.

For an existing Zig package, fetch Eggy and use the following `build.zig`:

```sh
zig fetch --save=eggy git+https://github.com/eggyengine/eggy
```

```zig
const std = @import("std");
const eggy = @import("eggy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    eggy.addGame(b, .{
        .name = "little_game",
        .game = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .target = target,
        .optimize = optimize,
    });
}
```

Keep `src` and your build files in `build.zig.zon.paths`. Include `resources`, `eggy.zon`,
and `controls.zon` there too if the package uses them. `addGame` supplies the `eggy`
import and the runtime entry point; do not write a separate `main` or poll SDL yourself.

## Build the world in code

```zig
const std = @import("std");
const eggy = @import("eggy");

const PlayerInput = eggy.input.Map(enum { move }, .{
    .key = "player",
    .controls = &.{
        .{ .control = .move, .kind = .vector, .bindings = &.{
            .{ .keys_2d = .{} },
            .{ .controller_stick = .{} },
        } },
    },
});

pub const Game = struct {
    player: eggy.EntityRef(eggy.Transform),
    pub const input_maps = .{PlayerInput};

    pub fn init(_: std.mem.Allocator, app: *eggy.App) !Game {
        const player = eggy.findNamed(&app.world, "Player") orelse
            try app.world.spawn(.{
                eggy.Name.init("Player"),
                eggy.Transform{},
                eggy.Mesh{ .color = .{ 1, 0.55, 0.1 } },
            });
        if (eggy.findNamed(&app.world, "Camera") == null) {
            _ = try app.world.spawn(.{
                eggy.Name.init("Camera"),
                eggy.Camera{},
                eggy.Transform{ .position = .{ 0, 3, 7 }, .rotation_deg = .{ -20, 0, 0 } },
            });
        }
        return .{ .player = .init(player) };
    }

    pub fn update(self: *Game, app: *eggy.App) !void {
        const move = try app.input.map(PlayerInput).vector(.move);
        const player = self.player.get(&app.world) orelse return;
        const step = 3 * app.time.delta_s;
        player.translate(.{ move.x * step, 0, move.y * step });
        app.world.markChanged(self.player.entity.?, eggy.Transform);
    }

    pub fn gameUi(_: *Game, _: *eggy.App, ui: *eggy.ui.Context) !void {
        ui.theme = .dark;
        ui.label("Move with WASD or the controller's left stick.", .{});
    }
};
```

The world owns spawned entities. `EntityRef` stores an ID rather than a component pointer;
`get` checks it again each update. Names let `init` reuse entities if you later open this
game in the editor or load a scene, instead of duplicating them on every restart.
For a required entity, return an explicit game error when it is missing or incompatible.

Transforms use metres, degree rotations, Y up, and forward along -Z. Mapped movement has
right/down-positive axes, so W's negative Y value moves this cube toward world -Z.
The camera looks down -Z from its transform. Built-in shapes need no model/image files.
UI-only games can omit the camera and mesh; a `gameUi` or `draw` hook still renders.

## Run without the editor

```sh
zig build runtime
./zig-out/bin/little_game
```

Or use `zig build run-runtime`. `zig build run` opens the desktop editor instead.
Use `-Doptimize=ReleaseFast` for an optimized runtime.

For a strictly code-created world, do not select a startup scene or leave scene files in
`resources/`. Normal runtime builds otherwise choose `-Dscene`, then `eggy.zon.default_scene`,
then the editor's last open scene, then the first resource scene. A chosen scene loads
before `Game.init`. Other resources are still packaged normally; distribute the installed
directory, not just the executable.

The current `zig build export`/File > Export workflow requires a startup scene even for
a game that spawns everything itself. Use an empty startup scene for that workflow, or
build/distribute the runtime installation directly. Code-only spawning does not require
changing physics or adding a separate entity framework.

## Keep authoring in code

Input-map declarations provide usable defaults without any settings file. You can edit a
project-root `controls.zon` by hand when bindings should change without editing game logic;
the build embeds it. See [Input mappings](input-mappings.md).

Use ordinary Zig state and [value timers](timers.md) for gameplay.
[Error handling](error-handling.md) explains recoverable failures and the runtime/editor
boundaries. [Plugins](plugins.md) covers native ECS systems and reusable packages.
