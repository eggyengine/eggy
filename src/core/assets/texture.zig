//! The `.eggtexture` format: an image's pixels, ready to put on the GPU, in s2s's binary form.
//! Packaging writes one for each image file (decoded with stb_image); the runtime reads them,
//! with no decoder of its own. The editor decodes image files directly instead.
const std = @import("std");
const s2s = @import("s2s");

/// An image: rows of red, green, blue and alpha bytes (as the file stores them, sRGB), top row
/// first.
pub const Texture = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    /// Free what `read` (or a decoder) allocated with `gpa`.
    pub fn deinit(self: *Texture, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }

    /// Whether `pixels` holds exactly `width` by `height` of them, and there are some.
    pub fn isWhole(self: Texture) bool {
        return self.width > 0 and self.height > 0 and self.pixels.len == @as(usize, self.width) * self.height * 4;
    }
};

/// Write `texture` as an `.eggtexture`.
pub fn write(writer: *std.Io.Writer, texture: Texture) std.Io.Writer.Error!void {
    try s2s.serialize(writer, Texture, texture);
}

/// Read an `.eggtexture`, allocating with `gpa` (see `Texture.deinit`). Fails with
/// `error.UnexpectedData` for one of another version, or whose pixels don't fill it.
pub fn read(gpa: std.mem.Allocator, reader: *std.Io.Reader) !Texture {
    var texture = try s2s.deserializeAlloc(reader, Texture, gpa);
    errdefer texture.deinit(gpa);
    if (!texture.isWhole()) return error.UnexpectedData;
    return texture;
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
