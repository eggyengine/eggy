//! The editor's icon, the pixel-art egg from `resources/icon.png`, put on its windows and drawn
//! in Help > About Eggy.
const std = @import("std");
const sdl3 = @import("eggy").sdl_adapter.sdl;

/// Give `window` the editor's icon. A desktop that ignores icons is not an error worth stopping for.
/// Requires a live SDL window; decodes embedded PNG bytes, sets the icon, and frees the
/// intermediate surface. Failures are logged, with no ownership transferred to the caller.
///
/// ```zig
/// icon.apply(app.window.window); // Editor host, after creating its SDL window.
/// ```
pub fn apply(window: sdl3.video.Window) void {
    set(window) catch |err| std.log.warn("cannot set the window icon: {t}", .{err});
}

fn set(window: sdl3.video.Window) !void {
    const stream = try sdl3.io_stream.Stream.initFromConstMem(@embedFile("editor_icon"));
    const icon = try sdl3.surface.Surface.initFromPngIo(stream, true);
    defer icon.deinit();
    try window.setIcon(icon);
}

/// The icon's pixel art: `size` by `size` RGBA pixels, row by row from the top.
pub const Pixels = [size][size][4]u8;
/// The icon's pixel art is this many pixels across, each drawn as a square block of the PNG.
pub const size = 32;

/// The icon's pixel art, read from the centre of each block of the embedded PNG. Decoding
/// failures propagate.
///
/// ```zig
/// const egg = try icon.pixels();
/// const top_left_alpha = egg[0][0][3]; // 0: the corners are see-through
/// ```
pub fn pixels() !Pixels {
    const stream = try sdl3.io_stream.Stream.initFromConstMem(@embedFile("editor_icon"));
    const png = try sdl3.surface.Surface.initFromPngIo(stream, true);
    defer png.deinit();
    const block = png.getWidth() / size;
    var art: Pixels = undefined;
    for (&art, 0..) |*row, y| for (row, 0..) |*pixel, x| {
        const color = try png.readPixel(x * block + block / 2, y * block + block / 2);
        pixel.* = .{ color.r, color.g, color.b, color.a };
    };
    return art;
}

test "the icon's pixel art is an egg: see-through corners, an opaque middle" {
    const art = try pixels();
    try std.testing.expectEqual(@as(u8, 0), art[0][0][3]);
    try std.testing.expectEqual(@as(u8, 255), art[size / 2][size / 2][3]);
}
