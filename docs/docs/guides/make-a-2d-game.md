---
title: Make a 2D game
---

A 2D game in Eggy is a world seen flat from the front: X to the right, Y up, and the camera
looking along -Z. Images are drawn with **Sprite** components, animated with
**SpriteAnimator**, and levels are painted with **Tilemap**. All three work in the **2D Scene**
panel, the 3D Scene panel and the game alike.

## Set up the camera

Add an entity with a **Camera**, set its `projection` to `orthographic`, and place it in front
of the scene (a `Transform` position of `0, 0, 10` works). `orthographic_height_m` is how many
metres of the world fit the window's height.

Open the 2D view with the **+** on the tab bar and **2D Scene**. It opens with the Hierarchy,
Inspector, Console and Assets around it, as a 3D tab does. Scroll to zoom and drag with the
right or middle button to pan.

The toolbar floating in the panel's corner works like the 3D Scene's: pick **Move**,
**Rotate**, **Scale** or both (**W**, **E**, **R**, **T**), turn snapping to the grid on or
off (hold **Ctrl** while dragging to do the opposite), show or hide the grid, and go back to
the origin. Drag its grip to move it, or fold it away with its last button. Where the pointer
is in the world shows in the bottom left corner.

## Draw a sprite

1. Put an image (PNG, JPEG, GIF or BMP) in `resources/`.
2. Select an entity and add a **Sprite** in the Inspector.
3. Drag the image from Assets onto its **image** slot.

| Field | What it does |
| --- | --- |
| `size_m` | Width and height in metres, before the `Transform`'s scale. |
| `color` | Tint, multiplied with the image. Lower the alpha to fade it out. |
| `region` | The part of the image shown: left, top, right, bottom, as fractions of the image. |
| `flip_x`, `flip_y` | Mirror it, without turning it over. |
| `layer` | Higher layers draw over lower ones, whatever their position. |
| `alpha_cutoff` | Pixels with less alpha than this aren't drawn. |

For crisp pixel art, open File > Project Settings and, under **Graphics**, set **Texture
filtering** to **Nearest (pixelated)**.

## Move, scale and turn things

Click an entity in the 2D Scene panel to select it and drag it to move it. With **Scale**
picked its box shows a square on each corner, with **Rotate** a knob above it, and with both
picked, both:

- Drag a corner to scale it. Hold **Shift** to keep its proportions.
- Drag the knob to turn it. With snapping on, it turns in 15 degree steps.
- The arrow keys nudge it one grid step.
- **F** frames it and **Delete** deletes it.

**Ctrl+Z** undoes each of these.

## Animate a sprite sheet

A sprite sheet is one image holding every frame in a grid. To see how yours is cut, select it
in Assets, turn on **Sprite sheet** in the Asset Preview and set its columns and rows. Each
frame is numbered from 0, left to right, top to bottom.

Add a **SpriteAnimator** to the entity with the Sprite:

| Field | What it does |
| --- | --- |
| `columns`, `rows` | How the image is cut. |
| `first_frame`, `frame_count` | The run of frames played, for example 8 and 4 for a walk in frames 8 to 11. |
| `frames_per_second` | How fast it plays. |
| `repeat` | `loop`, `once` (stops on the last frame), or `ping_pong` (there and back). |
| `playing` | It plays while this is on. |

The editor shows the frame the animator is on, and it plays when you press Play. It follows
the game's time, so pausing holds it.

To switch animations from code, change the run and start it again:

```zig
pub fn update(self: *Game, app: *eggy.App) !void {
    const player = eggy.findNamed(&app.world, "player") orelse return;
    const animator = app.world.get(player, eggy.SpriteAnimator) orelse return;
    const running = app.input.held(.right) or app.input.held(.left);
    const first: u16 = if (running) 8 else 0;
    if (animator.first_frame != first) {
        animator.first_frame = first;
        animator.frame_count = 4;
        animator.time_s = 0;
    }
    // Face the way it moves.
    if (app.world.get(player, eggy.Sprite)) |sprite| {
        if (app.input.held(.left)) sprite.flip_x = true;
        if (app.input.held(.right)) sprite.flip_x = false;
    }
    _ = self;
}
```

## Paint a tilemap

A tilemap is a grid of tiles cut from one tileset image, saved in a `.tilemap.zon` file.

1. In Assets, choose **New > Tilemap**. It makes an empty 16 by 16 map.
2. Open the file and set `columns` and `rows` to how your tileset is cut.
3. Add a **Tilemap** to an entity. Drag the map file onto **map** and the tileset image onto
   **tileset**. The map's top-left corner sits at the entity.
4. Select the entity in the 2D Scene panel and turn on **Paint tiles**. The tileset shows as a
   palette: click a tile to pick it.
5. Drag over the map to paint. Hold **Shift** to erase, or **Alt** and click to pick up the
   tile under the pointer.

Each stroke is one step for **Ctrl+Z**. `tile_size_m` sets how big each tile is in metres, and
`layer` puts the map in front of or behind sprites.

To make a map a different size, change `width` and `height` in its file and give `tiles`
that many entries, row by row from the top. 0 is an empty cell and `n` is tileset frame
`n - 1`.

## What's not there yet

- Sprites are cut out, not blended: pixels are either drawn or not, so soft edges look hard.
- There is no 2D physics yet. Move things in `update`, or use 3D physics with your sprites
  standing on the XY plane.
- The 2D Scene panel selects one entity at a time.
