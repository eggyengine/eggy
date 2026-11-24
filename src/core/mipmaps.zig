//! Alpha-aware, linear-light mip chains packed for portable GPU texture uploads.
const std = @import("std");
const assets = @import("eggy_assets");

const Format = assets.Texture.Format;

pub const Level = struct { width: u32, height: u32, row_bytes: u32, offset: usize };

/// Owned mips with portable row/placement alignment, down to 1x1. Both formats hold colour
/// gamma-encoded (the 2.2th root of linear light), so shaders decode an `.rgba16_float` texture
/// as they do an 8-bit one; its values may pass 1.
pub const Chain = struct {
    bytes: []u8,
    levels: [32]Level = undefined,
    count: u32,
    format: Format,

    /// Borrow tightly packed `format` input. Invalid dimensions/counts and allocation fail explicitly.
    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, pixels: []const u8, format: Format, enabled: bool) !Chain {
        const pixel_bytes = format.pixelBytes();
        if (width == 0 or height == 0 or width > 16384 or height > 16384 or pixels.len != @as(usize, width) * height * pixel_bytes)
            return error.InvalidTexture;
        var self = Chain{ .bytes = undefined, .count = 0, .format = format };
        var w = width;
        var h = height;
        var size: usize = 0;
        while (true) {
            // DX12 requires 512-byte placements; WebGPU and DX12 require 256-byte rows.
            size = std.mem.alignForward(usize, size, 512);
            const row_bytes = std.mem.alignForward(u32, w * @as(u32, @intCast(pixel_bytes)), 256);
            self.levels[self.count] = .{ .width = w, .height = h, .row_bytes = row_bytes, .offset = size };
            size = try std.math.add(usize, size, try std.math.mul(usize, row_bytes, h));
            self.count += 1;
            if (!enabled or (w == 1 and h == 1)) break;
            w = @max(1, w / 2);
            h = @max(1, h / 2);
        }
        self.bytes = try gpa.alloc(u8, size);
        @memset(self.bytes, 0);
        const first = self.levels[0];
        switch (format) {
            .rgba8_srgb => for (0..height) |row|
                @memcpy(self.bytes[row * first.row_bytes ..][0 .. width * 4], pixels[row * width * 4 ..][0 .. width * 4]),
            .rgba16_float => for (0..height) |y| for (0..width) |x| {
                var color: [4]f32 = undefined;
                for (&color, 0..) |*channel, i| channel.* = assets.texture.halfAt(pixels, (y * width + x) * 4 + i);
                self.store(first, x, y, color);
            },
        }
        for (1..self.count) |i| self.downsample(self.levels[i - 1], self.levels[i]);
        return self;
    }

    pub fn deinit(self: *Chain, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
    }

    /// The linear light and alpha of `level`'s pixel `x`, `y`.
    fn load(self: *const Chain, level: Level, x: usize, y: usize) [4]f32 {
        const at = level.offset + y * level.row_bytes + x * self.format.pixelBytes();
        var color: [4]f32 = undefined;
        switch (self.format) {
            .rgba8_srgb => for (&color, self.bytes[at..][0..4]) |*channel, value| {
                channel.* = @as(f32, @floatFromInt(value)) / 255;
            },
            .rgba16_float => for (&color, 0..) |*channel, i| {
                channel.* = assets.texture.halfAt(self.bytes[at..], i);
            },
        }
        for (color[0..3]) |*channel| channel.* = std.math.pow(f32, @max(channel.*, 0), 2.2);
        return color;
    }

    /// Store linear light and alpha `color` as `level`'s pixel `x`, `y`.
    fn store(self: *Chain, level: Level, x: usize, y: usize, color: [4]f32) void {
        const at = level.offset + y * level.row_bytes + x * self.format.pixelBytes();
        var encoded = color;
        for (encoded[0..3]) |*channel| channel.* = std.math.pow(f32, @max(channel.*, 0), 1.0 / 2.2);
        switch (self.format) {
            .rgba8_srgb => for (self.bytes[at..][0..4], encoded) |*out, value| {
                out.* = byte(value);
            },
            .rgba16_float => for (encoded, 0..) |value, i| assets.texture.setHalf(self.bytes[at..], i, value),
        }
    }

    fn downsample(self: *Chain, source: Level, destination: Level) void {
        const scale_x = @as(f32, @floatFromInt(source.width)) / @as(f32, @floatFromInt(destination.width));
        const scale_y = @as(f32, @floatFromInt(source.height)) / @as(f32, @floatFromInt(destination.height));
        for (0..destination.height) |y| for (0..destination.width) |x| {
            const x0 = @as(f32, @floatFromInt(x)) * scale_x;
            const y0 = @as(f32, @floatFromInt(y)) * scale_y;
            const x1 = @min(@as(f32, @floatFromInt(source.width)), @as(f32, @floatFromInt(x + 1)) * scale_x);
            const y1 = @min(@as(f32, @floatFromInt(source.height)), @as(f32, @floatFromInt(y + 1)) * scale_y);
            var color: [3]f32 = @splat(0);
            var alpha: f32 = 0;
            var area: f32 = 0;
            // Area weighting includes odd edge texels; premultiplication avoids transparent fringes.
            for (@as(usize, @intFromFloat(@floor(y0)))..@as(usize, @intFromFloat(@ceil(y1)))) |sy| {
                for (@as(usize, @intFromFloat(@floor(x0)))..@as(usize, @intFromFloat(@ceil(x1)))) |sx| {
                    const weight_x = @min(x1, @as(f32, @floatFromInt(sx + 1))) - @max(x0, @as(f32, @floatFromInt(sx)));
                    const weight_y = @min(y1, @as(f32, @floatFromInt(sy + 1))) - @max(y0, @as(f32, @floatFromInt(sy)));
                    const weight = weight_x * weight_y;
                    const pixel = self.load(source, sx, sy);
                    for (&color, pixel[0..3]) |*channel, value| channel.* += value * pixel[3] * weight;
                    alpha += pixel[3] * weight;
                    area += weight;
                }
            }
            var averaged: [4]f32 = .{ 0, 0, 0, alpha / area };
            if (alpha > 0) for (averaged[0..3], color) |*channel, value| {
                channel.* = value / alpha;
            };
            self.store(destination, x, y, averaged);
        };
    }
};

fn byte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}
