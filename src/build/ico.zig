//! Build tool: `ico <texture> <output>` writes the packaged image `texture` (an `.eggtexture`,
//! whatever file it came from) as a Windows `.ico`, for the game's executable: its first frame,
//! scaled down to fit 256 pixels and centred on a square.
const std = @import("std");
const assets = @import("eggy_assets");

/// The largest side an `.ico` image has.
const max_side = 256;

/// Build-tool entry point: read the `.eggtexture` at the first argument and write the `.ico` at
/// the second. Requires exactly two arguments; read, decode and write errors propagate.
///
/// ```sh
/// eggy_ico data/0123456789abcdef icon.ico
/// ```
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;

    var input = try std.Io.Dir.cwd().openFile(io, args[1], .{});
    defer input.close(io);
    var input_buffer: [64 * 1024]u8 = undefined;
    var reader = input.reader(io, &input_buffer);
    var texture = try assets.texture.read(gpa, &reader.interface);
    defer texture.deinit(gpa);

    const ico = try icoFor(gpa, texture.frame(0), texture.width, texture.height);
    defer gpa.free(ico);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = ico });
}

/// `rgba` (`width` by `height`, top row first) as a one-image `.ico`: a 32-bit bitmap with an
/// empty mask (its alpha says what shows), at most `max_side` square. Fails for an empty image.
fn icoFor(gpa: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) ![]u8 {
    if (width == 0 or height == 0) return error.EmptyImage;

    // The image's size once fitted into the icon, and where it sits in the square.
    const longest = @max(width, height);
    const side: u32 = @min(longest, max_side);
    const shown_w = @max(1, @as(u32, @intCast(@as(u64, width) * side / longest)));
    const shown_h = @max(1, @as(u32, @intCast(@as(u64, height) * side / longest)));
    const left = (side - shown_w) / 2;
    const top = (side - shown_h) / 2;

    const pixels_size = side * side * 4;
    const mask_row = (side + 31) / 32 * 4;
    const image_size = 40 + pixels_size + mask_row * side;
    const ico = try gpa.alloc(u8, 6 + 16 + image_size);
    @memset(ico, 0);
    var w: std.Io.Writer = .fixed(ico);

    // The header and the one image's entry (0 stands for 256).
    const entry_side: u8 = if (side >= 256) 0 else @intCast(side);
    try w.writeAll(&.{ 0, 0, 1, 0, 1, 0, entry_side, entry_side, 0, 0, 1, 0, 32, 0 });
    try w.writeInt(u32, image_size, .little);
    try w.writeInt(u32, 6 + 16, .little);

    // The bitmap's header: its height counts the mask too.
    try w.writeInt(u32, 40, .little);
    try w.writeInt(i32, @intCast(side), .little);
    try w.writeInt(i32, @intCast(side * 2), .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u16, 32, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, pixels_size + mask_row * side, .little);

    // Blue, green, red and alpha, bottom row first, each pixel the average of the source's
    // pixels it covers; the mask after them stays zero.
    const pixels = ico[6 + 16 + 40 ..][0..pixels_size];
    for (0..shown_h) |y| for (0..shown_w) |x| {
        const x0 = x * width / shown_w;
        const x1 = @max(x0 + 1, (x + 1) * width / shown_w);
        const y0 = y * height / shown_h;
        const y1 = @max(y0 + 1, (y + 1) * height / shown_h);
        var sum: [4]u64 = .{ 0, 0, 0, 0 };
        for (y0..y1) |sy| for (x0..x1) |sx| {
            for (&sum, rgba[(sy * width + sx) * 4 ..][0..4]) |*total, channel| total.* += channel;
        };
        const count = (x1 - x0) * (y1 - y0);
        const row = side - 1 - (top + y);
        const out = pixels[(row * side + left + x) * 4 ..][0..4];
        out.* = .{ @intCast(sum[2] / count), @intCast(sum[1] / count), @intCast(sum[0] / count), @intCast(sum[3] / count) };
    };
    return ico;
}

test "an image becomes a square icon, bottom row first in blue-green-red-alpha" {
    // 2 wide, 1 tall: red then blue, centred on a 2 by 2 square.
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 };
    const ico = try icoFor(std.testing.allocator, &rgba, 2, 1);
    defer std.testing.allocator.free(ico);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 1, 0, 2, 2 }, ico[0..8]);
    // The bitmap is twice as tall as the icon (the mask under it).
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, ico[22 + 8 ..][0..4], .little));
    // The image sits on the top row, which is stored last; the bottom row is see-through.
    const pixels = ico[22 + 40 ..];
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 255, 0, 0, 255 }, pixels[8..16]);
    try std.testing.expectError(error.EmptyImage, icoFor(std.testing.allocator, &.{}, 0, 0));
}

test "a large image is scaled to 256, written as 0 in the entry" {
    const rgba = try std.testing.allocator.alloc(u8, 512 * 512 * 4);
    defer std.testing.allocator.free(rgba);
    @memset(rgba, 200);
    const ico = try icoFor(std.testing.allocator, rgba, 512, 512);
    defer std.testing.allocator.free(ico);
    try std.testing.expectEqual(@as(u8, 0), ico[6]);
    try std.testing.expectEqual(@as(i32, 256), std.mem.readInt(i32, ico[22 + 4 ..][0..4], .little));
    try std.testing.expectEqualSlices(u8, &.{ 200, 200, 200, 200 }, ico[22 + 40 ..][0..4]);
}
