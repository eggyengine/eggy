---
title: Arrange the editor in tabs
---

The bar under the editor's title bar holds **tabs**, each a whole layout of panels. The
editor starts with a **3D** tab: the Scene panel and the panels around it.

## Open a tab

Press **+** on the bar, choose **File > New Tab...** or press **Ctrl+T**, then pick:

- **3D Scene** opens a new tab laid out like the first: the Scene in the middle, the
  Hierarchy on its left, the Inspector on its right, and the Console, Assets and Animation
  below it.
- **2D Scene** opens the same layout with the **2D Scene** panel in the middle: the world seen flat from the front, X to the
  right and Y up, as a 2D game sees it. Scroll to zoom, drag with the right or middle button
  to pan, and click an entity to select it. Drag it to move it; with **Snap** on it lands on
  the grid. Drag a corner of the selection to scale it (hold **Shift** to keep its
  proportions) or the knob above it to turn it; the arrow keys nudge it a grid step.
  **Ctrl+Z** undoes each change. **F** frames the selection and **Delete** deletes it.
  A gamepad pans with the left stick and zooms with the triggers.
- **UI Scene** opens the UI Designer (see [UI scenes](ui-scenes.md)).

**File > New 3D Scene Tab**, **New 2D Scene Tab** and **New UI Scene Tab** do the same.
**Ctrl+Tab** and **Ctrl+Shift+Tab** step through the tabs.

You can open as many of each as you like. Each one keeps its own view: every 3D tab its own
camera, every 2D tab its own place and zoom, and every UI tab its own UI scene. Opening a UI
scene from Assets shows it in the UI tab you used last.

Each tab has its own copy of these panels, and the copies all show the same project and the
same selection. The editor draws one copy of each panel at a time: the one in the tab shown.
When a tab's copy is also in sight somewhere else, such as in a tab popped out into a window,
it shows **Show here**. Press it to draw it there instead.

## Make a tab of any panels

Drag a panel by its tab up onto the bar. Let go on a tab to move the panel into it, or on
**Drop here for a new tab** to give it a tab of its own. You could, for example, give the
Inspector a whole tab. Hold the panel over a tab for a moment to show that tab, then drop the
panel exactly where you want it in its layout. A tab closes by itself when its last panel leaves.

## Open a file or a scene in a tab

Drag a file from **Assets** up onto the bar to give it a tab of its own, showing it in an
**Asset Preview**. The tab is named after the file. Double-click a file in Assets to open
it the same way in a window of its own. Closing that window closes only its tab.

Drag a scene onto the bar to open it in a new 3D tab, beside the scene you have open. Each 3D
tab keeps its own scene. Showing another tab opens its scene in its place, with any changes
you haven't saved, and showing the first tab again brings yours back as you left it.
**Ctrl+Z** goes back to the scene you had before.

## Move a tab

Drag a tab along the bar and let go where you want it.

To put a tab's panels into another tab, drag it onto that tab and hold it there for a moment.
The other tab is shown. Then drop it into that tab's layout, just as you would a panel: beside
a panel, or onto a row of panel tabs, between two of them. The tab you dragged closes, and its
panels stay where you dropped them.

## Pin a tab

Right-click a tab and choose **Pin tab**. Pinned tabs sit at the start of the bar with a pin
instead of a close button, and can't be closed until you choose **Unpin tab**.

## Pop a tab out

Right-click a tab and choose **Pop out into window**, or drag it down off the bar into its own
layout. The tab becomes a window of its own that you can dock panels in, like the main one.
Click its tab on the bar to bring it back.

## Close a tab

**Close tab** (or the tab's **x**, or a middle-click) closes the tab and its panels, the 3D tab
included. Close them all and the editor is empty, ready for a new tab. **Ctrl+Z** brings a
closed tab back, and **Window** reopens any panel.

Your tabs are kept with the rest of the layout, so they are there the next time you open the
editor.
