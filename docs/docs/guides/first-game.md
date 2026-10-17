---
sidebar_position: 1
title: Your first game
---

# Your first game

In this guide you make **Cube Runner**: an orange cube on a green floor that you drive with W, A, S and D and turn with the mouse, with a camera following behind. Along the way you meet the editor's panels, entities and components, and the code that makes them move.

You need Zig 0.16.0.

## Open the editor

Get Eggy and start its editor:

```bash
git clone https://github.com/eggyengine/eggy
cd eggy
zig build run
```

The first build takes a while. Later ones are quick.

## Make a project

Choose **File > New Project**. Give the project a title, which players see, and a package name, which Zig uses: lower case, digits and `_`. Then pick a folder for it and create it.

![The New Project window, titled Cube Runner](/img/first-game/new-project.png)

Eggy writes the project and builds its editor. This also takes a while the first time.

![Creating Cube Runner: building the editor](/img/first-game/loading.png)

When it is done, the project's own editor opens:

![The editor with an empty project open](/img/first-game/editor.png)

- **Hierarchy**, on the left, lists the entities in the scene.
- **Scene**, in the middle, shows them. Hold the right mouse button and move the mouse to look around, and scroll to zoom.
- **Inspector**, on the right, shows the selected entity's components. Beside it is a panel from your project's plugin.
- **Assets**, at the bottom, shows the project's files. **Console** beside it shows what the game and its build print.

## Make a scene

A scene is a file holding entities. Choose **New > Scene** in Assets: the editor makes `untitled.scene.zon` and opens it. Save it with **Ctrl+S** whenever you change it; the status bar marks it with `*` while it has unsaved changes.

## Add the player

An entity is a thing in the scene. On its own it is only a name: **components** give it everything else, such as where it is and what it looks like.

Press **Add** in the Hierarchy to make an entity, and rename it **Player** in the field at the top of the Inspector. Then press **Add component**:

![The Add component list for the Player entity](/img/first-game/add-component.png)

Add these two:

- **Transform**: where the entity is, how it is turned and how big it is. Set its position's Y to `0.5`, so the cube sits on the floor rather than in it.
- **Mesh**: what it looks like. Pick the **Cube** shape and an orange colour (R `1`, G `0.55`, B `0.1`).

![The Player entity: an orange cube with a Transform and a Mesh](/img/first-game/player.png)

## Add the floor and the camera

Add two more entities the same way:

- **Floor**, with a Transform scaled to `30`, `1`, `30` and a Mesh with the **Plane** shape, coloured green (`0.3`, `0.5`, `0.3`).
- **Camera**, with a Transform at `0`, `3`, `7` turned `-20` degrees about X, so it looks down at the cube, and a **Camera** component.

While the camera is selected, the Scene shows what it sees in the corner:

![The Camera entity, with its view in the corner of the Scene](/img/first-game/camera.png)

Save the scene. Press **Play** at the top of the window to see the game through the camera, and press it again, or Escape three times, to stop. Nothing moves yet: that takes code.

## Make the player move

Your game is the `Game` type in your project's `src/main.zig`. Open the file in your code editor and replace it with this:

```zig
//! cube_runner: the game. A cube you drive with WASD, turned by the mouse, with the camera
//! following behind.
const std = @import("std");
const eggy = @import("eggy");

/// Something the player drives: how fast it moves and turns.
pub const Player = struct {
    speed_m_per_s: f32 = 6,
    /// Degrees turned for each point the mouse moves, while the right button is held.
    turn_deg_per_point: f32 = 0.3,
};

pub const Game = struct {
    /// The components the editor's Inspector can add to entities.
    pub const components = .{Player};

    /// Runs once a frame while the game plays.
    pub fn update(self: *Game, app: *eggy.App) !void {
        _ = self;
        var players = app.world.query(.{ *eggy.Transform, *const Player });
        while (players.next()) |view| {
            const transform = view.get(*eggy.Transform);
            const player = view.get(*const Player);

            // Hold the right mouse button and move the mouse to turn.
            if (app.input.mouseHeld(.right)) {
                transform.rotation_deg[1] -= app.input.mouse_delta[0] * player.turn_deg_per_point;
            }

            // W and S go ahead and back, A and D to the sides, the way the cube faces.
            const across, const ahead = app.input.direction(.{});
            const forward = transform.forward();
            const right = transform.right();
            const step = player.speed_m_per_s * app.time.delta_s;
            transform.translate(.{
                (forward[0] * ahead + right[0] * across) * step,
                0,
                (forward[2] * ahead + right[2] * across) * step,
            });

            // The camera follows: six metres behind, three up, looking down a little.
            const camera = eggy.findNamed(&app.world, "Camera") orelse continue;
            const eye = app.world.get(camera, eggy.Transform) orelse continue;
            eye.position = .{
                transform.position[0] - forward[0] * 6,
                transform.position[1] + 3,
                transform.position[2] - forward[2] * 6,
            };
            eye.rotation_deg = .{ -20, transform.rotation_deg[1], 0 };
            app.world.markChanged(camera, eggy.Transform);
        }
    }
};
```

What it does:

- `Player` is a component of your own. Any struct can be one; listing it in `components` lets the editor show it, add it and edit its fields.
- `update` runs every frame while the game plays. It asks the world for every entity with both a `Transform` and a `Player`, and moves each one.
- `app.input` says which keys and mouse buttons are held, and how far the mouse moved. `direction(.{})` reads A/D across and S/W ahead, each `-1`, `0`, or `1`. You can choose other keys or read one axis with `axis`.
- Multiplying by `app.time.delta_s`, the length of the last frame in seconds, keeps the speed in metres per second however fast frames come.
- `eggy.findNamed` finds the entity named Camera, so the camera can follow.

Save the file and go back to the editor. It notices the change and rebuilds your game, then swaps it in without closing, with the progress in the status bar. If the build fails, the Console says why.

## Make the cube a player

Select **Player** in the Hierarchy, press **Add component**, and add **Player**. Its fields are the struct's, with their defaults, and you can change them here:

![The Player entity with the Player component added](/img/first-game/player-component.png)

Save the scene, and press **Play**. Hold W to drive forward, use A, S and D for the other ways, and hold the right mouse button over the Scene while moving the mouse to turn. The camera stays behind the cube:

![Playing Cube Runner: the camera following the cube across the floor](/img/first-game/gameplay.png)

When you stop, everything goes back to where the scene has it: play never changes your scene.

## Next

- [Plugins](plugins.md) covers every hook your game can have, panels of its own, and sharing code between games.
- `zig build run-runtime` in your project runs the game on its own, as players see it.
- [Code-only games](code-only-games.md) creates the world without scene files.
- [Input mappings](input-mappings.md) replaces physical-key gameplay logic with named controls.
- [Error handling](error-handling.md) covers failures in the runtime and editor.
