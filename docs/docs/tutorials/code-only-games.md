---
slug: /guides/code-only-games
sidebar_position: 2
title: Your first code-only game
---

Create a cube and camera in Zig, move the cube with WASD or a controller, and draw
an instruction label over the game. You will build and run it without authoring a
scene file.

## Before you begin

You need Zig 0.17.0, a code editor, and an Eggy game package containing
`src/main.zig`, `build.zig`, and `build.zig.zon`. You can use a project created by
the [project setup guide](../how-to/set-up-project.md) or an existing Zig package.
This lesson assumes you can edit and build Zig source files.

## 1. Set up the package {#set-up-the-package}

If you created the package with the editor, keep its build files. A plugin in
`src/root.zig` is optional; remove its `addPlugin` call and its entry in
`addGame.plugins` if you do not need it.

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

## 2. Build the world in code {#build-the-world-in-code}

Replace `src/main.zig` with this game. `init` creates a cube and camera, `update`
moves the cube, and `gameUi` draws the instruction label:

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

The world owns spawned entities. `EntityRef` stores an ID; `get` checks it again
each update before returning the component. The names let `init` reuse entities
if you later open this game in the editor or load a scene, avoiding duplicates
on restart. For a required entity, return an explicit game error when it is
missing or incompatible.

Transforms use metres, degree rotations, Y up, and forward along -Z. Mapped movement has
right/down-positive axes, so W's negative Y value moves this cube toward world -Z.
The camera looks down -Z from its transform. Built-in shapes need no model or
image files.

## 3. Keep startup free of scenes

For this lesson, do not select a startup scene or leave scene files in
`resources/`. A selected scene loads before `Game.init`, so it could add entities
to the world before the code above runs. Normal runtime builds select a scene
from `-Dscene`, then `eggy.zon.default_scene`, then the editor's last open scene,
then the first resource scene. See
[startup configuration](../reference/project-configuration.md) for lookup.

Other resources are still packaged normally.

## 4. Run without the editor {#run-without-the-editor}

From the project directory, build and launch the runtime. These commands use
`little_game`, the name in the build file above. If you kept an existing build
file, use its game's executable name:

```sh
zig build runtime
./zig-out/bin/little_game
```

Or use `zig build run-runtime`. `zig build run` opens the desktop editor instead.
Use `-Doptimize=fast` for an optimized runtime.

You should see the orange cube and the instruction label. Press W and S to move
it along world Z, and A and D to move it sideways. If a controller is connected,
its left stick should move the same cube. The camera stays in place in this
example, so the cube can move out of view.

## 5. Prepare the runtime for distribution

Distribute the installed directory, not just the executable.

The current `zig build export`/File > Export workflow requires a startup scene even for
a game that spawns everything itself. Use an empty startup scene for that workflow, or
build and distribute the runtime installation directly. Code-only spawning does
not require changing physics or adding a separate entity framework.

## Next {#keep-authoring-in-code}

The input-map declaration supplies defaults without a settings file.
[Map player controls](../how-to/map-input.md) explains how to use a project-root
`controls.zon` to change bindings without changing game logic; the build embeds
that file.

Use ordinary Zig state and [value timers](../how-to/timers.md) for gameplay.
For a UI-only game, you can omit the camera and mesh: a `gameUi` or `draw` hook
still renders.

- [Draw game UI](../how-to/game-ui.md) for more than an instruction label.
- [Handle errors](../how-to/handle-errors.md) for recoverable failures and the runtime/editor boundaries.
- [Create plugins](../how-to/create-plugins.md) for native ECS systems and reusable packages.
- [Build and export](../how-to/build-and-export.md) for runtime distribution.
