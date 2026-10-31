// Eggy's shader library: what a project's shader gets by including "eggy", and what Eggy's own
// mesh and post shaders build on. A post shader defines `float4 post(PostInput input)`; a
// surface shader defines `Surface surface(SurfaceInput input)`.
#pragma once

// One pixel of a post pass.
struct PostInput {
    // Where in the image, 0 to 1 from the top left; `sceneColor(uv)` reads the image there.
    float2 uv;
    // One pixel's size in `uv`.
    float2 texel;
    // Seconds the game has run.
    float time_s;
    // The pass's four values, set on its `PostProcess`.
    float4 values;
};

// One point on a mesh, before it is lit.
struct SurfaceInput {
    float3 world_position;
    // Unit length, in the world, bent by the material's normal map.
    float3 normal;
    // Unit length, from the point towards the camera.
    float3 view_direction;
    float2 uv;
    // The material's colour times its texture's, in linear light.
    float4 color;
    // The material's, times its metallic-roughness and emissive maps.
    float metallic;
    float roughness;
    float3 emissive;
    bool unlit;
    // Seconds the game has run.
    float time_s;
};

// How a point looks: what `surface` returns, which Eggy then lights.
struct Surface {
    // Linear light, 0 to 1.
    float3 base_color;
    // Below the material's alpha cutoff the point isn't drawn; a blended material mixes by it.
    float alpha;
    float metallic;
    float roughness;
    // Light the point gives off itself, added after lighting.
    float3 emissive;
    // Unit length, in the world.
    float3 normal;
    // Skip lighting: `base_color` is shown as it is.
    bool unlit;
};

// The surface the material describes, unchanged: start from it and change what you need.
Surface defaultSurface(SurfaceInput input) {
    Surface surface;
    surface.base_color = input.color.rgb;
    surface.alpha = input.color.a;
    surface.metallic = input.metallic;
    surface.roughness = input.roughness;
    surface.emissive = input.emissive;
    surface.normal = input.normal;
    surface.unlit = input.unlit;
    return surface;
}

// How bright a colour looks (Rec. 709 luminance).
float luminance(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}
