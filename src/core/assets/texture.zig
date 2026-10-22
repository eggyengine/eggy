//! The `.eggtexture` format: an image's pixels, ready to put on the GPU, in s2s's binary form.
//! Packaging writes one for each image file (decoded with stb_image); the runtime reads them,
//! with no decoder of its own. The editor decodes image files directly instead.
const std = @import("std");
const s2s = @import("s2s");

/// An image: rows of red, green, blue and alpha bytes (as the file stores them, sRGB), top row
/// first. An animated one (a GIF) holds each frame's pixels one after another, each shown for its
/// `frame_delays_ms`; meshes are painted with the first.
pub const Texture = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    /// How long each frame shows; empty for a still image (one frame).
    frame_delays_ms: []u32 = &.{},

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
        const size = @as(usize, self.width) * self.height * 4;
        return self.pixels[index * size ..][0..size];
    }

    /// Whether `pixels` holds exactly `width` by `height` of them for each frame, and there are
    /// some. Checks RGBA byte count without modifying or decoding the pixels.
    ///
    /// ```zig
    /// if (!texture.isWhole()) return error.InvalidTexture;
    /// ```
    pub fn isWhole(self: Texture) bool {
        return self.width > 0 and self.height > 0 and self.pixels.len == @as(usize, self.width) * self.height * 4 * self.frameCount();
    }
};

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
/// Reader/allocation errors propagate; the caller owns the returned RGBA bytes.
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
