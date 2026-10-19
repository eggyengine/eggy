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
