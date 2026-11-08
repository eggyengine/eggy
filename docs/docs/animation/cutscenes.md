---
title: Make cutscenes and render them
sidebar_position: 3
sidebar_label: Cutscenes
description: Key a cutscene, cut between cameras, start it from the game and render it to video.
---

A cutscene in Eggy is a clip played live in your scene, in the game's own time and lighting:
the player walks up to the boss, presses a key, and the camera, the characters and the
dialogue move as you keyed them while the world goes on around them. It is an entity with an
**Animator** whose clip moves other entities, and the same clip can be rendered to a video
from the **Render** menu.

## Set one up

1. Select an entity named after the cutscene, say `boss intro`, and press **Make a cutscene** in
   **Window > Animation**: it writes a clip into `resources/cutscenes/` and sets the Animator up
   as below. Or by hand: make a clip (**New > Animation > Cutscene** in Assets, five seconds long), then an empty entity named
   after the cutscene, say `boss intro`, and give it an **Animator** with that clip. Turn its
   **Playing** off so it waits for the game, set **Repeat** to `once`, and **Takes over** to
   `input_and_hud`.
2. Select it and open **Window > Animation**. Pick an actor (`boss`, `player`, `camera`) in the
   target list and key it, or turn on **Record** and move the actors with the gizmo: every move
   is keyed at the head. The panel stays on the cutscene while you select its actors.
3. Use **Key…** for the rest: the camera's `fov_deg` to push in, a dialogue screen's `visible`
   and the `text` of its nodes for each line, a `sound` to start, and `event`s for your code.

Cut between cameras on the **Camera cuts** lane at the top of the timeline. Put a **Camera** on
each shot's entity (turn its **Active** off so the game doesn't look through it), scrub to where
the shot starts and press **Add shot**: it cuts there to the next camera in the scene. Each shot
runs until the next one. Click a shot to pick its **Camera** (**Game camera** hands the view
back to the game's), and choose **Cut** or **Blend** with how many frames and which ease it
blends in over, from the shot before or, for the first, from the game's camera. Drag a shot to
move it. When the cutscene ends the view is the game's again anyway.

While the panel poses the cutscene, the Scene panel shows the shot at the head in its corner,
and looking through the game's camera from its toolbar shows the cutscene as the player will
see it, cuts and blends included.

Lines of dialogue are UI scenes: make a `dialogue.ui.zon` in the UI Designer with a `line`
node, put it on an entity with a **UiScreen**, and key `text` on the `line` node. Its buttons
work during the cutscene.

## Start it from the game

Start it when the player interacts with the boss, and answer its events in the
`animationEvent` hook:

```zig
const std = @import("std");
const eggy = @import("eggy");

pub const Game = struct {
    pub fn update(_: *Game, app: *eggy.App) !void {
        const boss = eggy.animation.inScene(&app.world, "boss") orelse return;
        const player = eggy.animation.inScene(&app.world, "player") orelse return;
        const intro = eggy.animation.inScene(&app.world, "boss intro") orelse return;
        const near = app.world.get(boss, eggy.Transform).?.position.distance(app.world.get(player, eggy.Transform).?.position) < 2;
        // The cutscene holds the player's input while it plays, so this can't restart it.
        if (near and app.input.pressed(.e)) try app.animation().start(intro);

        // The player answered the boss: carry on from where the clip waited.
        const dialogue = eggy.animation.inScene(&app.world, "dialogue") orelse return;
        if (app.uiScenes().clicked(dialogue, "accept")) try app.animation().unpause(intro);
    }

    pub fn animationEvent(_: *Game, app: *eggy.App, event: eggy.animation.Event) !void {
        if (std.mem.eql(u8, event.name, "wait_for_choice")) try app.animation().pause(event.animator);
        if (std.mem.eql(u8, event.name, "start_fight")) {
            // Your game's own code: wake the boss, start the music...
        }
    }
};
```

While a cutscene that takes over plays, the player's input doesn't reach the game (UI
buttons still take presses) and screens the clip doesn't animate are hidden, until it ends;
one paused on a choice keeps them. Turn on the Animator's **Letterbox** for black bars over the
top and bottom of the view while it plays. Holding **Escape** for a second skips to the end; the events it skips over are
still sent, so the fight still starts. `app.cutscene.takeover` says what is taken now, for
HUD you draw yourself in `gameUi`.

## Render it

The **Render** menu renders cutscenes of the open scene as Blender does, through their camera
cuts (or the scene's active camera), in the Render window, which shows each frame as it is made.
**Render Animation** (Ctrl+F12) renders the cutscene chosen in the window, which starts as the
one open in the Animation panel; **Render Image** renders the frame at the Animation panel's
playhead; **Render All Cutscenes** renders each in turn. **View Render** (F11) opens the window
without rendering, to change the size, frame rate, motion blur and format first.

Every frame is rendered at a fixed step, however long that takes, and Stop keeps the frames
made so far. They go to the project's `zig-out/film/<clip>-<n>/frames/`, and with
[ffmpeg](https://ffmpeg.org) installed they are encoded into `film.mp4` there, with the clip's
sounds mixed in at their keys.

The same works for any shot that isn't a cutscene in the game: an entity with an Animator and
a clip that moves the camera is a film of its own.
