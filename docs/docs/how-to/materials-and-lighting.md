---
title: Materials and scene lights
---

Add **Material**, **SceneLight** and **Environment** through the Inspector's component menu. They are
built-in components, so games do not need to register them.

## Surface materials

A Material on a Mesh entity supplies RGBA color, metallic and roughness factors, an
optional texture and maps, emissive RGB, an unlit switch, how its alpha shows, and whether
it is double-sided. Mesh color still tints the result. A material's texture overrides the
Mesh texture; without either, an imported model keeps its own textures.

Four maps add detail across a surface. **normal_texture** is a tangent-space normal map with
green pointing to the top of the image, as glTF has it. **metallic_roughness_texture** holds
roughness in green and metallic in blue, multiplying `roughness` and `metallic`.
**emissive_texture** multiplies `emissive_color`, so set that colour too (white shows the map
as it is). **occlusion_texture** holds, in red, how much ambient and sky light reaches each
point. A map the material leaves unset falls back to the model's own, so you can replace just
one of an imported model's maps.

For a reusable material, create a `.material.zon` file under `resources/`:

```zig
.{
    .color = .{ 1, 0.8, 0.3, 1 },
    .metallic = 0.8,
    .roughness = 0.25,
    .texture = "resources/art/metal.png",
    .normal_texture = "resources/art/metal_normal.png",
    .metallic_roughness_texture = "resources/art/metal_orm.png",
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
packaged vertices, and their parts keep the glTF material's normal, metallic-roughness,
emissive and occlusion maps, alpha mode and cutoff, and double-sidedness. An assigned
Material overrides those factors. The model format changed: rebuild packaged models rather
than reusing older `.eggmodel` files.

A material's **shader** slot takes a surface shader, which changes the surface before it is
lit; see [Post-processing and shaders](../guides/post-processing-and-shaders.md).

With **alpha_mode** `.cutout`, the default, alpha below `alpha_cutoff` is discarded and the
rest is opaque. With `.blend`, the surface mixes over whatever is behind it, for glass,
smoke, water or a fading object. Blended surfaces are drawn after every opaque one, farthest
first by each entity's origin, and don't hide what is drawn after them, so two blended
surfaces crossing each other can sort wrongly; split them into separate entities if they do.
Blended surfaces cast no shadows. Sprites take the same `alpha_mode`.

Only a surface's front faces are drawn: the side its normals face, counter-clockwise as
seen from there. Set **double_sided** for leaves, cloth or a plane you see from both sides.
Sprites and tilemaps are always double-sided.

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
exposure reference of 1000. Emissive surfaces are included before exposure. With the
Environment's default **surface** tone mapping, lit surfaces fit themselves with an ACES
curve and unlit materials are not mapped; the other tone mappings map the whole image
afterwards. See [Post-processing and shaders](../guides/post-processing-and-shaders.md).

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

Give the Environment a **sky** to show an image behind the scene: a panorama twice as wide as
it is tall, with the horizon across its middle and straight ahead (-z) in its middle column.
The sky then lights the scene in place of `ambient_color`, softly from every side and in
reflections, which are sharper on smoother surfaces. `sky_intensity` sets how bright it looks
and lights; `ambient_intensity` still scales its light, and the default 0.03 leaves it as is.

A high-dynamic-range panorama (Radiance `.hdr` or OpenEXR `.exr`) keeps light brighter than
white, so a sun in it lights and reflects as brightly as it was captured; a PNG or JPEG sky
stops at white. Lower `sky_intensity` if an HDR sky is brighter than the scene's lights.

```zig
try app.lighting().setEnvironment(.{ .sky = .init("resources/sky/meadow.hdr"), .sky_intensity = 1.5 });
```

Positive exposure EV doubles brightness per stop; negative EV halves it. Disabling
`default_light` removes the fallback light, not the ambient term. Multiple Environment
components without a resource override report an error. The Environment's `post` holds the
scene's tone mapping, bloom and colour grading.

## Shadows

Enable **casts_shadows** on one directional light, or select it explicitly:

```zig
try app.lighting().setShadowCaster(sun);
// Disable all authored shadow casters.
try app.lighting().setShadowCaster(null);
```

The code API validates the requested entity before changing the existing selection, and
leaves point and spot lights' shadows alone; selecting one of those reports
`UnsupportedShadowLight`. Authoring multiple directional shadow casters reports an error.

Point and spot lights cast shadows too: turn on their own **casts_shadows**. A spot light
takes one shadow map and a point light six (one for each side of a cube round it), out of
sixteen they share; asking for more reports `TooManyShadowLights`. Their maps reach as far
as the light's `range_m`, and they don't depend on the camera.

Graphics settings select **off**, **low** (1024), **medium** (2048) or **high** (4096)
shadow maps, plus shadow distance in metres and depth bias. Point and spot lights share one
map of that size, a quarter of it across for each of theirs. One texel-stabilized map
follows each view's camera; a 3×3 PCF filter softens edges, and alpha-cutout materials
also cut out the shadow. Increasing distance trades nearby detail for coverage.
Quality is bounded by the selected GPU's maximum texture size.

The directional light uses one map, not cascades. Global illumination and ray tracing are
not implemented.

Remove just a light with `try app.lighting().removeLight(entity)`. Borrowed material/light
services and component pointers must not survive world reset or library replacement.
