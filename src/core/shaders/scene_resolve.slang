struct VertexInput {
    [[vk::location(0)]] float2 uv : TEXCOORD0;
};
struct VertexOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float2 uv : TEXCOORD0;
};
[[vk::binding(0, 0)]]
Texture2D scene : register(t0, space0);
[[vk::binding(1, 0)]]
SamplerState scene_sampler : register(s1, space0);
[[vk::binding(2, 0)]]
cbuffer Options : register(b2, space0) {
    float4 texel; // xy: reciprocal source size; z: FXAA enabled
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = float4(input.uv.x * 2.0 - 1.0, 1.0 - input.uv.y * 2.0, 0.0, 1.0);
    output.uv = input.uv;
    return output;
}

float luma(float3 color) {
    return sqrt(max(dot(color, float3(0.299, 0.587, 0.114)), 0.0));
}

// SampleLevel, not Sample: FXAA branches on what it read, and WGSL allows Sample's implicit
// level only in uniform control flow. The scene has one level, so the result is the same.
[shader("pixel")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
    float4 center = scene.SampleLevel(scene_sampler, input.uv, 0);
    if (texel.z < 0.5) return center;
    float3 nw = scene.SampleLevel(scene_sampler, input.uv + float2(-1, -1) * texel.xy, 0).rgb;
    float3 ne = scene.SampleLevel(scene_sampler, input.uv + float2(1, -1) * texel.xy, 0).rgb;
    float3 sw = scene.SampleLevel(scene_sampler, input.uv + float2(-1, 1) * texel.xy, 0).rgb;
    float3 se = scene.SampleLevel(scene_sampler, input.uv + float2(1, 1) * texel.xy, 0).rgb;
    float middle = luma(center.rgb);
    float a = luma(nw), b = luma(ne), c = luma(sw), d = luma(se);
    float low = min(middle, min(min(a, b), min(c, d)));
    float high = max(middle, max(max(a, b), max(c, d)));
    if (high - low < max(0.0312, high * 0.125)) return center;
    float2 direction = float2(-((a + b) - (c + d)), (a + c) - (b + d));
    float reduction = max((a + b + c + d) * (0.25 * 0.125), 1.0 / 128.0);
    direction = clamp(direction / (min(abs(direction.x), abs(direction.y)) + reduction), -8.0, 8.0) * texel.xy;
    float3 narrow = 0.5 * (
        scene.SampleLevel(scene_sampler, input.uv + direction * (1.0 / 3.0 - 0.5), 0).rgb +
        scene.SampleLevel(scene_sampler, input.uv + direction * (2.0 / 3.0 - 0.5), 0).rgb);
    float3 wide = narrow * 0.5 + 0.25 * (
        scene.SampleLevel(scene_sampler, input.uv - direction * 0.5, 0).rgb +
        scene.SampleLevel(scene_sampler, input.uv + direction * 0.5, 0).rgb);
    float wide_luma = luma(wide);
    return float4(wide_luma < low || wide_luma > high ? narrow : wide, center.a);
}
