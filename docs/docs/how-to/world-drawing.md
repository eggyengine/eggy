---
title: Draw world sprites and text
---

Use `app.draw2d` during `update`, an ECS update system, or `editorUpdate` to request
world-space drawings for this frame. These are not screen-space widgets: they use the
game or Scene camera and are hidden by opaque geometry in front of them.

```zig
try app.draw2d.sprite(.{
    .image = .init("resources/art/marker.png"),
    .position = .{ 2, 1 },
    .depth_m = -3,
    .size = .{ 1, 1 },
});
try app.draw2d.worldText("Checkpoint", .{ 2, 2, -3 }, 0.3);
```

The sprite's position is its centre. Its default plane is world XY, with Z given by
`depth_m`; width and height are metres. Set `billboard = true` to face each view's
camera, or rotate it in its plane with `rotation_deg`. For 2D games, use an
[orthographic camera](render-scene.md#cameras-and-custom-drawing). These drawings last one
frame; for sprites placed in a scene and edited in the 2D Scene panel, use the `Sprite`
component instead ([Make a 2D game](../guides/make-a-2d-game.md)).

## Atlas regions and ordering

`uv_rect` is `{ left, top, right, bottom }` in normalized image coordinates:

```zig
try app.draw2d.sprite(.{
    .image = .init("resources/art/atlas.png"),
    .uv_rect = .{ 0, 0, 0.25, 0.25 },
    .tint = .{ 1, 0.5, 0.5, 0.8 },
    .layer = 2,
});
```

Higher layers draw later. Within a layer, transparent sprites and text sort back to
front; ties preserve submission order. They alpha-blend without writing depth, but
opaque scene geometry still occludes them. Sprites are unlit; scene lights and shadows
do not recolor them.

Text is UTF-8, white, camera-facing, and anchored at its left baseline. `height_m` is
the nominal font size in metres, not a fixed pixel size. Newlines create additional
lines. Text reuses the engine's default font and glyph rasterization.

Requests copy asset references and text. They clear at the next frame's start, so submit
them every update while visible. Do not queue them from the custom `draw` hook, which
runs after the scene pass. Invalid sizes, non-finite values, invalid UTF-8 and allocation
failures return errors. Failed image preparation reports `SpriteTextureUnavailable`.
