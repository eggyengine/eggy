//! The sky: a panorama behind the scene that lights it, dimly from every side (`irradiance`,
//! nine spherical-harmonic terms worked out once per image) and in reflections (its mips,
//! blurrier for rougher surfaces, sampled in `mesh.slang`).
const std = @import("std");
const math = @import("eggenvector");
const assets = @import("eggy_assets");
const texture_cache = @import("texture_cache.zig");

/// The sky's light falling on a surface facing each way, divided by pi, as nine
/// spherical-harmonic terms (rgb in each): the shader sums them for a normal (`skyLight`).
pub const Irradiance = [9][4]f32;

/// The way a panorama's point `u`, `v` (0 to 1, from its top left) looks: its middle row is the
/// horizon, its top straight up, and its middle column along -z. The shader's `skyUv` is its
/// inverse.
pub fn direction(u: f32, v: f32) math.Vec3 {
    const theta = v * std.math.pi;
    const phi = (u - 0.5) * std.math.tau;
    return .init(@sin(theta) * @sin(phi), @cos(theta), -@sin(theta) * @cos(phi));
}

/// The nine spherical-harmonic basis functions for unit direction `d`.
fn basis(d: math.Vec3) [9]f32 {
    return .{
        0.282095,
        0.488603 * d.y,
        0.488603 * d.z,
        0.488603 * d.x,
        1.092548 * d.x * d.y,
        1.092548 * d.y * d.z,
        0.315392 * (3 * d.z * d.z - 1),
        1.092548 * d.x * d.z,
        0.546274 * (d.x * d.x - d.y * d.y),
    };
}

/// The light `panorama` (sRGB) gives, in linear light, sampled on a grid of at most 256 by 128.
pub fn irradiance(panorama: assets.Texture) Irradiance {
    const pixels = panorama.frame(0);
    const step_x = @max(1, panorama.width / 256);
    const step_y = @max(1, panorama.height / 128);
    var sums: [9][3]f64 = @splat(@splat(0));
    var y: u32 = step_y / 2;
    while (y < panorama.height) : (y += step_y) {
        const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(panorama.height));
        // Each sample covers the solid angle of its cell, smaller towards the poles.
        const solid_angle = std.math.tau / @as(f32, @floatFromInt(panorama.width / step_x)) * std.math.pi / @as(f32, @floatFromInt(panorama.height / step_y)) * @sin(v * std.math.pi);
        var x: u32 = step_x / 2;
        while (x < panorama.width) : (x += step_x) {
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(panorama.width));
            const at = (@as(usize, y) * panorama.width + x) * 4;
            const terms = basis(direction(u, v));
            for (0..3) |channel| {
                const linear = std.math.pow(f32, @as(f32, @floatFromInt(pixels[at + channel])) / 255, 2.2);
                for (&sums, terms) |*sum, term| sum[channel] += linear * term * solid_angle;
            }
        }
    }
    // Convolved with a cosine lobe (Ramamoorthi and Hanrahan), then divided by pi.
    const lobe = [9]f32{ 1, 2.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0, 0.25, 0.25, 0.25, 0.25, 0.25 };
    var result: Irradiance = undefined;
    for (&result, sums, lobe) |*term, sum, weight| term.* = .{ @floatCast(sum[0] * weight), @floatCast(sum[1] * weight), @floatCast(sum[2] * weight), 0 };
    return result;
}

/// The sky a renderer shows: which image, its light, and its texture (borrowed from the
/// `TextureCache`).
pub const Sky = struct {
    key_hash: u64 = 0,
    light: Irradiance = @splat(@splat(0)),
    /// How many mips the texture has, for the shader's roughest reflections.
    mip_count: f32 = 1,
    texture: ?texture_cache.Gpu = null,

    /// Show the image at `key` (none for no sky), working out its light the first time.
    /// Host-only; failures are logged once and leave no sky.
    pub fn update(self: *Sky, textures: *texture_cache.TextureCache, key: ?[]const u8) void {
        const path = key orelse {
            self.* = .{};
            return;
        };
        const hash = std.hash.Wyhash.hash(0, path);
        if (hash == self.key_hash) {
            // The cache may have let it go (its file changed) since.
            self.texture = textures.get(path);
            return;
        }
        self.* = .{ .key_hash = hash };
        const loader = textures.loader orelse return;
        var panorama = loader.load(loader.context, textures.gpa, path) catch |err| {
            std.log.err("cannot load sky {s}: {t}", .{ path, err });
            return;
        };
        defer panorama.deinit(textures.gpa);
        self.light = irradiance(panorama);
        self.texture = textures.get(path);
        const largest: f32 = @floatFromInt(@max(panorama.width, panorama.height));
        self.mip_count = if (textures.settings.mipmaps) @floor(std.math.log2(largest)) + 1 else 1;
    }
};

test "a panorama's middle looks along -z and its top straight up" {
    const ahead = direction(0.5, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, -1), ahead.z, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), direction(0.3, 0).y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), direction(0.75, 0.5).x, 1e-6);
}

test "an even white sky lights every way alike, as brightly as it looks" {
    var pixels: [64 * 32 * 4]u8 = @splat(255);
    const light = irradiance(.{ .width = 64, .height = 32, .pixels = &pixels });
    // A surface under an even sky of radiance 1 receives pi, which over pi is 1.
    try std.testing.expectApproxEqAbs(@as(f32, 1), light[0][0] * 0.282095, 0.02);
    for (light[1..]) |term| try std.testing.expectApproxEqAbs(@as(f32, 0), term[0], 0.02);
}

test "a sky bright only above lights upward-facing surfaces more" {
    var pixels: [64 * 32 * 4]u8 = @splat(0);
    for (0..16 * 64) |pixel| pixels[pixel * 4 ..][0..3].* = @splat(255);
    const light = irradiance(.{ .width = 64, .height = 32, .pixels = &pixels });
    try std.testing.expect(light[1][0] > 0.1);
}

