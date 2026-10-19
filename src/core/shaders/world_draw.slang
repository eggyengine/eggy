struct VertexInput {
    [[vk::location(0)]] float3 position;
    [[vk::location(1)]] float2 uv;
    [[vk::location(2)]] float4 tint;
};
struct VertexOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float2 uv;
    [[vk::location(1)]] float4 tint;
};
[[vk::binding(0, 0)]]
cbuffer WorldCamera : register(b0, space0) {
    float4 projection0;
    float4 projection1;
    float4 projection2;
    float4 projection3;
    float4 options;
};
[[vk::binding(0, 1)]]
Texture2D paint : register(t0, space1);
[[vk::binding(1, 1)]]
SamplerState paint_sampler : register(s1, space1);

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = projection0 * input.position.x + projection1 * input.position.y + projection2 * input.position.z + projection3;
    output.uv = input.uv;
    output.tint = input.tint;
    return output;
}
[shader("pixel")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
    float4 color = paint.Sample(paint_sampler, input.uv) * input.tint;
    if (color.a <= 0.001) discard;
    if (options.x > 0.5) color.rgb = pow(max(color.rgb, 0.0), float3(2.2, 2.2, 2.2));
    return color;
}
