---
title: Build HUDs and billboards with UI scenes
---

A **UI scene** is a `.ui.zon` file holding a tree of UI nodes: panels, text, images (GIFs
play), buttons, progress bars, other UI scenes and your plugins' own widgets. Put one on an
entity to show it over the game (a HUD, a menu) or in the world (a sign, a name tag). Edit it
in the **UI Designer** panel, and change what it shows from your game's code.

## Make a UI scene

1. In the Assets panel choose **New > UI > UI Scene**.
2. Double-click it. The UI Designer opens in a **UI** tab of its own, with its three panels
   side by side. Switch back to the **3D** tab to see the world, or right-click the UI tab and
   choose **Pop out into window** to keep both on screen.

- **UI Tree** lists the scene's nodes, the same way the Hierarchy lists entities. **Add**
  (or right-click > **Add child**) picks a kind of node: panel, text, image, button,
  progress bar, another UI scene, or a plugin's widget. Drag a row onto another to move it
  inside, or onto a row's top or bottom edge to move it beside. The right-click menu renames,
  duplicates, copies and pastes, hides and deletes; the eye hides a node.
- **UI Designer** shows the scene at the size picked in its toolbar: its design size, a
  common monitor or a phone. Click a node to select it, and drag a pinned node to move it.
  The **Grid** switch shows lines every 10 design pixels, and drags snap to them while it is
  on. Drop an image or a UI scene from Assets onto it to add it there. Drop a font to add
  text in that font.
- **UI Properties** shows the selected node's settings, the way the Inspector shows a
  component's: what the node shows, its layout and its look. Drag numbers to change them,
  and drop images, fonts and UI scenes from Assets onto their slots. With the root selected
  it also shows the scene's design size, how it scales to the screen, and its theme.

Every change is saved to the file once you let go, and **Edit > Undo** takes it back. A game
that is playing shows the new version straight away.

## Lay nodes out

A node is laid out by its parent in a column or a row (**Direction**). Its parent's
**Gap**, **Padding**, **Align items** and **Justify** set where it goes. Each axis is sized
in one of four ways:

- **Auto**: the size of its content.
- **px**: a fixed size, in design pixels.
- **Percent**: a share of its parent.
- **Fill**: whatever space is left.

A node can instead be **pinned** (its **Anchor**) to a point of its parent. It then
sits at that point, plus an offset, and is left out of the row or column. **Pin to**'s nine
squares pin a node to a corner, an edge or the middle in one click. Pin the HUD's
corners this way so they reach the screen's edges at any size.

The scene's **Scaling** says how its design size meets the screen: `height` keeps the
height the same on every screen, `fit` keeps all of it in view, `none` uses one design
pixel per screen point, and so on.

## Make it look like your game

Colors can name one of the theme's colors (**primary**, **card**, **muted**...) or be your
own. The scene's theme starts from Eggy's dark or light theme. You can replace any of its
colors, its corner radius and its font. Nodes that use theme colors follow it.

Fonts are assets: put a TTF or OTF file in your project's `resources` (or drag it into the
Assets panel) and it shows there as a font. Drop it on the theme's **Font** to use it for the
whole scene, or on a text node's **Font** to use it for that text alone. Leave a text node's
font empty to use the scene's.

A node's look also takes a background image. Its **Slice** insets make it a nine-slice,
so the corners stay sharp at any size. The look also sets a border, rounded corners,
opacity and clipping of the node's children.

## Show it

Select an entity and add a component:

- **UiScreen** shows the scene over the game's view. **Layer** orders several screens, and
  **Interactive** off lets presses through to the game.
- **UiBillboard** shows the scene in the world, at the entity's Transform. **Width m** is
  its width in metres, even under a scaled parent. The billboard is as big as what the scene lays out: all of the design
  size when the root fills it, or just a 400 by 200 root inside a 1280 by 720 design, scaled
  to that width. **Face camera** turns it
  toward the camera; otherwise it faces the entity's +Z. **Resolution** trades sharpness for
  memory. Billboards are hidden by what is in front of them. Their buttons take mouse clicks,
  and clicking one in the Scene panel selects its entity.

A **UI scene** node shows another UI scene inside this one. Build a health bar or an item
card once, then use it in many places.

## Drive it from code

Name the nodes you want to change, then use `app.uiScenes()` with the entity and the
node's name:

```zig
pub fn update(self: *Game, app: *eggy.App) !void {
    const hud = eggy.findNamed(&app.world, "hud") orelse return;
    const scenes = app.uiScenes();
    if (scenes.clicked(hud, "pause")) {
        self.paused = !self.paused;
        try scenes.setText(hud, "pause", if (self.paused) "Resume" else "Pause");
        try scenes.setVisible(hud, "paused", self.paused);
    }
    try scenes.setValue(hud, "health", self.health / self.max_health);
}
```

| Call | What it does |
| --- | --- |
| `setText(entity, name, text)` | Changes the text of a text node or button |
| `setValue(entity, name, value)` | Fills a progress bar (0 to 1) |
| `setVisible(entity, name, visible)` | Shows or hides a node and its children |
| `setImage(entity, name, image)` | Changes an image node's image |
| `reset(entity, name)` | Goes back to what the file says |
| `clicked(entity, name)` | Whether that button was pressed last frame |

Changes last until you reset them, or the world is reset. Each press is also sent as an
`eggy.ui_scenes.Clicked` event (the entity and the button's name), for ECS systems.

## Add your own widgets

A plugin can offer widgets that the designer's palette lists beside the built-in ones, such
as a minimap or a radial meter. Declare them and draw them in `uiWidget`:

```zig
pub const ui_widgets = [_]eggy.plugins.UiWidget{.{ .key = "minimap", .title = "Minimap" }};

pub fn uiWidget(self: *Self, widget: usize, draw: eggy.plugins.UiWidgetDraw) !void {
    _ = widget;
    try draw.canvas.rect(draw.rect, self.map_color);
}
```

`draw.value` is the text the node's **Value** field holds, and `draw.time_ms` is a clock
for animation. See [Plugin hooks](../reference/plugin-hooks.md#ui-widgets).

## Limits

- Billboards use Eggy's font and ignore the theme's font. A text node's own font works on
  them.
- Text in a font of its own is sharpest at 12 to 64 pixels. Between those sizes it is
  scaled from the nearest one, and above 64 pixels it gets softer.
- A screen scene's theme font becomes the whole game UI's font while it shows.
- Images are scaled with nearest-neighbour filtering.
- A click reaches a billboard's button even through something standing in front of it, and
  touches don't press billboards yet.
