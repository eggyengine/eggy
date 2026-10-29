// A project's post pass: its `post` function, put in at "eggy: post" (`compose.zig`), run over
// every pixel of the HDR scene before bloom and grading. Never compiled on its own.
#include "eggy.slang"

struct PostVertexOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float2 uv : TEXCOORD0;
};

[[vk::binding(0, 0)]]
Texture2D eggy_scene : register(t0, space0);
[[vk::binding(1, 0)]]
SamplerState eggy_scene_sampler : register(s1, space0);
[[vk::binding(0, 1)]]
cbuffer EggyPass : register(b0, space1) {
    float4 eggy_values; // the pass's values
    float4 eggy_frame;  // x: seconds the game has run
};

// The scene's linear HDR light at `uv` (0 to 1 from the top left), before this pass.
float3 sceneColor(float2 uv) {
    return eggy_scene.SampleLevel(eggy_scene_sampler, uv, 0).rgb;
}

// eggy: post

[shader("pixel")]
float4 fragmentMain(PostVertexOutput vertex) : SV_Target0 {
    uint width, height;
    eggy_scene.GetDimensions(width, height);
    PostInput input;
    input.uv = vertex.uv;
    input.texel = float2(1.0 / float(width), 1.0 / float(height));
    input.time_s = eggy_frame.x;
    input.values = eggy_values;
    return post(input);
}
