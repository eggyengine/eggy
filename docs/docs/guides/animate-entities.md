---
title: Animate with the Animation panel
---

The **Animation** panel previews an entity's clips in the Scene and lets you add keyframes
to a clip you wrote yourself. Open it from **Window > Animation**; it docks beside the
Console.

## Make a clip and give it to an entity

1. In the Assets panel choose **New > Animation > Animation Clip**. It creates a `.clip.zon` file with
   one second and no tracks.
2. Select an entity, add an **Animator** in the Inspector and drop the clip on its **Clip**
   field. A model's own animations show under the model in Assets; drop one on **Model
   clip**.

## Preview

Select the entity and open the panel. **Play** runs the clip, clicking or dragging along the
ruler scrubs it and **Loop** wraps at the end. Everything the clip moves follows in the Scene
while you do. **Reset pose** (or selecting another entity with an Animator, hiding the panel
or pressing Play on the game) puts the scene back exactly as it was. A pose is never saved
into your scene.

The panel stays on its entity while you select others, so you can pose the actors of a
cutscene one after another.

If the entity has both a clip and a model clip, pick which one the timeline shows. Model
clips are read-only: you can scrub and play them, not key them.

## Add keys

Each track has a row, with what it acts on and its property on the left and a diamond for each
key. To key a pose:

1. Scrub to the time you want.
2. Move the entity with the gizmo (or its Inspector fields) while the panel is posing it.
3. Choose **This entity**, one of its children or any other entity in the scene, and press
   **Key Position**, **Key Rotation** or **Key Scale**. The key records the transform as it
   is now.

Or turn on **Record**: then whatever you move with the gizmo or the 2D handles, and a camera's
field of view changed in the Inspector, is keyed at the head as soon as you let go. Select
the entity to move in the Hierarchy; the panel keeps showing the clip.

**Key…** keys the rest: a camera's `fov_deg`, a UI node's `text` or `visible`, a `sound` to
start, a named `event`, or a sprite's `sprite_frame`. Pick the property, name the UI node where
it needs one, give the value and press **Add key**.

Click a key's diamond to select it; Shift-click adds more, from any track, and Ctrl+A selects
them all. Drag selected keys along their rows to move them together: they land on whole frames
(30 a second) and on the head when they pass near it, and hold Ctrl to place them freely.
Delete removes them, Ctrl+C and Ctrl+V copy them to the head, and **Move key to head** moves a
single key there. Click a track's name to select the track, then **Remove track**.

A key's ease shapes the move from it to the next key: **Ease in** starts slow, **Ease out**
settles into the next key, and **Ease in-out** does both, which suits most camera moves.

Ctrl+wheel over the timeline zooms in on the pointer and Shift+wheel pans; **Fit** shows the
whole clip again. **Duration** sets the clip's length; it can't be shorter than the last key.
Every change is written to the `.clip.zon` straight away and **Edit > Undo** takes it back.

While the panel is posing an entity, edits you make to its transform belong to the clip, and
the entity returns to its saved transform on **Reset pose**.
