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

Leave `.image` unset to draw a plain square in the sprite's `tint`.

## Particles

`app.particles` sends out short-lived points that fly from a spot and fade as they age.
They are drawn as camera-facing sprites, move on game time (so they hold still while the
game is paused), and pass through scene geometry because they don't collide with it.

```zig
// A burst of sparks, all at once.
_ = try app.particles.emit(.{
    .position_m = .{ 0, 1, 0 },
    .count = 30,
    .lifetime_s = 0.6,
    .velocity_m_per_s = .{ 0, 3, 0 },
    .spread_m_per_s = 2,
    .acceleration_m_per_s2 = .{ 0, -9.8, 0 },
    .color = .{ 1, 0.7, 0.2, 1 },
});

// Smoke that keeps rising until stopped.
const smoke = try app.particles.emit(.{
    .position_m = .{ 4, 0, 0 },
    .count = 0,
    .rate_per_s = 20,
    .lifetime_s = 2,
    .velocity_m_per_s = .{ 0, 1, 0 },
    .size_m = 0.4,
    .image = .init("resources/smoke.png"),
});
try app.particles.stop(smoke);
```

With `rate_per_s` left at 0, `count` particles go out at once. With a rate, the emitter keeps
sending until you call `stop`, or until it has sent `count` if you set one. Particles already
out live for the rest of their lifetime after `stop`. Set `.fade = false` to keep them solid.
`emit` rejects negative or non-finite numbers, a size of zero, and colour channels outside
0 to 1 with `InvalidParticleOptions`. Up to 10,000 particles can be out at once; beyond
that, emitters skip new ones until older ones expire.
