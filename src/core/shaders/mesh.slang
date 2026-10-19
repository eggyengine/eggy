// Meshes with authored metallic/roughness materials and directional/point scene lights.
struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float3 normal : NORMAL;
    [[vk::location(2)]] float4 model0 : TEXCOORD0;
    [[vk::location(3)]] float4 model1 : TEXCOORD1;
    [[vk::location(4)]] float4 model2 : TEXCOORD2;
    [[vk::location(5)]] float4 model3 : TEXCOORD3;
    [[vk::location(6)]] float4 color : COLOR0;
    [[vk::location(7)]] float2 uv : TEXCOORD4;
    [[vk::location(8)]] float4 surface_color : COLOR1;
    [[vk::location(9)]] float4 material_params : TEXCOORD5;
    [[vk::location(10)]] float4 emissive_cutoff : TEXCOORD6;
    [[vk::location(11)]] float4 imported_color : COLOR2;
    [[vk::location(12)]] float2 imported_material : TEXCOORD7;
    [[vk::location(13)]] float3 imported_emissive : TEXCOORD8;
};

struct VertexOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float3 normal : NORMAL;
    [[vk::location(1)]] float4 color : COLOR0;
    [[vk::location(2)]] float2 uv : TEXCOORD0;
    [[vk::location(3)]] float3 world : TEXCOORD1;
    [[vk::location(4)]] float4 material : TEXCOORD2;
    [[vk::location(5)]] float4 emissive_cutoff : TEXCOORD3;
};

struct SceneLight {
    float4 position_kind;
    float4 direction_range;
    float4 color_intensity;
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
    float4 eye;
    float4 light_info;       // x: number of scene lights
    SceneLight lights[16];
};

// The texture the mesh is painted with, and how it is sampled.
[[vk::binding(0, 1)]]
Texture2D paint : register(t0, space1);
[[vk::binding(1, 1)]]
SamplerState paint_sampler : register(s1, space1);

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
    // Cofactors give the inverse-transpose normal without a matrix inverse per vertex.
    float3 cof0 = cross(input.model1.xyz, input.model2.xyz);
    float3 cof1 = cross(input.model2.xyz, input.model0.xyz);
    float3 cof2 = cross(input.model0.xyz, input.model1.xyz);
    float determinant = dot(input.model0.xyz, cof0);
    output.normal = (cof0 * input.normal.x + cof1 * input.normal.y + cof2 * input.normal.z) * (determinant < 0 ? -1.0 : 1.0);
    bool authored = input.material_params.w > 0.5;
    output.color = input.color * (authored ? input.surface_color : input.imported_color);
    output.uv = input.uv;
    output.world = world.xyz;
    output.material = authored ? input.material_params : float4(input.imported_material, 0, 0);
    output.emissive_cutoff = authored ? input.emissive_cutoff : float4(input.imported_emissive, 0.01);
    return output;
}

float3 unit(float3 value) {
    return value / max(length(value), 0.00001);
}

float3 surfaceLight(float3 base, float metallic, float roughness, float3 normal, float3 view, float3 incoming, float3 radiance) {
    const float pi = 3.14159265;
    float ndl = max(dot(normal, incoming), 0.0);
    float ndv = max(dot(normal, view), 0.0001);
    float3 half_vector = unit(view + incoming);
    float ndh = max(dot(normal, half_vector), 0.0);
    float vdh = max(dot(view, half_vector), 0.0);
    float alpha = max(roughness * roughness, 0.0025);
    float alpha2 = alpha * alpha;
    float denominator = ndh * ndh * (alpha2 - 1.0) + 1.0;
    float distribution = alpha2 / max(pi * denominator * denominator, 0.000001);
    float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    float geometry = ndv / (ndv * (1.0 - k) + k) * ndl / max(ndl * (1.0 - k) + k, 0.0001);
    float3 fresnel0 = lerp(float3(0.04, 0.04, 0.04), base, metallic);
    float3 fresnel = fresnel0 + (1.0 - fresnel0) * pow(1.0 - vdh, 5.0);
    float3 specular = distribution * geometry * fresnel / max(4.0 * ndv * ndl, 0.0001);
    float3 diffuse = (1.0 - fresnel) * (1.0 - metallic) * base / pi;
    return (diffuse + specular) * radiance * ndl;
}

[shader("pixel")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
    float4 texel = paint.Sample(paint_sampler, input.uv);
    float alpha = input.color.a * texel.a;
    if (alpha < input.emissive_cutoff.w) discard;
    float3 base = pow(max(input.color.rgb * texel.rgb, 0.0), float3(2.2, 2.2, 2.2));
    float3 normal = unit(input.normal);
    float3 view = unit(eye.xyz - input.world);
    float3 color = base;
    if (input.material.z < 0.5) {
        color = base * 0.03;
        if (light_info.x < 0.5) {
            // Keep scenes without authored lights visible in both the editor and runtime.
            if (input.material.w > 0.5 || input.material.x > 0.0 || input.material.y < 0.999) {
                color += surfaceLight(base, saturate(input.material.x), clamp(input.material.y, 0.05, 1.0), normal, view, unit(light.xyz), float3(3.0, 3.0, 3.0));
            } else {
                float lit = 0.3 + 0.7 * max(dot(normal, unit(light.xyz)), 0.0);
                color = base * lit;
            }
        }
        for (int i = 0; i < int(light_info.x); ++i) {
            SceneLight current = lights[i];
            float3 incoming = -current.direction_range.xyz;
            float attenuation = 1.0;
            if (current.position_kind.w > 0.5) {
                float3 offset = current.position_kind.xyz - input.world;
                float distance2 = dot(offset, offset);
                float distance = sqrt(distance2);
                incoming = unit(offset);
                float falloff = saturate(1.0 - pow(distance / max(current.direction_range.w, 0.001), 4.0));
                attenuation = falloff * falloff / max(distance2, 0.01);
            }
            float3 radiance = current.color_intensity.rgb * current.color_intensity.w * attenuation;
            color += surfaceLight(base, saturate(input.material.x), clamp(input.material.y, 0.05, 1.0), normal, view, incoming, radiance);
        }
    }
    color += input.emissive_cutoff.rgb;
    // sRGB targets encode linear output themselves; other targets need explicit encoding.
    color = options.x > 0.5 ? color : pow(max(color, 0.0), float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));
    return float4(color, alpha);
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
    output.uv = input.uv;
    output.world = world.xyz;
    output.material = float4(0, 1, 0, 0);
    output.emissive_cutoff = float4(0, 0, 0, 0);
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
    output.uv = input.uv;
    output.world = world.xyz;
    output.material = float4(0, 1, 0, 0);
    output.emissive_cutoff = float4(0, 0, 0, 0);
    return output;
}

[shader("pixel")]
float4 fragmentOutline(VertexOutput input) : SV_Target0 {
    float3 color = options.x > 0.5 ? pow(input.color.rgb, float3(2.2, 2.2, 2.2)) : input.color.rgb;
    return float4(color, 1.0);
}
