---
title: Run animation graphs
sidebar_position: 2.5
description: State machines and blend states that pick an entity's animation from parameters the game sets.
---

An animation graph decides what an `Animator` plays, so game code only says what is happening: how fast the hero moves, whether it is on the ground, that it just jumped. The graph turns that into states, transitions and blends.

In the Assets panel choose **New > Animation > Animation Graph**. It makes a `.graph.zon` with one empty layer. Give the entity that draws the model an **AnimationGraph** component and drop the graph on its **Graph** field. It adds an `Animator` if the entity has none.

Double-click the graph to edit it in the Graph tab. Its layers and parameters are on the left, and the layer shown is on the canvas. Add states from the toolbar, drag them to arrange them, and drag from the dot on a state's right edge to another state to add a transition; from Entry, it sets where the layer starts. Press a state or an arrow to edit it on the right, and press Delete to remove it. A blend state shows its clips where they sit, along a line or on a square; drag one to move it. Every change is saved as you make it, and Edit > Undo takes it back.

A graph holds parameters and layers. A parameter is a `float`, a `bool` or a `trigger`, which stays set until a transition uses it. Each layer is a state machine. It starts in its `entry` state, and each frame it takes the first transition whose conditions all hold, fading into the next state over `blend_s` seconds. Transitions with an empty `from` leave any state, and are checked first. `wait_for_end` holds a transition back until the state it leaves has played its clip to the end, less `blend_s`. A transition from a state to itself enters it again and restarts its clip from its `start_s`, which replays a one-shot: `Draw` to `Draw` on a trigger.

A state plays one clip, or blends several by parameters. `blend_1d` places clips along one float, as in [blend states](animation-states.md). `blend_2d` places them on a plane of two floats, such as turn and speed, and the clips nearest the value share the pose. The first layer moves the whole body; a layer with a `bone` moves that bone and those below it over the layers before it.

```zig
.{
    .format_version = 1,
    .parameters = .{ .{ .name = "speed" }, .{ .name = "jump", .kind = .trigger } },
    .layers = .{ .{
        .name = "Base",
        .entry = "Locomotion",
        .states = .{
            .{ .name = "Locomotion", .motion = .{ .blend_1d = .{ .parameter = "speed", .points = .{
                .{ .clip = "1f2e3d4c5b6a7980", .at = .{ 0, 0 } },
                .{ .clip = "8a7b6c5d4e3f2011", .at = .{ 6, 0 } },
            } } } },
            .{ .name = "Jump", .motion = .{ .clip = .{ .clip = "0a1b2c3d4e5f6071", .repeat = .once } } },
        },
        .transitions = .{
            .{ .from = "Locomotion", .to = "Jump", .conditions = .{ .{ .parameter = "jump" } } },
            .{ .from = "Jump", .to = "Locomotion", .wait_for_end = true },
        },
    } },
}
```

`start_s` starts a state's clips that many seconds in each time it is entered, skipping a wind-up. `root_motion` says what they do with the root bone: `keep` moves it as the clip does, `in_place` takes out its drift so a walk walks on the spot, and `pinned` holds it at its first key, leaving the movement to the game.

A state with `.motion = .none` plays nothing, and its layer fades out over the transition's `blend_s`. An upper-body layer can rest in one, go to a one-shot `Draw` on a trigger, and come back with `wait_for_end`, so the arms ease back into the walk instead of freezing on the last frame:

```zig
.{
    .format_version = 1,
    .parameters = .{ .{ .name = "draw", .kind = .trigger } },
    .layers = .{
        .{ .name = "Base", .states = .{
            .{ .name = "Walk", .motion = .{ .clip = .{ .clip = "8a7b6c5d4e3f2011" } }, .root_motion = .in_place },
        } },
        .{
            .name = "Arms",
            .bone = "mixamorig:Spine",
            .entry = "Rest",
            .states = .{
                .{ .name = "Rest", .motion = .none },
                .{ .name = "Draw", .motion = .{ .clip = .{ .clip = "5e6f708192a3b4c5", .repeat = .once } }, .start_s = 0.2 },
            },
            .transitions = .{
                .{ .from = "Rest", .to = "Draw", .conditions = .{ .{ .parameter = "draw" } } },
                .{ .from = "Draw", .to = "Draw", .conditions = .{ .{ .parameter = "draw" } } },
                .{ .from = "Draw", .to = "Rest", .blend_s = 0.3, .wait_for_end = true },
            },
        },
    },
}
```

Clips are named by their asset ids, which the editor writes for you. Set parameters from code each frame through `app.animationGraphs()`:

```zig
const graphs = app.animationGraphs();
try graphs.set(hero, "speed", ground_speed_m_per_s);
try graphs.set(hero, "grounded", if (on_ground) 1 else 0);
if (jumped) try graphs.trigger(hero, "jump");
```

A graph holds at most 16 parameters, 4 layers and 32 states a layer. Every clip playing at once, across layers and fades, shares the `Animator`'s 8 slots, so a blend state holds at most 8 clips.
