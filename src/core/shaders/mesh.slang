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
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float4 world = input.model0 * input.position.x + input.model1 * input.position.y + input.model2 * input.position.z + input.model3;
    VertexOutput output;
    output.position = view_projection0 * world.x + view_projection1 * world.y + view_projection2 * world.z + view_projection3 * world.w;
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
