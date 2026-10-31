//! The `.eggtexture` format: an image's pixels, ready to put on the GPU, in s2s's binary form.
//! Packaging writes one for each image file (decoded with stb_image); the runtime reads them,
//! with no decoder of its own. The editor decodes image files directly instead.
const std = @import("std");
const s2s = @import("s2s");

/// An image: rows of red, green, blue and alpha pixels stored as `format` says, top row first. An
/// animated one (a GIF) holds each frame's pixels one after another, each shown for its
/// `frame_delays_ms`; meshes are painted with the first.
pub const Texture = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    /// How long each frame shows; empty for a still image (one frame).
    frame_delays_ms: []u32 = &.{},
    format: Format = .rgba8_srgb,

    pub const Format = enum {
        /// A byte a channel, as most image files store them (sRGB).
        rgba8_srgb,
        /// A little-endian 16-bit float a channel, in linear light and brighter than white where
        /// the scene is: a high-dynamic-range image (`.hdr`, `.exr`).
        rgba16_float,

        pub fn pixelBytes(self: Format) usize {
            return switch (self) {
                .rgba8_srgb => 4,
                .rgba16_float => 8,
            };
        }
    };

    /// Free what `read` (or a decoder) allocated with `gpa`.
    /// The pixel and delay slices must belong to this allocator; invalidates them and must be
    /// called once.
    ///
    /// ```zig
    /// var texture = try read(gpa, reader);
    /// defer texture.deinit(gpa);
    /// ```
    pub fn deinit(self: *Texture, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        if (self.frame_delays_ms.len > 0) gpa.free(self.frame_delays_ms);
    }

    /// How many frames it holds: one for a still image.
    pub fn frameCount(self: Texture) usize {
        return @max(1, self.frame_delays_ms.len);
    }

    /// Frame `index`'s pixels; `index` must be below `frameCount`.
    pub fn frame(self: Texture, index: usize) []u8 {
        const size = @as(usize, self.width) * self.height * self.format.pixelBytes();
        return self.pixels[index * size ..][0..size];
    }

    /// Whether `pixels` holds exactly `width` by `height` of them for each frame, and there are
    /// some. Checks the byte count `format` needs without modifying or decoding the pixels.
    ///
    /// ```zig
    /// if (!texture.isWhole()) return error.InvalidTexture;
    /// ```
    pub fn isWhole(self: Texture) bool {
        return self.width > 0 and self.height > 0 and self.pixels.len == @as(usize, self.width) * self.height * self.format.pixelBytes() * self.frameCount();
    }

    /// Pixel `index` of `frame_pixels` (one of its `frame`s), as linear red, green, blue and
    /// straight alpha.
    pub fn linear(self: Texture, frame_pixels: []const u8, index: usize) [4]f32 {
        var result: [4]f32 = undefined;
        switch (self.format) {
            .rgba8_srgb => {
                const pixel = frame_pixels[index * 4 ..][0..4];
                for (result[0..3], pixel[0..3]) |*channel, value| channel.* = std.math.pow(f32, @as(f32, @floatFromInt(value)) / 255, 2.2);
                result[3] = @as(f32, @floatFromInt(pixel[3])) / 255;
            },
            .rgba16_float => for (&result, 0..) |*channel, i| {
                channel.* = halfAt(frame_pixels, index * 4 + i);
            },
        }
        return result;
    }

    /// A copy in `.rgba8_srgb`, brighter-than-white light clipped to white, for what only shows
    /// bytes (a UI image, an icon). Owned by `gpa` (see `deinit`).
    pub fn toSrgb8(self: Texture, gpa: std.mem.Allocator) !Texture {
        const pixel_count = @as(usize, self.width) * self.height * self.frameCount();
        const pixels = try gpa.alloc(u8, pixel_count * 4);
        errdefer gpa.free(pixels);
        for (0..pixel_count) |index| {
            const color = self.linear(self.pixels, index);
            for (pixels[index * 4 ..][0..3], color[0..3]) |*out, value| out.* = toByte(std.math.pow(f32, std.math.clamp(value, 0, 1), 1.0 / 2.2));
            pixels[index * 4 + 3] = toByte(color[3]);
        }
        const delays: []u32 = if (self.frame_delays_ms.len == 0) &.{} else try gpa.dupe(u32, self.frame_delays_ms);
        return .{ .width = self.width, .height = self.height, .pixels = pixels, .frame_delays_ms = delays };
    }
};

/// The `index`th 16-bit float in `bytes`, which needn't be aligned for one.
pub fn halfAt(bytes: []const u8, index: usize) f32 {
    return @as(f16, @bitCast(std.mem.readInt(u16, bytes[index * 2 ..][0..2], .little)));
}

/// `value` as a little-endian 16-bit float in `bytes` at `index`, clamped to the largest one.
pub fn setHalf(bytes: []u8, index: usize, value: f32) void {
    const half: f16 = @floatCast(std.math.clamp(value, -65504, 65504));
    std.mem.writeInt(u16, bytes[index * 2 ..][0..2], @bitCast(half), .little);
}

fn toByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

/// Write `texture` as an `.eggtexture`.
/// Borrows the RGBA pixels without validating their count; propagates writer errors.
///
/// ```zig
/// var output: std.Io.Writer.Allocating = .init(gpa);
/// defer output.deinit();
/// try write(&output.writer, texture);
/// ```
pub fn write(writer: *std.Io.Writer, texture: Texture) std.Io.Writer.Error!void {
    try s2s.serialize(writer, Texture, texture);
}

/// Read an `.eggtexture`, allocating with `gpa` (see `Texture.deinit`). Fails with
/// `error.UnexpectedData` for one of another version, or whose pixels don't fill it.
/// Reader/allocation errors propagate; the caller owns the returned pixels.
///
/// ```zig
/// var input: std.Io.Reader = .fixed(eggtexture_bytes);
/// var texture = try read(gpa, &input);
/// defer texture.deinit(gpa);
/// ```
pub fn read(gpa: std.mem.Allocator, reader: *std.Io.Reader) !Texture {
    var texture = try s2s.deserializeAlloc(reader, Texture, gpa);
    errdefer texture.deinit(gpa);
    if (!texture.isWhole()) return error.UnexpectedData;
    return texture;
}

test "an animated texture keeps every frame and its delay" {
    const gpa = std.testing.allocator;
    var pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    var delays = [_]u32{ 100, 250 };
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .width = 1, .height = 1, .pixels = &pixels, .frame_delays_ms = &delays });
    var reader: std.Io.Reader = .fixed(bytes.written());
    var texture = try read(gpa, &reader);
    defer texture.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), texture.frameCount());
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, texture.frame(1));
    try std.testing.expectEqualSlices(u32, &delays, texture.frame_delays_ms);
}

test "a texture reads back as written, and one short of pixels is refused" {
    const gpa = std.testing.allocator;
    var pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .width = 2, .height = 1, .pixels = &pixels });
    var reader: std.Io.Reader = .fixed(bytes.written());
    var texture = try read(gpa, &reader);
    defer texture.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &pixels, texture.pixels);

    var short: std.Io.Writer.Allocating = .init(gpa);
    defer short.deinit();
    try write(&short.writer, .{ .width = 2, .height = 2, .pixels = &pixels });
    var short_reader: std.Io.Reader = .fixed(short.written());
    try std.testing.expectError(error.UnexpectedData, read(gpa, &short_reader));
}

test "a high-dynamic-range texture keeps light brighter than white, and clips it for bytes" {
    const gpa = std.testing.allocator;
    var pixels: [8]u8 = undefined;
    for ([_]f32{ 4, 0.5, 0, 1 }, 0..) |value, i| setHalf(&pixels, i, value);
    const bright: Texture = .{ .width = 1, .height = 1, .pixels = &pixels, .format = .rgba16_float };
    try std.testing.expect(bright.isWhole());
    try std.testing.expectEqual(@as(f32, 4), bright.linear(bright.frame(0), 0)[0]);
    var shown = try bright.toSrgb8(gpa);
    defer shown.deinit(gpa);
    // Linear 0.5 is sRGB 186.
    try std.testing.expectEqualSlices(u8, &.{ 255, 186, 0, 255 }, shown.pixels);
}
