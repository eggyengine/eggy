---
title: The Scene panel
sidebar_position: 2
description: Move around the Scene with a mouse, touchpad or gamepad, and play the game in it.
---

The **Scene** panel shows the open scene through the editor's own camera, with a gizmo on the
selection. **W**, **E**, **R** and **T** pick the gizmo's Move, Rotate, Scale and Universal
handles, as do the buttons on its floating toolbar.

## Move around

| Device | Look | Move | Zoom |
| --- | --- | --- | --- |
| Mouse | Right-drag looks around; Alt+left-drag orbits | Right-drag with WASD flies; middle-drag pans | Wheel |
| Touchpad | Two-finger scroll orbits | Shift with two-finger scroll pans | Ctrl with two-finger scroll, or pinch |
| Gamepad | Right stick looks around; with the right shoulder held, orbits | Left stick flies, faster with the left shoulder held; the triggers rise and sink | |

The panel tells mouse and touchpad scrolling apart on each scroll, so both work together.
Pinch zooms where the desktop passes pinch gestures to SDL. SDL has no twist gesture, so
scroll sideways with two fingers to turn around the scene. A gamepad's south button (A on
Xbox pads) frames the selection, as **F** does.

Gestures start only over the Scene, not over its toolbar or another panel. A gamepad steers
whichever Scene panel, 3D or 2D, the pointer was over last. The [2D Scene panel](workspace-tabs.md#open-a-tab)
pans and zooms instead of flying.

## Play the game

**Play** at the top of the window runs the game in the Scene panel, through the scene's active
camera. The toolbar, gizmo and orientation widget hide, and an accent border marks the panel
as playing. Press **Play** again, or **Escape**, to stop; change **Stop play key** in
**Edit > Settings** if the game needs Escape itself. **Simulate** runs the game's systems and
physics while you keep the editor's camera and tools. Both start with nothing selected.

To play through another of the scene's cameras, hold **Shift** while you press **Play**, pick
the camera, and press **Play**. That camera is the only active one until you stop.

Stopping puts the scene back as it was before Play. To keep where something ended up, select
it and press **Ctrl+Shift+K** while playing: its Transform stays after Stop, and **Edit > Undo**
takes it back. [Ownership, Play, and reload](../game-code/ownership-and-reload.md#play-starts-from-the-editable-scene)
explains what else Play and Stop do.

While the game runs, the gamepad is the game's.

## Scenes changed outside the editor

When something else saves the open scene, such as a text editor, a script or `git checkout`,
the editor opens it again as a step you can undo. If you have unsaved changes it leaves the
scene alone. Scene instances of a changed scene are made again.
