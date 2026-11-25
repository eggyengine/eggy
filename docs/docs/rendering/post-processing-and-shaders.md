---
title: Post-processing and shaders
sidebar_position: 3
description: Tone mapping, bloom and grading, and Slang post and surface shaders.
---

Eggy renders the scene in HDR, keeping light brighter than white until the end, then fits
it to the screen with **post-processing**. That last step can tone map, bloom and grade the
image. You can also add your own passes and change how a material's surface looks with
**shaders** written in [Slang](https://shader-slang.org).

## Set the look of a scene

Add an **Environment** to any entity in the scene (it may already have one). Its **post**
settings are the scene's look:

| Setting | What it does |
| --- | --- |
| **tone_mapping** | How bright light fits the screen. **aces** (the default) is a filmic curve, **agx** keeps hues as they brighten, **reinhard** is gentle, and **none** clips at white. **surface** is Eggy's original look, which scenes made before keep: lit surfaces fit themselves and nothing else is mapped. |
| **bloom** | Light above **threshold** glows into its surroundings, at **intensity** (0.04 by default). 0 is off. |
| **contrast** | 1 leaves it as it is; higher pushes tones apart. |
| **saturation** | 1 leaves colour as it is; 0 is black and white. |
| **vignette** | Darkens the corners, from 0 (none) to 1. |
| **passes** | Your own post shaders, run in order (see below). |

Bloom works best with a tone mapping other than **surface**. Under **surface**, lit
surfaces are already squeezed below white, so only bright unlit and emissive things glow.
For a glowing object, give its material an **emissive_color** above 1.

The image is dithered as it is shown, so smooth gradients such as skies, fog and the vignette
don't band. The Scene panel shows the look as you change it.

## Give one camera its own look

Add a **PostProcess** component to a Camera. While that camera is the active one, its
settings replace the Environment's: a dream sequence, a security camera, or a hurt
player's view. Remove the component to go back to the scene's look.

From code, change the settings like any component:

```zig
if (app.world.get(camera, eggy.PostProcess)) |post| {
    post.saturation = 0.2;
    post.vignette = 0.6;
}
```

## Write a post shader

A post shader runs once for every pixel of the image, before bloom and tone mapping, so it
sees the scene's real light values.

1. In Assets, choose **New > Rendering > Post Shader**. It makes a `.slang` file that fades the image
   towards grey.
2. Open it in your code editor:

   ```slang
   #include "eggy.slang"

   float4 post(PostInput input) {
       float3 color = sceneColor(input.uv);
       color = lerp(color, luminance(color).xxx, saturate(input.values.x));
       return float4(color, 1.0);
   }
   ```

3. Select the entity with the Environment (or a camera's PostProcess). Drag the shader
   onto one of **passes**' **shader** slots, and set its **values**. Here the first value is
   how grey the image gets.

:::tip Code editors
When the editor opens your project it writes Eggy's shader library to `.eggy/shaders/eggy.slang`.
With VS Code, VSCodium or Cursor as your code editor (Edit > Settings), it also adds that
folder to `.vscode/settings.json`, so the Slang extension finds `#include "eggy.slang"` and
completes `PostInput` and the rest. In another editor, add `.eggy/shaders` (as an absolute
path) to its Slang language server's include paths.
:::

`#include "eggy.slang"` gives your shader everything below. The function must be called `post`
and take a `PostInput`:

| In `PostInput` | Meaning |
| --- | --- |
| `uv` | Where this pixel is, 0 to 1 from the top left |
| `texel` | One pixel's size in `uv`, for reading neighbours |
| `time_s` | Seconds the game has run; stands still while you edit or pause |
| `values` | The pass's four **values** |

`sceneColor(uv)` reads the image at any point, so a pass can blur, distort or outline.
Return the new colour in linear light; values above 1 are fine.

Up to four passes run, each reading what the one before it wrote.

## Write a surface shader

A surface shader changes how a material's surface looks before it is lit: patterns,
pulsing glows, colour by height. Eggy still lights and shadows the result.

1. Choose **New > Rendering > Surface Shader**. It makes a `.slang` file with a slow glow.
2. Edit it:

   ```slang
   #include "eggy.slang"

   Surface surface(SurfaceInput input) {
       Surface shown = defaultSurface(input);
       // Stripes across the world, two metres apart.
       float band = step(0.5, frac(input.world_position.x * 0.5));
       shown.base_color *= lerp(0.6, 1.0, band);
       return shown;
   }
   ```

3. Give a Mesh entity a **Material** and drag the shader onto its **shader** slot. A
   `.material.zon` file takes a shader too: `.shader = "resources/shaders/stripes.slang"`.

The function must be called `surface`. `defaultSurface(input)` is the surface exactly as
the material describes it; start from it and change what you need.

| In `SurfaceInput` | Meaning |
| --- | --- |
| `world_position` | The point in the world |
| `normal`, `view_direction` | Which way it faces (bent by its normal map), and towards the camera, both unit length |
| `uv` | Its texture coordinates |
| `color` | The material's colour times its texture, in linear light, with alpha |
| `metallic`, `roughness`, `emissive`, `unlit` | The material's values, times its maps |
| `time_s` | Seconds the game has run |

| In `Surface` | Meaning |
| --- | --- |
| `base_color` | Its colour, in linear light |
| `alpha` | Below the material's **alpha_cutoff** the point isn't drawn; a blended material mixes by it |
| `metallic`, `roughness` | How it reflects light |
| `emissive` | Light it gives off, added after lighting |
| `normal` | Which way it faces, for lighting |
| `unlit` | Show `base_color` as it is, unlit |

Shadows ignore a surface shader's `alpha`: they follow the material's own colour and
texture.

## Write a terrain shader

A terrain shader colours a [Terrain](procedural-terrain.md)'s faces before they are lit. Make
a `.slang` file whose function is called `terrainSurface`, and drag it onto the Terrain's
**shader** slot:

```slang
#include "eggy.slang"

Surface terrainSurface(TerrainSurfaceInput input) {
    Surface shown = defaultTerrainSurface(input);
    // Snow on faces above values[0].x metres that are flat enough to hold it.
    float snow = step(input.values[0].x, input.face_position.y) * step(0.7, input.normal.y);
    shown.base_color = lerp(shown.base_color, float3(0.9, 0.92, 0.95), snow);
    return shown;
}
```

`defaultTerrainSurface(input)` is the face as the Terrain's own colours paint it. Colour by
what is the same across a face, and the ground keeps its facets.

| In `TerrainSurfaceInput` | Meaning |
| --- | --- |
| `world_position`, `view_direction` | The point in the world, and towards the camera |
| `normal` | Which way the face looks, unit length |
| `face_position` | The middle of the face, in the world |
| `face_random` | -1 to 1, the same every time for the same face |
| `color`, `roughness` | The Terrain's own colour for the face, in linear light, and its roughness |
| `attributes` | The grid's four bytes at the face's first corner, each 0 to 1; 0 without any |
| `values` | The Terrain's `values`, four `float4`s |
| `time_s` | Seconds the game has run |

It returns a `Surface`, as a surface shader does. Shadows ignore it.

## When a shader has a mistake

The editor compiles a shader the first time something uses it, and again when you come back
to the editor after changing it. If it doesn't compile, the Console shows Slang's message,
pointing at the line in your file, and the mesh or pass is drawn without it.

A shader is a post shader if it takes a `PostInput`, a surface shader if it takes a
`SurfaceInput`, and a terrain shader if it takes a `TerrainSurfaceInput`. Putting one in
another's slot is reported in the Console and skipped.

When you build or export the game, every shader is compiled ahead of time for the platform,
web included, so a mistake stops the build with the same message.
