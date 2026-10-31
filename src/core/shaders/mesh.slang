// Metallic/roughness surfaces with their maps, lit by scene lights (shadowed through PCF: the
// directional light's map and point and spot lights' shared one) and by the sky or a flat
// ambient; and the sky behind them. A material's surface shader is put in at "eggy: surface"
// (`compose.zig`), replacing `defaultSurface`.
#include "eggy.slang"

// No semantics on the varyings: Slang's WGSL numbers semantic'd inputs its own way, ignoring
// vk::location, while without them it numbers them in order, as vk::location does.
struct VertexInput {
    [[vk::location(0)]] float3 position;
    [[vk::location(1)]] float3 normal;
    [[vk::location(2)]] float4 model0;
    [[vk::location(3)]] float4 model1;
    [[vk::location(4)]] float4 model2;
    [[vk::location(5)]] float4 model3;
    [[vk::location(6)]] float4 color;
    [[vk::location(7)]] float2 uv;
    [[vk::location(8)]] float4 surface_color;
    [[vk::location(9)]] float4 material_params;
    [[vk::location(10)]] float4 emissive_cutoff;
    [[vk::location(11)]] float4 imported_color;
    [[vk::location(12)]] float2 imported_material;
    [[vk::location(13)]] float3 imported_emissive;
    [[vk::location(14)]] float4 uv_rect; // the part of the texture drawn: left, top, right, bottom
};

struct VertexOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float3 normal;
    [[vk::location(1)]] float4 color;
    [[vk::location(2)]] float2 uv;
    [[vk::location(3)]] float3 world;
    [[vk::location(4)]] float4 material;
    [[vk::location(5)]] float4 emissive_cutoff;
};

struct SceneLight {
    float4 position_kind;
    float4 direction_range;
    float4 color_intensity;
    float4 cone_shadow;
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
    float4 light_info;       // x: number of scene lights, y: seconds the game has run
    float4 ambient;
    float4 environment;      // exposure multiplier, fallback light, shadow-light index, post pass maps tones
    float4 shadow_matrix0;
    float4 shadow_matrix1;
    float4 shadow_matrix2;
    float4 shadow_matrix3;
    float4 shadow_params;    // bias, reciprocal map size, light index, enabled
    SceneLight lights[16];
    float4 local_shadow_matrices[64]; // each point and spot shadow map's matrix, by column
    float4 local_shadow_params;       // reciprocal shared texture size, maps across it
    float4 sky_rays[3];               // through the view's middle, towards its right and top edges; [0].w: a sky
    float4 sky;                       // brightness shown, brightness as light, mip count
    float4 sky_light[9];              // the sky's light over pi, as spherical harmonics (`sky.zig`)
};

[[vk::binding(1, 0)]]
DepthTexture2D shadow_map : register(t1, space0);
[[vk::binding(2, 0)]]
SamplerComparisonState shadow_sampler : register(s2, space0);
[[vk::binding(3, 0)]]
DepthTexture2D local_shadow_map : register(t3, space0);

// The texture the mesh is painted with, and how it is sampled.
[[vk::binding(0, 1)]]
Texture2D paint : register(t0, space1);
[[vk::binding(1, 1)]]
SamplerState paint_sampler : register(s1, space1);

// Its other maps (`material_maps.zig`); neutral ones where it has none.
[[vk::binding(0, 2)]]
Texture2D normal_map : register(t0, space2);
[[vk::binding(1, 2)]]
Texture2D metallic_roughness_map : register(t1, space2);
[[vk::binding(2, 2)]]
Texture2D emissive_map : register(t2, space2);
[[vk::binding(3, 2)]]
Texture2D occlusion_map : register(t3, space2);
[[vk::binding(4, 2)]]
SamplerState map_sampler : register(s4, space2);
[[vk::binding(5, 2)]]
cbuffer Maps : register(b5, space2) {
    float4 map_flags; // x: 1 with a normal map, y: an imported surface's alpha cutoff
};

// The sky's panorama.
[[vk::binding(0, 3)]]
Texture2D sky_texture : register(t0, space3);
[[vk::binding(1, 3)]]
SamplerState sky_sampler : register(s1, space3);

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
    output.uv = lerp(input.uv_rect.xy, input.uv_rect.zw, input.uv);
    output.world = world.xyz;
    output.material = authored ? input.material_params : float4(input.imported_material, 0, 0);
    output.emissive_cutoff = authored ? input.emissive_cutoff : float4(input.imported_emissive, 0.01);
    return output;
}

static const float pi = 3.14159265;

float3 unit(float3 value) {
    return value / max(length(value), 0.00001);
}

float3 surfaceLight(float3 base, float metallic, float roughness, float3 normal, float3 view, float3 incoming, float3 radiance) {
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

// Where on the sky's panorama direction `d` looks (`sky.zig`'s `direction`, inverted).
float2 skyUv(float3 d) {
    return float2(atan2(d.x, -d.z) / (2.0 * pi) + 0.5, acos(clamp(d.y, -1.0, 1.0)) / pi);
}

float3 skyColor(float3 d, float lod) {
    return pow(max(sky_texture.SampleLevel(sky_sampler, skyUv(d), lod).rgb, 0.0), float3(2.2, 2.2, 2.2));
}

// The sky's light reaching a surface facing `n`, over pi.
float3 skyLight(float3 n) {
    float3 light = sky_light[0].rgb * 0.282095;
    light += sky_light[1].rgb * 0.488603 * n.y + sky_light[2].rgb * 0.488603 * n.z + sky_light[3].rgb * 0.488603 * n.x;
    light += sky_light[4].rgb * 1.092548 * n.x * n.y + sky_light[5].rgb * 1.092548 * n.y * n.z;
    light += sky_light[6].rgb * 0.315392 * (3.0 * n.z * n.z - 1.0) + sky_light[7].rgb * 1.092548 * n.x * n.z;
    light += sky_light[8].rgb * 0.546274 * (n.x * n.x - n.y * n.y);
    return max(light, 0.0);
}

// How much of the surroundings a surface reflects, by angle and roughness (Karis' fit of the
// split-sum lookup, so no table is needed).
float3 environmentBrdf(float3 fresnel0, float roughness, float ndv) {
    float4 r = roughness * float4(-1.0, -0.0275, -0.572, 0.022) + float4(1.0, 0.0425, 1.04, -0.04);
    float a004 = min(r.x * r.x, exp2(-9.28 * ndv)) * r.x + r.y;
    float2 ab = float2(-1.04, 1.04) * a004 + r.zw;
    return fresnel0 * ab.x + ab.y;
}

// `normal` bent by a tangent-space normal map's `texel` (+y towards the image's top), along a
// frame worked out from how `world` and `uv` change across the pixel, so meshes need no tangents.
float3 mappedNormal(float3 normal, float3 world, float2 uv, float3 texel) {
    float3 dp1 = ddx(world);
    float3 dp2 = ddy(world);
    float2 duv1 = ddx(uv);
    float2 duv2 = ddy(uv);
    float3 dp2perp = cross(dp2, normal);
    float3 dp1perp = cross(normal, dp1);
    float3 tangent = dp2perp * duv1.x + dp1perp * duv2.x;
    float3 bitangent = dp2perp * duv1.y + dp1perp * duv2.y;
    float largest = max(dot(tangent, tangent), dot(bitangent, bitangent));
    // A surface without texture coordinates has no frame to bend along.
    if (!(largest > 1e-20)) return normal;
    float scale = rsqrt(largest);
    float3 bent = texel * 2.0 - 1.0;
    return unit(tangent * scale * bent.x - bitangent * scale * bent.y + normal * bent.z);
}

float visibility(float3 world, float ndl) {
    float4 clip = shadow_matrix0 * world.x + shadow_matrix1 * world.y + shadow_matrix2 * world.z + shadow_matrix3;
    float3 point = clip.xyz / clip.w;
    float2 uv = float2(point.x * 0.5 + 0.5, 0.5 - point.y * 0.5);
    if (point.z < 0.0 || point.z > 1.0 || any(uv < 0.0) || any(uv > 1.0)) return 1.0;
    float depth = point.z - shadow_params.x * (1.0 + 2.0 * (1.0 - saturate(ndl)));
    float visible = 0.0;
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x)
            visible += shadow_map.SampleCmpLevelZero(shadow_sampler, uv + float2(x, y) * shadow_params.y, depth);
    return visible / 9.0;
}

// How much of a point or spot light reaches `world` past its shadow map, sampled a little out
// along `normal` (a texel's width there) so a surface doesn't shadow itself.
float localVisibility(SceneLight light, float3 world, float3 normal) {
    float3 offset = world - light.position_kind.xyz;
    int map = int(light.cone_shadow.w + 0.5);
    // A point light's map is the cube side the point is on (`shadows.zig`'s `cube_sides`).
    float tan_half = 1.0913; // a cube side's 95 degrees
    if (light.position_kind.w < 1.5) {
        float3 a = abs(offset);
        if (a.x >= a.y && a.x >= a.z) map += offset.x > 0.0 ? 0 : 1;
        else if (a.y >= a.z) map += offset.y > 0.0 ? 2 : 3;
        else map += offset.z > 0.0 ? 4 : 5;
    } else {
        tan_half = tan(min(acos(clamp(light.cone_shadow.y, -1.0, 1.0)) + 0.0873, 1.4835));
    }
    float across = local_shadow_params.y;
    float map_texel = across * local_shadow_params.x;
    float3 shifted = world + normal * (2.0 * length(offset) * tan_half * map_texel * 1.5);
    float4 clip = local_shadow_matrices[map * 4] * shifted.x + local_shadow_matrices[map * 4 + 1] * shifted.y + local_shadow_matrices[map * 4 + 2] * shifted.z + local_shadow_matrices[map * 4 + 3];
    if (clip.w <= 0.0) return 1.0;
    float3 point = clip.xyz / clip.w;
    float2 uv = float2(point.x * 0.5 + 0.5, 0.5 - point.y * 0.5);
    if (point.z < 0.0 || point.z > 1.0 || any(uv < 0.0) || any(uv > 1.0)) return 1.0;
    // Kept a filter's width inside the map, so it never reads its neighbour's.
    uv = clamp(uv, 1.5 * map_texel, 1.0 - 1.5 * map_texel);
    float2 shared = (float2(float(map % 4), float(map / 4)) + uv) / across;
    float depth = point.z - 0.00002;
    float visible = 0.0;
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x)
            visible += local_shadow_map.SampleCmpLevelZero(shadow_sampler, shared + float2(x, y) * local_shadow_params.x, depth);
    return visible / 9.0;
}

// eggy: surface
#ifndef EGGY_SURFACE
Surface surface(SurfaceInput input) {
    return defaultSurface(input);
}
#endif

[shader("pixel")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
    // The point as the material and its maps (and its surface shader) describe it. Every map is
    // read before anything is discarded, as screen-space derivatives need.
    float4 texel = paint.Sample(paint_sampler, input.uv);
    float3 normal_texel = normal_map.Sample(map_sampler, input.uv).rgb;
    float4 metallic_roughness = metallic_roughness_map.Sample(map_sampler, input.uv);
    float3 emissive_texel = emissive_map.Sample(map_sampler, input.uv).rgb;
    float occlusion = occlusion_map.Sample(map_sampler, input.uv).r;
    float3 geometric = unit(input.normal);
    SurfaceInput described;
    described.world_position = input.world;
    described.normal = map_flags.x > 0.5 ? mappedNormal(geometric, input.world, input.uv, normal_texel) : geometric;
    described.view_direction = unit(eye.xyz - input.world);
    described.uv = input.uv;
    described.color = float4(pow(max(input.color.rgb * texel.rgb, 0.0), float3(2.2, 2.2, 2.2)), input.color.a * texel.a);
    described.metallic = saturate(input.material.x * metallic_roughness.b);
    described.roughness = input.material.y * metallic_roughness.g;
    described.emissive = input.emissive_cutoff.rgb * pow(max(emissive_texel, 0.0), float3(2.2, 2.2, 2.2));
    described.unlit = input.material.z > 0.5;
    described.time_s = light_info.y;
    Surface shown = surface(described);
    float alpha = shown.alpha;
    // An authored material's cutoff comes with the instance, an imported surface's with its maps.
    float cutoff = input.material.w > 0.5 ? input.emissive_cutoff.w : map_flags.y;
    if (alpha < cutoff) discard;
    float3 base = max(shown.base_color, 0.0);
    float3 normal = unit(shown.normal);
    float3 view = described.view_direction;
    float metallic = saturate(shown.metallic);
    float roughness = clamp(shown.roughness, 0.05, 1.0);
    float3 color = base;
    if (!shown.unlit) {
        if (sky_rays[0].w > 0.5) {
            // Lit by the sky: dimly from every side, and reflecting it, blurrier when rougher.
            float ndv = max(dot(normal, view), 0.0001);
            float3 fresnel0 = lerp(float3(0.04, 0.04, 0.04), base, metallic);
            float3 reflected = skyColor(reflect(-view, normal), roughness * max(sky.z - 1.0, 0.0)) * environmentBrdf(fresnel0, roughness, ndv);
            color = (base * (1.0 - metallic) * skyLight(normal) + reflected) * sky.y * occlusion;
        } else {
            color = base * ambient.rgb * ambient.w * (1.0 - metallic) * occlusion;
        }
        if (light_info.x < 0.5 && environment.y > 0.5) {
            // Keep scenes without authored lights visible in both the editor and runtime.
            if (input.material.w > 0.5 || metallic > 0.0 || shown.roughness < 0.999) {
                color += surfaceLight(base, metallic, roughness, normal, view, unit(light.xyz), float3(3.0, 3.0, 3.0));
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
                if (current.position_kind.w > 1.5) {
                    float cone = dot(-incoming, current.direction_range.xyz);
                    attenuation *= smoothstep(current.cone_shadow.y, current.cone_shadow.x, cone);
                }
            }
            if (shadow_params.w > 0.5 && i == int(shadow_params.z))
                attenuation *= visibility(input.world, dot(normal, incoming));
            else if (current.position_kind.w > 0.5 && current.cone_shadow.z > 0.5 && attenuation > 0.0)
                attenuation *= localVisibility(current, input.world, geometric);
            float3 radiance = current.color_intensity.rgb * current.color_intensity.w * 0.001 * attenuation;
            color += surfaceLight(base, metallic, roughness, normal, view, incoming, radiance);
        }
    }
    color += max(shown.emissive, 0.0);
    color *= environment.x;
    // Fit HDR direct lighting into the output range without hard-clipping bright surfaces,
    // unless the post pass maps the whole image's tones.
    if (!shown.unlit && environment.w < 0.5)
        color = saturate((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14));
    // sRGB targets encode linear output themselves; other targets need explicit encoding.
    color = options.x > 0.5 ? color : pow(max(color, 0.0), float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));
    return float4(color, alpha);
}

[shader("pixel")]
void fragmentShadow(VertexOutput input) {
    float alpha = input.color.a * paint.Sample(paint_sampler, input.uv).a;
    float cutoff = input.material.w > 0.5 ? input.emissive_cutoff.w : map_flags.y;
    if (alpha < cutoff) discard;
}

// The sky behind everything: one triangle over the whole view, each pixel looking out along
// its ray. Its corners come in a vertex buffer, as SV_VertexID needs Vulkan's
// shaderDrawParameters.
struct SkyOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float2 ndc;
};

[shader("vertex")]
SkyOutput vertexSky([[vk::location(0)]] float2 corner) {
    SkyOutput output;
    output.position = float4(corner, 0.5, 1.0);
    output.ndc = corner;
    return output;
}

[shader("pixel")]
float4 fragmentSky(SkyOutput input) : SV_Target0 {
    float3 ray = unit(sky_rays[0].xyz + sky_rays[1].xyz * input.ndc.x + sky_rays[2].xyz * input.ndc.y);
    float3 color = skyColor(ray, 0.0) * sky.x * environment.x;
    if (environment.w < 0.5)
        color = saturate((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14));
    color = options.x > 0.5 ? color : pow(max(color, 0.0), float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));
    return float4(color, 1.0);
}

// The selected object's mask: the object itself, at the nearest depth, without colour.
[shader("vertex")]
VertexOutput vertexMask(VertexInput input) {
    float4 world = input.model0 * input.position.x + input.model1 * input.position.y + input.model2 * input.position.z + input.model3;
    float4 clip = toClip(world);
    VertexOutput output;
    output.position = float4(clip.xy, mask_depth * clip.w, clip.w);
    output.normal = float3(0.0, 1.0, 0.0);
    output.color = input.color;
    output.uv = float2(0.0, 0.0);
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
    output.uv = float2(0.0, 0.0);
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
