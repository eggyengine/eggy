---
title: Make cutscenes and film them
---

A cutscene in Eggy is a clip played live in your scene, in the game's own time and lighting:
the player walks up to the boss, presses a key, and the camera, the characters and the
dialogue move as you keyed them while the world goes on around them. It is an entity with an
**Animator** whose clip moves other entities, and the same clip can be rendered to a video
from **File > Export**.

## Set one up

1. Make a clip (**New > Animation > Animation Clip** in Assets), then an empty entity named
   after the cutscene, say `boss intro`, and give it an **Animator** with that clip. Turn its
   **Playing** off so it waits for the game, set **Repeat** to `once`, and **Takes over** to
   `input_and_hud`.
2. Select it and open **Window > Animation**. Pick an actor (`boss`, `player`, `camera`) in the
   target list and key it, or turn on **Record** and move the actors with the gizmo: every move
   is keyed at the head. The panel stays on the cutscene while you select its actors.
3. Use **Key…** for the rest: the camera's `fov_deg` to push in, a dialogue screen's `visible`
   and the `text` of its nodes for each line, a `sound` to start, and `event`s for your code.

Cut between cameras with a camera cut: put a **Camera** on each shot's entity (turn its
**Active** off so the game doesn't look through it), pick it in the target list, choose
**camera cut** in **Key…** and give how many seconds to blend from the shot before, `0` for a
hard cut. From that key on the view looks through that camera; blending eases from the shot
before, or from the game's camera into the first one. A cut with **This entity** picked hands
the view back to the game's camera, blending as long as you say, and when the cutscene ends
the view is the game's again anyway. The keys sit on the **Camera cuts** row.

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
buttons still take presses), screens the clip doesn't animate are hidden, and the view is
letterboxed, until it ends; one paused on a choice keeps them. Holding **Escape** for a second skips to the end; the events it skips over are
still sent, so the fight still starts. `app.cutscene.takeover` says what is taken now, for
HUD you draw yourself in `gameUi`.

## Film it

**File > Export > Film** renders a cutscene of the open scene to a video, through its camera cuts
(or the scene's active camera). Pick the cutscene, the size, the frame rate and the motion blur; every frame is
rendered at a fixed step, however long that takes. The frames go to the project's
`zig-out/film/<clip>-<n>/frames/`, and with [ffmpeg](https://ffmpeg.org) installed they are
encoded into `film.mp4` there, with the clip's sounds mixed in at their keys.

The same works for any shot that isn't a cutscene in the game: an entity with an Animator and
a clip that moves the camera is a film of its own.
