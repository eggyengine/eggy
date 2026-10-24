// The editor's infinite grid on the ground (y = 0): each pixel's ray from the camera meets the
// ground somewhere, and lines are drawn where that point is near a whole 1, 10, 100 or 1000
// metres (each stronger than the last), the x axis in red and the z axis in blue. Each size fades
// out as its cells shrink below a few pixels, so the grid reaches the horizon without shimmering.
// Its depth is the point's, so meshes in front hide it. One oversized triangle covers the viewport.

struct VertexInput {
    // (0, 0), (2, 0) and (0, 2): so (0, 0) to (1, 1) spans the viewport.
    [[vk::location(0)]] float2 uv : TEXCOORD0;
};

struct VertexOutput {
    float4 position : SV_Position;
};

struct FragmentOutput {
    float4 color : SV_Target0;
    float depth : SV_Depth;
};

[[vk::binding(0, 0)]]
cbuffer Grid : register(b0, space0) {
    float4 view_projection0; // the camera's view-projection matrix, by column
    float4 view_projection1;
    float4 view_projection2;
    float4 view_projection3;
    float4 eye;              // xyz: where the camera is
    float4 forward;          // xyz: which way it looks
    float4 across;           // xyz: right, as far as the view's edge is from its middle
    float4 upward;           // xyz: up, likewise
    float4 viewport;         // the viewport in pixels: x, y, width, height
    float4 options;          // x: sRGB target; y: unused; z: orthographic projection
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = float4(input.uv.x * 2.0 - 1.0, 1.0 - input.uv.y * 2.0, 0.5, 1.0);
    return output;
}

// How much of a line `size` metres apart covers this pixel of the ground at `coord`: 1 on it,
// fading out over about a pixel either side, and gone where its cells are too small to tell apart.
float gridLine(float2 coord, float size) {
    float2 c = coord / size;
    float2 width = fwidth(c);
    float2 distance = abs(frac(c - 0.5) - 0.5) / max(width, float2(1e-5, 1e-5));
    float visible = 1.0 - smoothstep(0.08, 0.3, max(width.x, width.y));
    return (1.0 - min(min(distance.x, distance.y), 1.0)) * visible;
}

// How much of a line along one axis (where `value` is 0) covers this pixel.
float axisLine(float value) {
    return 1.0 - min(abs(value) / max(fwidth(value), 1e-5), 1.0);
}

[shader("pixel")]
FragmentOutput fragmentMain(VertexOutput input) {
    // The ray through this pixel, and where it meets the ground.
    float2 ndc = float2((input.position.x - viewport.x) / viewport.z * 2.0 - 1.0, 1.0 - (input.position.y - viewport.y) / viewport.w * 2.0);
    float3 offset = across.xyz * ndc.x + upward.xyz * ndc.y;
    float3 origin = eye.xyz + (options.z > 0.5 ? offset : float3(0, 0, 0));
    float3 direction = forward.xyz + (options.z > 0.5 ? float3(0, 0, 0) : offset);
    float t = -origin.y / direction.y;
    if (!(t > 0.0)) discard;
    float3 ground = origin + direction * t;

    // The lines, the axes over them, fading with distance and at grazing angles.
    float alpha = max(max(gridLine(ground.xz, 1.0) * 0.18, gridLine(ground.xz, 10.0) * 0.3),
                      max(gridLine(ground.xz, 100.0) * 0.4, gridLine(ground.xz, 1000.0) * 0.5));
    float3 color = float3(0.55, 0.57, 0.62);
    float x_axis = axisLine(ground.z);
    float z_axis = axisLine(ground.x);
    if (x_axis > 0.0) { color = lerp(color, float3(0.86, 0.25, 0.25), x_axis); alpha = max(alpha, x_axis * 0.8); }
    if (z_axis > 0.0) { color = lerp(color, float3(0.25, 0.45, 0.9), z_axis); alpha = max(alpha, z_axis * 0.8); }
    alpha *= smoothstep(0.0, 0.15, abs(normalize(direction).y));
    if (alpha <= 0.002) discard;

    FragmentOutput output;
    color = options.x > 0.5 ? pow(color, float3(2.2, 2.2, 2.2)) : color;
    output.color = float4(color, alpha);
    float4 clip = view_projection0 * ground.x + view_projection1 * ground.y + view_projection2 * ground.z + view_projection3;
    output.depth = clip.z / clip.w;
    return output;
}
