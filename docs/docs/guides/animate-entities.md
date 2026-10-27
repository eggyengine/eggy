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

Select the entity and open the panel. **Play** runs the clip, the slider scrubs it and
**Loop** wraps at the end. The entity moves in the Scene while you do. **Reset pose** (or
selecting something else, hiding the panel or pressing Play on the game) puts the entity
back exactly as it was. A pose is never saved into your scene.

If the entity has both a clip and a model clip, pick which one the timeline shows. Model
clips are read-only: you can scrub and play them, not key them.

## Add keys

A diamond on the timeline is a key. To key a pose:

1. Scrub to the time you want.
2. Move the entity with the gizmo (or its Inspector fields) while the panel is posing it.
3. Choose **This entity**, or one of its children, and press **Key Position**, **Key
   Rotation** or **Key Scale**. The key records the transform as it is now.

Click a key's time under its track to select it, then **Move key to head**, **Delete key**
or **Remove track**. **Duration** sets the clip's length; it can't be shorter than the last
key. Every change is written to the `.clip.zon` straight away and **Edit > Undo** takes it
back.

While the panel is posing an entity, edits you make to its transform belong to the clip, and
the entity returns to its saved transform on **Reset pose**.
