// Meshes: each instance's model matrix (as columns) places a shape's vertices; one light from
// above lights them, with some ambient so the far side isn't black.
struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float3 normal : NORMAL;
    [[vk::location(2)]] float4 model0 : TEXCOORD0;
    [[vk::location(3)]] float4 model1 : TEXCOORD1;
    [[vk::location(4)]] float4 model2 : TEXCOORD2;
    [[vk::location(5)]] float4 model3 : TEXCOORD3;
    [[vk::location(6)]] float4 color : COLOR0;
};

struct VertexOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float3 normal : NORMAL;
    [[vk::location(1)]] float4 color : COLOR0;
};

[[vk::binding(0, 0)]]
cbuffer Camera : register(b0, space0) {
    float4 view_projection0; // the camera's view-projection matrix, by column
    float4 view_projection1;
    float4 view_projection2;
    float4 view_projection3;
    float4 light;            // xyz: the direction towards the light
    float4 options;          // x: 1 when the target is sRGB
    float4 outline;          // the selection outline's colour
    float4 outline_size;     // xy: the viewport in pixels; z: the outline's width in pixels
};

// The depth a selected object's mask is drawn at (the nearest there is), and its outline's hull
// just behind it: the hull is drawn wherever the mask isn't, in front of everything else.
static const float mask_depth = 0.0;
static const float outline_depth = 0.000001;

float4 toClip(float4 world) {
    return view_projection0 * world.x + view_projection1 * world.y + view_projection2 * world.z + view_projection3 * world.w;
}

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float4 world = input.model0 * input.position.x + input.model1 * input.position.y + input.model2 * input.position.z + input.model3;
    VertexOutput output;
    output.position = toClip(world);
    output.normal = input.model0.xyz * input.normal.x + input.model1.xyz * input.normal.y + input.model2.xyz * input.normal.z;
    output.color = input.color;
    return output;
}

[shader("pixel")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
    float lit = 0.3 + 0.7 * max(dot(normalize(input.normal), normalize(light.xyz)), 0.0);
    float3 color = input.color.rgb * lit;
    color = options.x > 0.5 ? pow(color, float3(2.2, 2.2, 2.2)) : color;
    return float4(color, input.color.a);
}

// The selected object's mask: the object itself, at the nearest depth, without colour.
[shader("vertex")]
VertexOutput vertexMask(VertexInput input) {
    float4 world = input.model0 * input.position.x + input.model1 * input.position.y + input.model2 * input.position.z + input.model3;
    float4 clip = toClip(world);
    VertexOutput output;
    output.position = float4(clip.xy, mask_depth * clip.w, clip.w);
    output.normal = input.normal;
    output.color = input.color;
    return output;
}

// The selection outline: the object's hull, pushed outwards on screen from its centre by the
// outline's width, just behind the mask and in front of everything else.
[shader("vertex")]
VertexOutput vertexOutline(VertexInput input) {
    float4 world = input.model0 * input.position.x + input.model1 * input.position.y + input.model2 * input.position.z + input.model3;
    float4 clip = toClip(world);
    float4 centre = toClip(input.model3);
    float2 half_viewport = outline_size.xy * 0.5;
    float2 away = (clip.xy / clip.w - centre.xy / centre.w) * half_viewport;
    float distance = length(away);
    float2 push = distance > 0.0001 ? away / distance * outline_size.z / half_viewport : float2(0.0, 0.0);
    VertexOutput output;
    output.position = float4(clip.xy + push * clip.w, outline_depth * clip.w, clip.w);
    output.normal = float3(0.0, 1.0, 0.0);
    output.color = outline;
    return output;
}

[shader("pixel")]
float4 fragmentOutline(VertexOutput input) : SV_Target0 {
    float3 color = options.x > 0.5 ? pow(input.color.rgb, float3(2.2, 2.2, 2.2)) : input.color.rgb;
    return float4(color, 1.0);
}
