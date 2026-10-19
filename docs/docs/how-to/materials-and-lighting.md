---
title: Materials and scene lights
---

Add **Material** and **SceneLight** through the Inspector's component menu. Both are
built-in components, so games do not need to register them.

## Surface materials

A Material on a Mesh entity supplies RGBA color, metallic and roughness factors, an
optional texture, emissive RGB, an unlit switch, and an alpha-cutout threshold. Mesh color
still tints the result. A material's texture overrides the Mesh texture; without either,
an imported model keeps its own textures.

For a reusable material, create a `.material.zon` file under `resources/`:

```zig
.{
    .color = .{ 1, 0.8, 0.3, 1 },
    .metallic = 0.8,
    .roughness = 0.25,
    .texture = "resources/art/metal.png",
}
```

Assign it to the component's **file** slot. A set file supplies the entire material rather
than mixing with the component's inline values. Materials are packaged unchanged, with
their referenced textures packaged through the normal resource pipeline. Color factors
are 0–1, roughness and metallic are 0–1, and emissive values are finite and nonnegative.
Malformed or missing material assets log an error and their meshes are not drawn.

Game code can assign components directly or use the borrowed service:

```zig
try app.materials().assign(entity, .{ .metallic = 0.6, .roughness = 0.3 });
```

Models retain imported base-color, metallic, roughness, and emissive factors in their
packaged vertices. An assigned Material overrides those factors. The model format changed:
rebuild packaged models rather than reusing older `.eggmodel` files.

Alpha below `alpha_cutoff` is discarded; this is cutout transparency, not translucent
blending. Normal maps, metallic/roughness texture maps and postprocessing are not implemented.

## Scene lights

SceneLight depends on Transform. Its **kind** selects directional or point lighting:

```zig
try app.lighting().setLight(sun, .{
    .directional = .{ .illuminance_lux = 1000 },
});
try app.lighting().setLight(lamp, .{
    .point = .{ .color = .{ 1, 0.7, 0.3 }, .intensity_cd = 100, .range_m = 6 },
});
```

Directional lights shine down their world-space local -Z axis. Point lights use their
world position, inverse-square attenuation, and a smooth cutoff at `range_m`. Parent
transforms apply to both. The renderer uses a fixed exposure reference of 1000 lux for
directional lights and 100 candela for point lights, with a small ambient term.

Up to sixteen lights can be active; exceeding this reports an error rather than silently
dropping lights. Scenes without authored lights retain a fixed preview light. Lights
illuminate metallic/roughness surfaces but do not cast shadows.

Remove just a light with `try app.lighting().removeLight(entity)`. Borrowed material/light
services and component pointers must not survive world reset or library replacement.
