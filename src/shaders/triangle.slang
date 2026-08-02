struct VertexOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

struct VertexInput {
    float2 position : TEXCOORD0;
    float2 uv : TEXCOORD1;
};

struct Scene {
    column_major float4x4 model;
    column_major float4x4 view;
    column_major float4x4 proj;
};

[[vk::binding(0, 0)]]
ConstantBuffer<Scene> scene;

float rand(float2 co) {
    return frac(sin(dot(co, float2(12.9898, 78.233))) * 43758.5453);
}

[shader("vertex")]
VertexOutput vsMain(VertexInput input) {
    VertexOutput output;

    float4 localPosition = float4(input.position, 0.0, 1.0);
    output.position =
        mul(scene.proj, mul(scene.view, mul(scene.model, localPosition)));

    output.uv = input.uv;
    return output;
}

[shader("fragment")]
float4 psMain(VertexOutput input) : SV_Target0 {
    float noise = rand(input.position.xy + input.uv);
    return float4(noise, noise, noise, 1.0);
}
