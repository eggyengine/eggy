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
not the generated entities inside them.

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
