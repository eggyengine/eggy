struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float3 color : COLOR0;
    [[vk::location(2)]] float kind : TEXCOORD0;
};

struct VertexOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float3 color : COLOR0;
};

[[vk::binding(0, 0)]]
cbuffer Scene : register(b0, space0) {
    float4 rotation;   // sin/cos of yaw, then sin/cos of pitch
    float4 screen;     // center and half-size in window NDC
    float4 projection; // aspect ratio, focal length, sRGB target
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    if (input.kind > 0.5) {
        output.position = float4(screen.xy + input.position.xy * screen.zw, 0.999, 1.0);
    } else {
        float x = input.position.x * rotation.y + input.position.z * rotation.x;
        float z = -input.position.x * rotation.x + input.position.z * rotation.y;
        float y = input.position.y * rotation.w - z * rotation.z;
        z = input.position.y * rotation.z + z * rotation.w + 4.8;
        float4 clip = float4(x * projection.y / projection.x, y * projection.y,
            (z * 30.0 - 3.0) / 29.9, z);
        output.position = float4(clip.xy * screen.zw + screen.xy * clip.w, clip.zw);
    }
    output.color = input.color;
    return output;
}

[shader("pixel")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
    float3 color = projection.z > 0.5 ? pow(input.color, float3(2.2, 2.2, 2.2)) : input.color;
    return float4(color, 1.0);
}
