//! A project's logo (the image `.icon` names in its `eggy.zon`) as a small square thumbnail with
//! rounded corners, the size the launcher lists it at.
const std = @import("std");
const icon = @import("../icon.zig");

/// The thumbnail's side in pixels: a 40-point tile at up to 2.4x pixel density.
pub const side = 96;
pub const Pixels = [side * side * 4]u8;

/// The logo at `icon_path` in `project_dir` as a thumbnail, into `out`. Decoding and allocation
/// errors propagate.
///
/// ```zig
/// var pixels: logo.Pixels = undefined;
/// try logo.decode(gpa, "/home/you/space_game", "resources/icon.png", &pixels);
/// ```
pub fn decode(gpa: std.mem.Allocator, project_dir: []const u8, icon_path: []const u8, out: *Pixels) !void {
    const full_path = try std.fs.path.joinZ(gpa, &.{ project_dir, icon_path });
    defer gpa.free(full_path);
    var decoded = try @import("eggy_model_import").decodeImage(gpa, full_path);
    defer decoded.deinit(gpa);
    var texture = try decoded.toSrgb8(gpa);
    defer texture.deinit(gpa);
    try thumbnail(texture.pixels, texture.width, texture.height, out);
}

/// `image` (straight-alpha RGBA, `width` by `height`) cropped to its centre square, averaged
/// down (or repeated up) to `side`, with its corners rounded off, into `out`.
pub fn thumbnail(image: []const u8, width: u32, height: u32, out: *Pixels) !void {
    if (width == 0 or height == 0 or image.len < @as(usize, width) * height * 4) return error.InvalidImage;
    const crop: usize = @min(width, height);
    const left = (width - crop) / 2;
    const top = (height - crop) / 2;
    const radius: f32 = side * 8.0 / 40.0;
    for (0..side) |y| for (0..side) |x| {
        // Average the source pixels this one covers; at least one when enlarging.
        const x0 = left + x * crop / side;
        const y0 = top + y * crop / side;
        const x1 = @max(x0 + 1, left + (x + 1) * crop / side);
        const y1 = @max(y0 + 1, top + (y + 1) * crop / side);
        var sum: [4]u32 = @splat(0);
        for (y0..y1) |sy| for (x0..x1) |sx| {
            for (&sum, image[(sy * width + sx) * 4 ..][0..4]) |*total, channel| total.* += channel;
        };
        const count: u32 = @intCast((x1 - x0) * (y1 - y0));
        const pixel = out[(y * side + x) * 4 ..][0..4];
        for (pixel, sum) |*channel, total| channel.* = @intCast(total / count);
        const coverage = icon.roundedCoverage(@floatFromInt(x), @floatFromInt(y), side, radius);
        pixel[3] = @intFromFloat(@round(@as(f32, @floatFromInt(pixel[3])) * coverage));
    };
}

test "a wide logo is cropped to its centre and its corners rounded off" {
    // 3 by 1: red, green, blue. The centre square is the green pixel.
    const image = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255 };
    const out = try std.testing.allocator.create(Pixels);
    defer std.testing.allocator.destroy(out);
    try thumbnail(&image, 3, 1, out);
    const middle = (side / 2 * side + side / 2) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, out[middle..][0..4]);
    try std.testing.expectEqual(0, out[3]); // the top-left corner is see-through
    try std.testing.expectError(error.InvalidImage, thumbnail(&image, 0, 1, out));
}
