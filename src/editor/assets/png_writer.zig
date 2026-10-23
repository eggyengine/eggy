//! Writing RGBA pixels as a PNG file, so a texture a model carries inside it can be saved out
//! and edited in an image editor.
const std = @import("std");
const flate = std.compress.flate;

/// Write `width` by `height` RGBA8 `pixels` (`width * height * 4` bytes, rows top to bottom) to
/// `out` as a PNG. Rows are stored unfiltered and deflated with zlib. Allocates the compressed
/// image with `gpa` while writing; writer and allocation errors propagate.
pub fn write(gpa: std.mem.Allocator, out: *std.Io.Writer, width: u32, height: u32, pixels: []const u8) !void {
    std.debug.assert(pixels.len == @as(usize, width) * height * 4);
    try out.writeAll("\x89PNG\r\n\x1a\n");

    // The header: 8 bits per channel, colour with alpha, no interlacing.
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(out, "IHDR", &header);

    // Each row behind a "no filter" byte, deflated together (the compressor needs room to
    // write into before it starts).
    var compressed = try std.Io.Writer.Allocating.initCapacity(gpa, 64 * 1024);
    defer compressed.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var deflate = try flate.Compress.init(&compressed.writer, window, .zlib, .default);
    const row_len = @as(usize, width) * 4;
    for (0..height) |y| {
        try deflate.writer.writeByte(0);
        try deflate.writer.writeAll(pixels[y * row_len ..][0..row_len]);
    }
    try deflate.finish();
    try chunk(out, "IDAT", compressed.written());
    try chunk(out, "IEND", "");
}

// A chunk: its length, type, data, and the CRC of type and data.
fn chunk(out: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try out.writeInt(u32, @intCast(data.len), .big);
    try out.writeAll(kind);
    try out.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try out.writeInt(u32, crc.final(), .big);
}

test "a PNG holds its size and, inflated, each row behind a filter byte" {
    const gpa = std.testing.allocator;
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 9, 9, 9, 0 };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, 2, 2, &pixels);
    const png = out.written();
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", png[0..8]);
    try std.testing.expectEqualStrings("IHDR", png[12..16]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[16..20], .big));
    try std.testing.expectEqualStrings("IEND", png[png.len - 8 ..][0..4]);

    // The image data, inflated again.
    const idat_len = std.mem.readInt(u32, png[33..37], .big);
    try std.testing.expectEqualStrings("IDAT", png[37..41]);
    var input: std.Io.Reader = .fixed(png[41..][0..idat_len]);
    var window: [flate.max_window_len]u8 = undefined;
    var inflate = flate.Decompress.init(&input, .zlib, &window);
    var rows: std.Io.Writer.Allocating = .init(gpa);
    defer rows.deinit();
    _ = try inflate.reader.streamRemaining(&rows.writer);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ++ pixels[0..8].* ++ [_]u8{0} ++ pixels[8..16].*), rows.written());
}
