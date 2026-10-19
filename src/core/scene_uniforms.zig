//! Shared GPU camera, lighting and shadow layout for scene passes.
const lighting = @import("lighting.zig");

pub const Camera = extern struct {
    view_projection: [4][4]f32,
    light: [4]f32 = .{ 0.4, 1, 0.6, 0 },
    options: [4]f32 = @splat(0),
    outline: [4]f32 = @splat(0),
    outline_size: [4]f32 = @splat(0),
    eye: [4]f32 = @splat(0),
    light_info: [4]f32 = @splat(0),
    ambient: [4]f32 = .{ 1, 1, 1, 0.03 },
    environment: [4]f32 = .{ 1, 1, -1, 0 },
    shadow_matrix: [4][4]f32 = @splat(@splat(0)),
    /// x: depth bias, y: reciprocal map size, z: light index, w: enabled.
    shadow_params: [4]f32 = @splat(0),
    lights: [lighting.max_lights]lighting.GpuLight = @splat(.{}),
};
