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

## Extract a reusable scene

Right-click an entity and choose **Extract tree to scene**. Eggy saves its tree to
`resources/scene/<entity name>.scene.zon`, choosing a numbered name rather than
overwriting a file. Rename or move the new asset from the Assets panel.

The original tree is replaced by a selected scene instance in the same sibling
position. Its local transform moves to the instance, so the tree stays in place
without applying that transform twice. Open the extracted scene to edit its contents.

Saving the file, its descriptor, and the replacement are one Undo/Redo operation.
If saving or preparing history fails, the original tree remains. Extraction rejects
entity references crossing the tree boundary: move those targets into the tree or
clear the references first. Internal references remap when the scene is instantiated.

## Fold children or hide a tree

The arrow beside a parent folds or expands its children in the Hierarchy. It does
not affect the Scene view. Searching temporarily reveals folded matches; clearing
the search restores the folds.

The **eye** at the right of each row hides or shows that entity's meshes in the
editor Scene view. Hiding is inherited by descendants, including scene-instance
contents; a child cannot override a hidden parent. Hidden meshes cannot be picked,
and hidden selections have no gizmo or camera preview. Right-click also offers
**Hide in editor** / **Show in editor**, with Undo/Redo support.

Folds and eye visibility are editor-only and reset when the world is replaced,
including scene changes, Undo of scene edits, Play, and game-code reloads. They
never change saved scene contents or runtime game behavior.

## Inspector components

Each component card has an icon beside its name: transforms, meshes, cameras,
scene instances, materials, and lights have distinct icons; game and plugin
components use a common attachment icon. The full component name and plugin owner
remain visible. Click the header to fold its fields without removing the component.
