// The HDR scene's post-processing: bloom's blur chain, then grading into the presentation target.
struct VertexInput {
    [[vk::location(0)]] float2 uv : TEXCOORD0;
};
struct VertexOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float2 uv : TEXCOORD0;
};
[[vk::binding(0, 0)]]
Texture2D source : register(t0, space0);
[[vk::binding(1, 0)]]
SamplerState linear_sampler : register(s1, space0);
// The grade's bloom; bloom passes bind their source here too.
[[vk::binding(2, 0)]]
Texture2D glow : register(t2, space0);
[[vk::binding(0, 1)]]
cbuffer Post : register(b0, space1) {
    float4 bloom;    // x: intensity, y: threshold
    float4 grade;    // x: contrast, y: saturation, z: vignette, w: tone mapping (ToneMapping)
    float4 scene_uv; // the scene's rectangle in the target: xy its corner, zw its size
    float4 options;  // x: FXAA, y: encode sRGB (the destination doesn't)
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = float4(input.uv.x * 2.0 - 1.0, 1.0 - input.uv.y * 2.0, 0.0, 1.0);
    output.uv = input.uv;
    return output;
}

float2 texelOf(Texture2D image) {
    uint width, height;
    image.GetDimensions(width, height);
    return float2(1.0 / float(width), 1.0 / float(height));
}

float luminance(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

// Four bilinear taps, each the average of four texels: a 4x4 box halving the source.
float3 downsample(float2 uv) {
    float2 texel = texelOf(source);
    return 0.25 * (
        source.SampleLevel(linear_sampler, uv + float2(-1, -1) * texel, 0).rgb +
        source.SampleLevel(linear_sampler, uv + float2(1, -1) * texel, 0).rgb +
        source.SampleLevel(linear_sampler, uv + float2(-1, 1) * texel, 0).rgb +
        source.SampleLevel(linear_sampler, uv + float2(1, 1) * texel, 0).rgb);
}

// The first step keeps only light over the threshold, clamped so single hot pixels don't flicker.
[shader("pixel")]
float4 bloomPrefilter(VertexOutput input) : SV_Target0 {
    float3 color = min(downsample(input.uv), 64.0);
    float brightness = max(color.r, max(color.g, color.b));
    float kept = max(brightness - bloom.y, 0.0) / max(brightness, 0.0001);
    return float4(color * kept, 1.0);
}

[shader("pixel")]
float4 bloomDown(VertexOutput input) : SV_Target0 {
    return float4(downsample(input.uv), 1.0);
}

// A 3x3 tent over the smaller level, added onto the larger one by the pipeline's blending.
[shader("pixel")]
float4 bloomUp(VertexOutput input) : SV_Target0 {
    float2 texel = texelOf(source);
    float3 sum = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float weight = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
            sum += weight * source.SampleLevel(linear_sampler, input.uv + float2(x, y) * texel, 0).rgb;
        }
    }
    return float4(sum / 16.0, 1.0);
}

float3 aces(float3 color) {
    return saturate((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14));
}

// AgX's base look (Troy Sobotka's, fitted by Benjamin Wrensch): into its log space, a sigmoid,
// and back to linear display light.
float3 agx(float3 color) {
    const float3x3 inset = float3x3(
        0.842479062253094, 0.0423282422610123, 0.0423756549057051,
        0.0784335999999992, 0.878468636469772, 0.0784336,
        0.0792237451477643, 0.0791661274605434, 0.879142973793104);
    const float3x3 outset = float3x3(
        1.19687900512017, -0.0528968517574562, -0.0529716355144438,
        -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
        -0.0990297440797205, -0.0989611768448433, 1.15107367264116);
    const float min_ev = -12.47393;
    const float max_ev = 4.026069;
    float3 x = clamp(log2(max(mul(color, inset), 1e-10)), min_ev, max_ev);
    x = (x - min_ev) / (max_ev - min_ev);
    float3 x2 = x * x;
    float3 x4 = x2 * x2;
    x = 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
    return pow(saturate(mul(x, outset)), 2.2);
}

float3 mapTones(float3 color) {
    int mode = int(grade.w + 0.5);
    if (mode == 1) return aces(color);
    if (mode == 2) return agx(color);
    if (mode == 3) return color / (1.0 + color);
    // Surface (lit surfaces mapped themselves) and none both clip.
    return saturate(color);
}

// The scene at `uv` with bloom, tones mapped and colour graded, in linear display light.
float3 graded(float2 uv) {
    float3 color = max(source.SampleLevel(linear_sampler, uv, 0).rgb, 0.0);
    color += bloom.x * glow.SampleLevel(linear_sampler, uv, 0).rgb;
    color = mapTones(color);
    // Contrast pivots on middle grey in a perceptual (gamma) space, where it looks even.
    float3 perceptual = pow(color, 1.0 / 2.2);
    perceptual = saturate((perceptual - 0.5) * grade.x + 0.5);
    color = pow(perceptual, 2.2);
    return max(lerp(luminance(color).xxx, color, grade.y), 0.0);
}

float perceivedLuma(float3 color) {
    return sqrt(max(dot(color, float3(0.299, 0.587, 0.114)), 0.0));
}

// FXAA over the graded image, so edges are found in what's shown rather than in raw scene light.
float3 antialiased(float2 uv) {
    float3 center = graded(uv);
    if (options.x < 0.5) return center;
    float2 texel = texelOf(source);
    float3 nw = graded(uv + float2(-1, -1) * texel);
    float3 ne = graded(uv + float2(1, -1) * texel);
    float3 sw = graded(uv + float2(-1, 1) * texel);
    float3 se = graded(uv + float2(1, 1) * texel);
    float middle = perceivedLuma(center);
    float a = perceivedLuma(nw), b = perceivedLuma(ne), c = perceivedLuma(sw), d = perceivedLuma(se);
    float low = min(middle, min(min(a, b), min(c, d)));
    float high = max(middle, max(max(a, b), max(c, d)));
    if (high - low < max(0.0312, high * 0.125)) return center;
    float2 direction = float2(-((a + b) - (c + d)), (a + c) - (b + d));
    float reduction = max((a + b + c + d) * (0.25 * 0.125), 1.0 / 128.0);
    direction = clamp(direction / (min(abs(direction.x), abs(direction.y)) + reduction), -8.0, 8.0) * texel;
    float3 narrow = 0.5 * (graded(uv + direction * (1.0 / 3.0 - 0.5)) + graded(uv + direction * (2.0 / 3.0 - 0.5)));
    float3 wide = narrow * 0.5 + 0.25 * (graded(uv - direction * 0.5) + graded(uv + direction * 0.5));
    float wide_luma = perceivedLuma(wide);
    return wide_luma < low || wide_luma > high ? narrow : wide;
}

// SampleLevel, not Sample, throughout: FXAA branches on what it read, and WGSL allows Sample's
// implicit level only in uniform control flow.
[shader("pixel")]
float4 gradeMain(VertexOutput input) : SV_Target0 {
    float3 color = antialiased(input.uv);
    // Darken toward the scene's corners, not the window's.
    float2 centered = ((input.uv - scene_uv.xy) / max(scene_uv.zw, 0.0001) - 0.5) * 2.0;
    color *= 1.0 - grade.z * smoothstep(0.3, 1.0, length(centered) * 0.7071);
    if (options.y > 0.5) color = pow(color, 1.0 / 2.2);
    return float4(color, 1.0);
}
