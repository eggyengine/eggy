// The scene's backdrop: a gradient over the scene's part of the window, at the far plane.
struct VertexInput {
    [[vk::location(0)]] float2 position : POSITION;
    [[vk::location(1)]] float3 color : COLOR0;
};

struct VertexOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float3 color : COLOR0;
};

[[vk::binding(0, 0)]]
cbuffer Scene : register(b0, space0) {
    float4 screen;  // center and half-size in window NDC
    float4 options; // x: 1 when the target is sRGB
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = float4(screen.xy + input.position * screen.zw, 0.999, 1.0);
    output.color = input.color;
    return output;
}

[shader("pixel")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
    float3 color = options.x > 0.5 ? pow(input.color, float3(2.2, 2.2, 2.2)) : input.color;
    return float4(color, 1.0);
}
