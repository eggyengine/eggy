// Metallic/roughness surfaces with their maps, lit by scene lights (with soft shadows: the
// directional light's cascades and point and spot lights' shared map) and by the sky or a flat
// ambient, through height fog; terrain lifted from a height grid and lit the same way; and the
// sky behind them. A material's surface shader is put in at "eggy: surface" (`compose.zig`),
// replacing `defaultSurface`.
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
    float4 shadow_matrices[16]; // each directional cascade's matrix, by column
    float4 shadow_splits;       // how far along the view each cascade reaches, in metres
    float4 shadow_texels;       // one texel's width in each cascade, in metres
    float4 view_forward;        // xyz: the way the view looks
    float4 shadow_params;       // bias, reciprocal map size, light index, enabled
    SceneLight lights[16];
    float4 local_shadow_matrices[64]; // each point and spot shadow map's matrix, by column
    float4 local_shadow_params;       // reciprocal shared texture size, maps across it
    float4 sky_rays[3];               // through the view's middle, towards its right and top edges; [0].w: a sky
    float4 sky;                       // brightness shown, brightness as light, mip count
    float4 sky_light[9];              // the sky's light over pi, as spherical harmonics (`sky.zig`)
    float4 fog;                       // rgb: its colour, a: its density at its height, per metre
    float4 fog_shape;                 // x: that height, y: how fast it thins going up, z: how far the sky is
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

float3 surfaceLight(float3 base, float metallic, float roughness, float3 normal, float3 view, float3 incoming, float3 radiance, float3 energy) {
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
    float3 specular = energy * distribution * geometry * fresnel / max(4.0 * ndv * ndl, 0.0001);
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

// How much of the surroundings a surface reflects, by angle and roughness, as a scale and bias
// on its fresnel0 (Karis' fit of the split-sum lookup, so no table is needed).
float2 environmentBrdf(float roughness, float ndv) {
    float4 r = roughness * float4(-1.0, -0.0275, -0.572, 0.022) + float4(1.0, 0.0425, 1.04, -0.04);
    float a004 = min(r.x * r.x, exp2(-9.28 * ndv)) * r.x + r.y;
    return float2(-1.04, 1.04) * a004 + r.zw;
}

// What single-scattering specular misses on rough surfaces, which bounce light between their
// microfacets: added back so rough metals don't darken (Fdez-Aguera).
float3 multipleScattering(float3 fresnel0, float2 brdf) {
    return 1.0 + fresnel0 * (1.0 / max(brdf.x + brdf.y, 0.0001) - 1.0);
}

// How much of the sky's reflection reaches a surface its occlusion map darkens (Lagarde).
float specularOcclusion(float ndv, float occlusion, float roughness) {
    return saturate(pow(ndv + occlusion, exp2(-16.0 * roughness - 1.0)) - 1.0 + occlusion);
}

// Rougher where the normal changes quickly across the pixel, so small highlights on curved or
// normal-mapped surfaces don't sparkle (Tokuyoshi and Kaplanyan).
float stableRoughness(float3 normal, float roughness) {
    float3 across = ddx(normal);
    float3 down = ddy(normal);
    float variance = 0.25 * (dot(across, across) + dot(down, down));
    float alpha2 = roughness * roughness * roughness * roughness;
    return sqrt(sqrt(saturate(alpha2 + min(2.0 * variance, 0.18))));
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

// A different number for each pixel in a fine, even pattern (Jimenez's interleaved gradient
// noise), to turn shadow taps and dither cascade changes without visible repeats.
float pixelNoise(float2 pixel) {
    return frac(52.9829189 * frac(dot(pixel, float2(0.06711056, 0.00583715))));
}

static const int shadow_taps = 12;

// How much of `map` at `uv` lies past `depth`: taps spread evenly over a disk `radius` wide (by
// the golden angle), turned by `angle`, kept between `lowest` and `highest` so none reads a
// neighbouring map. Each tap compares and blends four texels itself.
float filteredShadow(DepthTexture2D map, float2 uv, float depth, float radius, float2 lowest, float2 highest, float angle) {
    float visible = 0.0;
    for (int i = 0; i < shadow_taps; ++i) {
        float theta = float(i) * 2.3999632 + angle;
        float2 tap = sqrt((float(i) + 0.5) / float(shadow_taps)) * float2(cos(theta), sin(theta));
        visible += map.SampleCmpLevelZero(shadow_sampler, clamp(uv + tap * radius, lowest, highest), depth);
    }
    return visible / float(shadow_taps);
}

static const int cascades = 4;
// The share of a cascade, at its far end, fading into the next (`shadows.cascade_blend`).
static const float cascade_blend = 0.1;

// How much of the directional light reaches `world` in `cascade`, sampled a little out along
// `normal` (wider the coarser the cascade) so a surface doesn't shadow itself.
float cascadeVisibility(int cascade, float3 world, float3 normal, float ndl, float noise) {
    float3 shifted = world + normal * shadow_texels[cascade] * (1.0 + saturate(1.0 - ndl));
    int column = cascade * 4;
    float4 clip = shadow_matrices[column] * shifted.x + shadow_matrices[column + 1] * shifted.y + shadow_matrices[column + 2] * shifted.z + shadow_matrices[column + 3];
    float3 point = clip.xyz / clip.w;
    float2 uv = float2(point.x * 0.5 + 0.5, 0.5 - point.y * 0.5);
    if (point.z < 0.0 || point.z > 1.0 || any(uv < 0.0) || any(uv > 1.0)) return 1.0;
    // The cascades are the quarters of one texture, row by row.
    float2 corner = float2(float(cascade % 2), float(cascade / 2)) * 0.5;
    float texel = shadow_params.y;
    float depth = point.z - shadow_params.x * (1.0 + 2.0 * (1.0 - saturate(ndl)));
    return filteredShadow(shadow_map, corner + uv * 0.5, depth, 1.5 * texel, corner + texel, corner + 0.5 - texel, noise * 6.2831853);
}

// How much of the directional light reaches `world`: from the nearest cascade reaching it,
// handed to the next across a dithered band, and fading out at the shadow distance.
float visibility(float3 world, float3 normal, float ndl, float2 pixel) {
    float depth_m = dot(world - eye.xyz, view_forward.xyz);
    if (depth_m > shadow_splits[cascades - 1]) return 1.0;
    int cascade = 0;
    while (cascade < cascades - 1 && depth_m > shadow_splits[cascade]) ++cascade;
    float previous = cascade == 0 ? 0.0 : shadow_splits[cascade - 1];
    float end = shadow_splits[cascade];
    float fading = saturate((depth_m - (end - (end - previous) * cascade_blend)) / max((end - previous) * cascade_blend, 0.0001));
    float noise = pixelNoise(pixel);
    if (cascade == cascades - 1) return lerp(cascadeVisibility(cascade, world, normal, ndl, noise), 1.0, fading);
    if (noise < fading) ++cascade;
    return cascadeVisibility(cascade, world, normal, ndl, noise);
}

// How much of a point or spot light reaches `world` past its shadow map, sampled a little out
// along `normal` (a texel's width there) so a surface doesn't shadow itself.
float localVisibility(SceneLight light, float3 world, float3 normal, float2 pixel) {
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
    float texel = local_shadow_params.x;
    float map_texel = across * texel;
    float3 shifted = world + normal * (2.0 * length(offset) * tan_half * map_texel * 1.5);
    float4 clip = local_shadow_matrices[map * 4] * shifted.x + local_shadow_matrices[map * 4 + 1] * shifted.y + local_shadow_matrices[map * 4 + 2] * shifted.z + local_shadow_matrices[map * 4 + 3];
    if (clip.w <= 0.0) return 1.0;
    float3 point = clip.xyz / clip.w;
    float2 uv = float2(point.x * 0.5 + 0.5, 0.5 - point.y * 0.5);
    if (point.z < 0.0 || point.z > 1.0 || any(uv < 0.0) || any(uv > 1.0)) return 1.0;
    float2 corner = float2(float(map % 4), float(map / 4)) / across;
    float depth = point.z - 0.00002;
    return filteredShadow(local_shadow_map, corner + uv / across, depth, 1.5 * texel, corner + texel, corner + 1.0 / across - texel, pixelNoise(pixel) * 6.2831853);
}

// How much of the light between the camera and `world` the fog takes: thickest at its height,
// thinning above it (exponential height fog, integrated along the ray).
float fogAmount(float3 world) {
    if (fog.a <= 0.0) return 0.0;
    float3 ray = world - eye.xyz;
    float distance = length(ray);
    float climb = fog_shape.y * ray.y;
    float thickness = fog.a * exp(-fog_shape.y * (eye.y - fog_shape.x));
    // How the fog thins along the ray, averaged; 1 when the ray stays level or the fog is even.
    float along = abs(climb) > 0.0001 ? (1.0 - exp(-climb)) / climb : 1.0;
    return 1.0 - exp(-thickness * distance * along);
}

// eggy: surface
#ifndef EGGY_SURFACE
Surface surface(SurfaceInput input) {
    return defaultSurface(input);
}
#endif

// eggy: terrain
#ifndef EGGY_TERRAIN
Surface terrainSurface(TerrainSurfaceInput input) {
    return defaultTerrainSurface(input);
}
#endif

// How `shown` looks at `world` lit by the scene, through the fog, at the view's exposure:
// `normal` and `roughness` are its own, worked out before anything was discarded (derivatives
// need it); `geometric` is the face's normal before maps bent it. `authored`: an authored
// material, which the fallback light lights as a surface rather than a plain colour.
float4 shade(Surface shown, float3 normal, float roughness, float3 geometric, float3 world, float3 view, float occlusion, bool authored, float2 pixel) {
    float3 base = max(shown.base_color, 0.0);
    float metallic = saturate(shown.metallic);
    float ndv = max(dot(normal, view), 0.0001);
    float3 fresnel0 = lerp(float3(0.04, 0.04, 0.04), base, metallic);
    float2 brdf = environmentBrdf(roughness, ndv);
    float3 energy = multipleScattering(fresnel0, brdf);
    float3 color = base;
    if (!shown.unlit) {
        float3 specular = (fresnel0 * brdf.x + brdf.y) * energy * specularOcclusion(ndv, occlusion, roughness);
        if (sky_rays[0].w > 0.5) {
            // Lit by the sky: dimly from every side, and reflecting it, blurrier when rougher. A
            // reflection that would come from inside the surface fades out.
            float3 mirrored = reflect(-view, normal);
            float horizon = saturate(1.0 + dot(mirrored, geometric));
            float3 reflected = skyColor(mirrored, roughness * max(sky.z - 1.0, 0.0)) * specular * horizon * horizon;
            color = (base * (1.0 - metallic) * skyLight(normal) * occlusion + reflected) * sky.y;
        } else {
            // A flat ambient lights evenly and is reflected evenly.
            color = ambient.rgb * ambient.w * (base * (1.0 - metallic) * occlusion + specular);
        }
        if (light_info.x < 0.5 && environment.y > 0.5) {
            // Keep scenes without authored lights visible in both the editor and runtime.
            if (authored || metallic > 0.0 || shown.roughness < 0.999) {
                color += surfaceLight(base, metallic, roughness, normal, view, unit(light.xyz), float3(3.0, 3.0, 3.0), energy);
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
                float3 offset = current.position_kind.xyz - world;
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
                attenuation *= visibility(world, geometric, dot(geometric, incoming), pixel);
            else if (current.position_kind.w > 0.5 && current.cone_shadow.z > 0.5 && attenuation > 0.0)
                attenuation *= localVisibility(current, world, geometric, pixel);
            float3 radiance = current.color_intensity.rgb * current.color_intensity.w * 0.001 * attenuation;
            color += surfaceLight(base, metallic, roughness, normal, view, incoming, radiance, energy);
        }
    }
    color += max(shown.emissive, 0.0);
    color = lerp(color, fog.rgb, fogAmount(world));
    color *= environment.x;
    // Fit HDR direct lighting into the output range without hard-clipping bright surfaces,
    // unless the post pass maps the whole image's tones.
    if (!shown.unlit && environment.w < 0.5)
        color = saturate((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14));
    // sRGB targets encode linear output themselves; other targets need explicit encoding.
    color = options.x > 0.5 ? color : pow(max(color, 0.0), float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));
    return float4(color, shown.alpha);
}

// A terrain shader is compiled for `fragmentMain` too, as the terrain's (below).
#ifndef EGGY_TERRAIN
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
    float3 normal = unit(shown.normal);
    // Derivatives before anything is discarded, as above.
    float roughness = clamp(stableRoughness(normal, clamp(shown.roughness, 0.05, 1.0)), 0.05, 1.0);
    // An authored material's cutoff comes with the instance, an imported surface's with its maps.
    float cutoff = input.material.w > 0.5 ? input.emissive_cutoff.w : map_flags.y;
    if (shown.alpha < cutoff) discard;
    return shade(shown, normal, roughness, geometric, input.world, described.view_direction, occlusion, input.material.w > 0.5, input.position.xy);
}
#endif

// Terrain: one flat patch of corners drawn once per `terrain.Patch`, each corner lifted to its
// height in the grid, read from `paint`, where the grid's one-channel texture is bound in the
// colour texture's place. Each face is shaded flat, coloured by its height and slope, then by
// its terrain shader (`terrainSurface`).

// The grid's attributes, four bytes a corner, bound beside its heights; 1 by 1 and zero for a
// grid without any.
[[vk::binding(2, 1)]]
Texture2D terrain_attributes : register(t2, space1);

// No semantics, and locations in order, as on `VertexInput`.
struct TerrainInput {
    [[vk::location(0)]] float3 corner; // column and row in the patch; y 1 on a skirt's lower edge
    [[vk::location(1)]] float4 model0; // from the grid's column, height and row to the world, by column
    [[vk::location(2)]] float4 model1;
    [[vk::location(3)]] float4 model2;
    [[vk::location(4)]] float4 model3;
    [[vk::location(5)]] float4 patch;   // its first column and row, corners per cell, skirt depth
    [[vk::location(6)]] float4 color;   // between the bands: rgb, and each face's shade either way
    [[vk::location(7)]] float4 low;     // rgb, and the height in metres it is below
    [[vk::location(8)]] float4 high;    // rgb, and the height in metres it is above
    [[vk::location(9)]] float4 steep;   // rgb, and the upward part of a normal it is below
    [[vk::location(10)]] float4 surface; // roughness, cells across a patch
    [[vk::location(11)]] float4 values0; // the Terrain's values, for its shader
    [[vk::location(12)]] float4 values1;
    [[vk::location(13)]] float4 values2;
    [[vk::location(14)]] float4 values3;
};

struct TerrainOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float3 world;
    [[vk::location(1)]] float3 local; // column, height, row
    [[vk::location(2)]] nointerpolation float4 patch;
    [[vk::location(3)]] nointerpolation float4 color;
    [[vk::location(4)]] nointerpolation float4 low;
    [[vk::location(5)]] nointerpolation float4 high;
    [[vk::location(6)]] nointerpolation float4 steep;
    [[vk::location(7)]] nointerpolation float4 surface;
    // The model's rows: each column's x, y and z, to place a point of the grid in the world.
    [[vk::location(8)]] nointerpolation float4 model_x;
    [[vk::location(9)]] nointerpolation float4 model_y;
    [[vk::location(10)]] nointerpolation float4 model_z;
    [[vk::location(11)]] nointerpolation float4 values0;
    [[vk::location(12)]] nointerpolation float4 values1;
    [[vk::location(13)]] nointerpolation float4 values2;
    [[vk::location(14)]] nointerpolation float4 values3;
};

float heightAt(float2 at) {
    uint columns, rows;
    paint.GetDimensions(columns, rows);
    int2 texel = int2(clamp(at, float2(0.0, 0.0), float2(float(columns - 1), float(rows - 1))));
    return paint.Load(int3(texel, 0)).r;
}

float4 attributesAt(float2 at) {
    uint columns, rows;
    terrain_attributes.GetDimensions(columns, rows);
    int2 texel = int2(clamp(at, float2(0.0, 0.0), float2(float(columns - 1), float(rows - 1))));
    return terrain_attributes.Load(int3(texel, 0));
}

[shader("vertex")]
TerrainOutput vertexTerrain(TerrainInput input) {
    uint columns, rows;
    paint.GetDimensions(columns, rows);
    // Corners past the grid's edge fold onto it, so a patch hanging over draws nothing there.
    float2 at = min(input.patch.xy + input.corner.xz * input.patch.z, float2(float(columns - 1), float(rows - 1)));
    float height = paint.Load(int3(int2(at), 0)).r;
    // A skirt hangs from every patch edge, covering gaps between patches drawn at different
    // detail; along the grid's own edges it walls in the space the others hang in.
    float3 local = float3(at.x, height - input.corner.y * input.patch.w, at.y);
    float4 world = input.model0 * local.x + input.model1 * local.y + input.model2 * local.z + input.model3;
    TerrainOutput output;
    output.position = toClip(world);
    output.world = world.xyz;
    output.local = local;
    output.patch = input.patch;
    output.color = input.color;
    output.low = input.low;
    output.high = input.high;
    output.steep = input.steep;
    output.surface = input.surface;
    output.model_x = float4(input.model0.x, input.model1.x, input.model2.x, input.model3.x);
    output.model_y = float4(input.model0.y, input.model1.y, input.model2.y, input.model3.y);
    output.model_z = float4(input.model0.z, input.model1.z, input.model2.z, input.model3.z);
    output.values0 = input.values0;
    output.values1 = input.values1;
    output.values2 = input.values2;
    output.values3 = input.values3;
    return output;
}

// -1 to 1, the same every time for the same face.
float faceNoise(float2 corner, float upper) {
    uint hash = uint(corner.x) * 0x27d4eb2du ^ uint(corner.y) * 0x165667b1u ^ uint(upper) * 0x9e3779b9u;
    hash ^= hash >> 15;
    hash *= 0x2c1b3c6du;
    hash ^= hash >> 12;
    return float(hash & 0xffffu) / 32767.5 - 1.0;
}

// A point on a terrain, coloured by its bands and its terrain shader, then lit.
float4 terrainColor(TerrainOutput input) {
    // The face's own normal, from how the point moves across the pixel, towards the camera.
    float3 geometric = unit(cross(ddx(input.world), ddy(input.world)));
    if (dot(geometric, eye.xyz - input.world) < 0.0) geometric = -geometric;
    // The face under the point at this patch's detail: its cell, and which of the cell's two
    // triangles (split from its first corner to the one across, as `terrain.zig` says).
    float step = input.patch.z;
    float2 in_cells = (input.local.xz - input.patch.xy) / step;
    float2 cell = clamp(floor(in_cells), 0.0, input.surface.y - 1.0);
    float2 inside = saturate(in_cells - cell);
    float upper = inside.x > inside.y ? 1.0 : 0.0;
    float2 first = input.patch.xy + cell * step;
    float2 second = first + (upper > 0.5 ? float2(step, 0.0) : float2(0.0, step));
    float2 across = first + step;
    float2 centre = (first + second + across) / 3.0;
    float face_height = (heightAt(first) + heightAt(second) + heightAt(across)) / 3.0;
    float4 face_local = float4(centre.x, face_height, centre.y, 1.0);
    float3 face_world = float3(dot(input.model_x, face_local), dot(input.model_y, face_local), dot(input.model_z, face_local));
    // Steep faces are rock whatever their height; the rest go by how high they are.
    float3 color = input.color.rgb;
    if (face_world.y < input.low.w) color = input.low.rgb;
    else if (face_world.y > input.high.w) color = input.high.rgb;
    if (geometric.y < input.steep.w) color = input.steep.rgb;
    float face_random = faceNoise(first, upper);
    color *= 1.0 + face_random * input.color.w;
    TerrainSurfaceInput described;
    described.world_position = input.world;
    described.normal = geometric;
    described.view_direction = unit(eye.xyz - input.world);
    described.face_position = face_world;
    described.face_random = face_random;
    described.color = pow(max(color, 0.0), float3(2.2, 2.2, 2.2));
    described.roughness = input.surface.x;
    described.attributes = attributesAt(first);
    described.values[0] = input.values0;
    described.values[1] = input.values1;
    described.values[2] = input.values2;
    described.values[3] = input.values3;
    described.time_s = light_info.y;
    Surface shown = terrainSurface(described);
    float3 normal = unit(shown.normal);
    float roughness = clamp(stableRoughness(normal, clamp(shown.roughness, 0.05, 1.0)), 0.05, 1.0);
    return shade(shown, normal, roughness, geometric, input.world, described.view_direction, 1.0, true, input.position.xy);
}

[shader("pixel")]
float4 fragmentTerrain(TerrainOutput input) : SV_Target0 {
    return terrainColor(input);
}

#ifdef EGGY_TERRAIN
[shader("pixel")]
float4 fragmentMain(TerrainOutput input) : SV_Target0 {
    return terrainColor(input);
}
#endif

[shader("pixel")]
void fragmentShadow(VertexOutput input) {
    float alpha = input.color.a * paint.Sample(paint_sampler, input.uv).a;
    float cutoff = input.material.w > 0.5 ? input.emissive_cutoff.w : map_flags.y;
    if (alpha < cutoff) discard;
}

// The sky behind everything, through the fog: one triangle over the whole view, each pixel
// looking out along its ray. Its corners come in a vertex buffer, as SV_VertexID needs Vulkan's
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
    float fogged = fogAmount(eye.xyz + ray * fog_shape.z);
    // Without a sky only the fog is drawn, over the backdrop.
    bool has_sky = sky_rays[0].w > 0.5;
    float3 color = lerp(has_sky ? skyColor(ray, 0.0) * sky.x : fog.rgb, fog.rgb, fogged) * environment.x;
    if (environment.w < 0.5)
        color = saturate((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14));
    color = options.x > 0.5 ? color : pow(max(color, 0.0), float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));
    return float4(color, has_sky ? 1.0 : fogged);
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
