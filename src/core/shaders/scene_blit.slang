// Copies the scene texture into the current viewport: one oversized triangle covers it.

struct VertexOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float2 uv : TEXCOORD0;
};

[[vk::binding(0, 0)]] Texture2D scene;
[[vk::binding(1, 0)]] SamplerState scene_sampler;

struct VertexInput {
    // (0, 0), (2, 0) and (0, 2): texture coordinates, so (0, 0) to (1, 1) spans the viewport.
    [[vk::location(0)]] float2 uv : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    float2 uv = input.uv;
    // uv (0, 0) is the viewport's top-left corner.
    output.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    output.uv = uv;
    return output;
}

[shader("pixel")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
    return scene.Sample(scene_sampler, input.uv);
}
