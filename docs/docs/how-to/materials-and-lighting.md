---
title: Materials and scene lights
---

Add **Material**, **SceneLight** and **Environment** through the Inspector's component menu. They are
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
blending. Normal maps and metallic/roughness texture maps are not implemented.

## Scene lights

SceneLight depends on Transform. Its **kind** selects directional, point or spot lighting:

```zig
try app.lighting().setLight(sun, .{
    .directional = .{ .illuminance_lux = 1000 },
});
try app.lighting().setLight(lamp, .{
    .point = .{ .color = .{ 1, 0.7, 0.3 }, .intensity_cd = 100, .range_m = 6 },
});
try app.lighting().setLight(spotlight, .{
    .spot = .{ .intensity_cd = 500, .range_m = 12, .inner_angle_deg = 15, .outer_angle_deg = 30 },
});
```

Directional and spot lights shine down their world-space local -Z axis. Point and spot
lights use their world position, inverse-square attenuation, and a smooth cutoff at
`range_m`. Spot cones smoothly fade between the inner and outer angles; angles are
half-angles in degrees and must satisfy `0 <= inner < outer < 90`. Parent transforms
apply to all light types.

Lighting uses a GGX metallic/roughness BRDF, native lux/candela strengths with a shared
exposure reference of 1000, and an ACES fitted tone mapper. Emissive surfaces are included
before exposure and tone mapping. Unlit materials bypass the BRDF and tone mapping,
but still receive global exposure.

Up to sixteen lights can be active; exceeding this reports an error rather than silently
dropping lights. Scenes without authored lights retain a fixed preview light by default.

## Ambient illumination and exposure

Use one **Environment** component to save ambient lighting with the scene. The code API
sets a world resource that takes precedence over that component:

```zig
try app.lighting().setEnvironment(.{
    .ambient_color = .{ 0.8, 0.9, 1 },
    .ambient_intensity = 0.02,
    .exposure_ev = 1,
    .default_light = false,
});
```

Positive exposure EV doubles brightness per stop; negative EV halves it. Disabling
`default_light` removes the fallback light, not the ambient term. Multiple Environment
components without a resource override report an error.

## Directional shadows

Enable **casts_shadows** on one directional light, or select it explicitly:

```zig
try app.lighting().setShadowCaster(sun);
// Disable all authored shadow casters.
try app.lighting().setShadowCaster(null);
```

The code API validates the requested entity before changing the existing selection.
Authoring multiple shadow casters reports an error. Point and spot shadow requests
report `UnsupportedShadowLight`; those shadow types are not implemented.

Graphics settings select **off**, **low** (1024), **medium** (2048) or **high** (4096)
shadow maps, plus shadow distance in metres and depth bias. One texel-stabilized map
follows each view's camera; a 3×3 PCF filter softens edges, and alpha-cutout materials
also cut out the shadow. Increasing distance trades nearby detail for coverage.
Quality is bounded by the selected GPU's maximum texture size.

Shadows use one directional map, not cascades. Environment image-based lighting,
global illumination and ray tracing are not implemented.

Remove just a light with `try app.lighting().removeLight(entity)`. Borrowed material/light
services and component pointers must not survive world reset or library replacement.
