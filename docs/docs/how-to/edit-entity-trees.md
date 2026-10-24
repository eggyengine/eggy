---
title: Edit entity trees
---

## Copy and paste

Right-click an entity in the Hierarchy and choose **Copy tree**, then **Paste tree**.
With the Hierarchy focused, **Ctrl+C** and **Ctrl+V** do the same; when a text field
is focused, those shortcuts edit text instead.

Copy includes descendants. Paste creates a new tree beside the selected entity,
under the same parent, or at the top level when pasting into empty space. The new
root becomes selected. References between copied entities point to their copies;
references outside the tree keep their existing targets.

The clipboard survives deleting the source tree and reloading game code. Paste is
an individual Undo/Redo step. Scene instances copy their source-scene reference,
not the generated entities inside them. Replacing the world clears clipboard
references to entities outside the copied tree, so reused entity IDs cannot bind
the paste to unrelated objects.

Tree copy, extraction, and undo snapshots currently reject components containing
`EntityRef` inside a struct, array, optional, or union field. Only direct `EntityRef`
fields can be remapped safely. This includes inactive union variants and unset
nested references; rejected copies leave the previous clipboard unchanged.
Extraction also rejects these fields outside the selected tree, because their
incoming references cannot be verified safely.

## Extract a reusable scene

Right-click an entity and choose **Extract tree to scene**. Eggy saves its tree to
`resources/scene/<entity name>.scene.zon`, choosing a numbered name rather than
overwriting a file. Rename or move the new asset from the Assets panel.

The original tree is replaced by a selected scene instance in the same sibling
position. Its local transform moves to the instance, so the tree stays in place
without applying that transform twice. Open the extracted scene to edit its contents.

Saving the file, cataloguing it, and the replacement are one Undo/Redo operation.
If saving or preparing history fails, the original tree remains. Extraction rejects
entity references crossing the tree boundary: move those targets into the tree or
clear the references first. Internal references remap when the scene is instantiated.

## Fold children or hide a tree

The arrow beside a parent folds or expands its children in the Hierarchy. It does
not affect the Scene view. Searching temporarily reveals folded matches; clearing
the search restores the folds.

The **eye** at the right of each row hides or shows that entity's meshes and authored
lights in the editor Scene view. Hiding is inherited by descendants, including scene-instance
contents; a child cannot override a hidden parent. Hidden meshes cannot be picked,
hidden lights no longer illuminate the scene, and hidden selections have no gizmo
or camera preview. Right-click also offers
**Hide in editor** / **Show in editor**, with Undo/Redo support.

Folds and eye visibility are kept for each scene in the project's `.eggy/hierarchy.zon`, so
they are there when you open the scene again. They are editor-only: they never change saved
scene contents or runtime game behavior.

## Tune one scene instance

A scene instance's entities are listed under it in the Hierarchy, their names tinted. Select
one and change its fields in the Inspector, or move it with the gizmo, to tune that instance
alone. For example, a `garden` scene can hold `player_entity` and `player2_entity`, both
instances of `player.scene.zon`. Give `player_entity`'s player a higher speed and only it
runs faster.

The scene the instance is in saves only what you changed, on the instance, so a later change
to `player.scene.zon` still shows in every instance wherever you didn't change it. Only field
values are kept: these entities can't be dragged to another parent, and a new name or a
component you add to one isn't saved. Open the instanced scene to change what it is made of.
Each change is a step you can undo.

## Inspector components

Each component card has an icon beside its name: transforms, meshes, cameras,
scene instances, materials, and lights have distinct icons; game and plugin
components use a common attachment icon. The full component name and plugin owner
remain visible. Click the header to fold its fields without removing the component.
