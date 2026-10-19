//! Alpha-aware, linear-light mip chains packed for portable GPU texture uploads.
const std = @import("std");

pub const Level = struct { width: u32, height: u32, row_bytes: u32, offset: usize };

/// Owned RGBA8 mips with portable row/placement alignment, down to 1x1.
pub const Chain = struct {
    bytes: []u8,
    levels: [32]Level = undefined,
    count: u32,

    /// Borrow tightly packed sRGB RGBA8 input. Invalid dimensions/counts and allocation fail explicitly.
    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, pixels: []const u8, enabled: bool) !Chain {
        if (width == 0 or height == 0 or width > 16384 or height > 16384 or pixels.len != @as(usize, width) * height * 4)
            return error.InvalidTexture;
        var self = Chain{ .bytes = undefined, .count = 0 };
        var w = width;
        var h = height;
        var size: usize = 0;
        while (true) {
            // DX12 requires 512-byte placements; WebGPU and DX12 require 256-byte rows.
            size = std.mem.alignForward(usize, size, 512);
            const row_bytes = std.mem.alignForward(u32, w * 4, 256);
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
        for (0..height) |row|
            @memcpy(self.bytes[row * first.row_bytes ..][0 .. width * 4], pixels[row * width * 4 ..][0 .. width * 4]);
        for (1..self.count) |i| self.downsample(self.levels[i - 1], self.levels[i]);
        return self;
    }

    pub fn deinit(self: *Chain, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
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
                    const pixel = self.bytes[source.offset + sy * source.row_bytes + sx * 4 ..][0..4];
                    const a = @as(f32, @floatFromInt(pixel[3])) / 255;
                    for (&color, pixel[0..3]) |*channel, value|
                        channel.* += std.math.pow(f32, @as(f32, @floatFromInt(value)) / 255, 2.2) * a * weight;
                    alpha += a * weight;
                    area += weight;
                }
            }
            const out = self.bytes[destination.offset + y * destination.row_bytes + x * 4 ..][0..4];
            for (out[0..3], color) |*channel, value|
                channel.* = byte(if (alpha > 0) std.math.pow(f32, value / alpha, 1.0 / 2.2) else 0);
            out[3] = byte(alpha / area);
        };
    }
};

fn byte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

test "mips average in linear light and do not bleed transparent colors" {
    var light = try Chain.init(std.testing.allocator, 2, 1, &.{ 0, 0, 0, 255, 255, 255, 255, 255 }, true);
    defer light.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), light.count);
    const offset = light.levels[1].offset;
    try std.testing.expectApproxEqAbs(@as(f32, 186), @as(f32, @floatFromInt(light.bytes[offset])), 1);
    var transparent = try Chain.init(std.testing.allocator, 2, 1, &.{ 255, 0, 0, 0, 0, 0, 255, 255 }, true);
    defer transparent.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 128 }, transparent.bytes[transparent.levels[1].offset..][0..4]);
}

test "mip chains cover odd edges, thin images and disabled mipmapping" {
    var odd = try Chain.init(std.testing.allocator, 3, 1, &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255 }, true);
    defer odd.deinit(std.testing.allocator);
    for (odd.levels[0..odd.count]) |level| {
        try std.testing.expectEqual(@as(usize, 0), level.offset % 512);
        try std.testing.expectEqual(@as(u32, 0), level.row_bytes % 256);
    }
    const last = odd.bytes[odd.levels[1].offset..][0..4];
    try std.testing.expect(last[0] > 140 and last[1] == last[0] and last[2] == last[0]);
    var single = try Chain.init(std.testing.allocator, 1, 1, &.{ 0, 0, 0, 255 }, true);
    defer single.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), single.count);
    var disabled = try Chain.init(std.testing.allocator, 2, 1, &.{ 0, 0, 0, 255, 255, 255, 255, 255 }, false);
    defer disabled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), disabled.count);
    try std.testing.expectError(error.InvalidTexture, Chain.init(std.testing.allocator, 0, 0, &.{}, true));
}
