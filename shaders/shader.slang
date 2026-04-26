import camera;

struct VertexInput {
    float3 inPosition;
    float3 inColour;
    float2 inTexCoord;
};

struct VertexOutput {
    float4 position : SV_Position;
    float3 colour;
    float2 fragTexCoord;
};

ConstantBuffer<Camera3D> ubo;

[shader("vertex")]
VertexOutput vertMain(VertexInput input) {
    VertexOutput output;
    output.position = mul(ubo.proj, mul(ubo.view, mul(ubo.model, float4(input.inPosition, 1.0))));
    output.colour = input.inColour;
    output.fragTexCoord = input.inTexCoord;
    return output;
}

Sampler2D texture;

[shader("fragment")]
float4 fragMain(VertexOutput inVert) : SV_Target {
    return texture.Sample(inVert.fragTexCoord);
}