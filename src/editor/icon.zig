//! The editor's icon, the pixel-art egg from `resources/icon.png`, put on its windows and drawn
//! in Help > About Eggy; with a project icon set, the egg wears it in its bottom-right corner.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;

/// Give `window` the editor's icon: the badged one while `useBadge` has one, else the egg. A
/// desktop that ignores icons is not an error worth stopping for.
/// Requires a live SDL window; sets the icon and frees the intermediate surface. Failures are
/// logged, with no ownership transferred to the caller.
///
/// ```zig
/// icon.apply(app.window.window); // Editor host, after creating its SDL window.
/// ```
pub fn apply(window: sdl3.video.Window) void {
    set(window) catch |err| std.log.warn("cannot set the window icon: {t}", .{err});
}

/// A badged icon's side, in pixels: the egg's blocks drawn this many pixels each.
pub const badged_size = size * 8;
/// The badged icon's pixels (`badged_size` square, RGBA, top row first).
pub const Badged = [badged_size * badged_size * 4]u8;

/// The icon every window gets from `apply` from now on: `badged` (copied), or the egg for null.
/// Windows already open keep theirs until `apply` is called on them again.
pub fn useBadge(badged: ?*const Badged) void {
    if (badged) |art| {
        current = art.*;
        has_badge = true;
    } else has_badge = false;
}

// ponytail: one editor process shows one project, so the badge is process-wide; key it by window if that changes.
var current: Badged = undefined;
var has_badge = false;

/// Badge the egg with the project's icon, the image file at `icon_path` in `project_dir`, for
/// every window `apply` is called on from now on; null (or a file that won't decode, which is
/// logged) goes back to the plain egg. Call `apply` on open windows afterwards.
///
/// ```zig
/// icon.useProjectIcon(gpa, opened.dir, config.icon);
/// icon.apply(app.window.window);
/// ```
pub fn useProjectIcon(gpa: std.mem.Allocator, project_dir: []const u8, icon_path: ?[]const u8) void {
    const path = icon_path orelse return useBadge(null);
    const badged = gpa.create(Badged) catch return useBadge(null);
    defer gpa.destroy(badged);
    decodeBadge(gpa, project_dir, path, badged) catch |err| {
        std.log.warn("cannot use {s} as the project's icon: {t}", .{ path, err });
        return useBadge(null);
    };
    useBadge(badged);
}

/// The egg badged with the image file at `path` in `project_dir`, into `out`.
/// Decoding and allocation errors propagate.
pub fn decodeBadge(gpa: std.mem.Allocator, project_dir: []const u8, path: []const u8, out: *Badged) !void {
    const full_path = try std.fs.path.joinZ(gpa, &.{ project_dir, path });
    defer gpa.free(full_path);
    var texture = try @import("eggy_model_import").decodeImage(gpa, full_path);
    defer texture.deinit(gpa);
    try badge(texture.pixels, texture.width, texture.height, out);
}

/// The egg with `image` (straight-alpha RGBA, `width` by `height`) over its bottom-right
/// corner, into `out`: scaled to fit half the icon, keeping its shape, on a rounded dark plate
/// so it reads over the egg. Fails when the image is empty or the egg can't be decoded.
///
/// ```zig
/// try icon.badge(texture.pixels, texture.width, texture.height, &badged);
/// icon.useBadge(&badged);
/// ```
pub fn badge(image: []const u8, width: u32, height: u32, out: *Badged) !void {
    if (width == 0 or height == 0 or image.len < @as(usize, width) * height * 4) return error.InvalidImage;
    const egg = try pixels();

    // The egg, each of its blocks a square of pixels.
    const block = badged_size / size;
    for (0..badged_size) |y| for (0..badged_size) |x| {
        out[(y * badged_size + x) * 4 ..][0..4].* = egg[y / block][x / block];
    };

    // The plate the image sits on, then the image, nearest-sampled to keep pixel art crisp.
    const plate = badged_size / 2 + badged_size / 16;
    const plate_at = badged_size - plate;
    const radius: f32 = @floatFromInt(plate / 5);
    for (plate_at..badged_size) |y| for (plate_at..badged_size) |x| {
        const coverage = roundedCoverage(@floatFromInt(x - plate_at), @floatFromInt(y - plate_at), @floatFromInt(plate), radius);
        blend(out[(y * badged_size + x) * 4 ..][0..4], .{ 28, 25, 21, 255 }, coverage);
    };
    const inset = badged_size / 32;
    const room: f32 = @floatFromInt(plate - 2 * inset);
    const scale = room / @as(f32, @floatFromInt(@max(width, height)));
    const shown_w: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(width)) * scale))));
    const shown_h: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(height)) * scale))));
    const left = plate_at + inset + (plate - 2 * inset - shown_w) / 2;
    const top = plate_at + inset + (plate - 2 * inset - shown_h) / 2;
    for (0..shown_h) |y| for (0..shown_w) |x| {
        const sx = @min(width - 1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(x)) / scale)));
        const sy = @min(height - 1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(y)) / scale)));
        const source = image[(@as(usize, sy) * width + sx) * 4 ..][0..4];
        blend(out[((top + y) * badged_size + left + x) * 4 ..][0..4], source[0..3].* ++ [1]u8{255}, @as(f32, @floatFromInt(source[3])) / 255);
    };
}

/// `color` over `pixel` by `coverage` (0 to 1), keeping the result's alpha the larger.
fn blend(pixel: *[4]u8, color: [4]u8, coverage: f32) void {
    if (coverage <= 0) return;
    for (pixel[0..3], color[0..3]) |*channel, over| {
        channel.* = @intFromFloat(@round(@as(f32, @floatFromInt(channel.*)) * (1 - coverage) + @as(f32, @floatFromInt(over)) * coverage));
    }
    pixel[3] = @max(pixel[3], @as(u8, @intFromFloat(@round(coverage * 255))));
}

/// How much of the pixel at `x`, `y` a `side` square with corners rounded by `radius` covers.
fn roundedCoverage(x: f32, y: f32, side: f32, radius: f32) f32 {
    const cx = std.math.clamp(x + 0.5, radius, side - radius);
    const cy = std.math.clamp(y + 0.5, radius, side - radius);
    const distance = @sqrt((x + 0.5 - cx) * (x + 0.5 - cx) + (y + 0.5 - cy) * (y + 0.5 - cy));
    return std.math.clamp(radius - distance + 0.5, 0, 1);
}

fn set(window: sdl3.video.Window) !void {
    if (has_badge) {
        const surface = try sdl3.surface.Surface.initFrom(badged_size, badged_size, .array_rgba_32, &current);
        defer surface.deinit();
        return window.setIcon(surface);
    }
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

test "a badge keeps the egg's top left and puts the image in the bottom right" {
    const red = [_]u8{ 255, 0, 0, 255 } ** 4;
    const badged = try std.testing.allocator.create(Badged);
    defer std.testing.allocator.destroy(badged);
    try badge(&red, 2, 2, badged);
    const egg = try pixels();
    // The top-left corner is the egg's, see-through.
    try std.testing.expectEqual(egg[0][0][3], badged[3]);
    // The bottom-right quarter's middle is the image's red.
    const at = (badged_size * 3 / 4 * badged_size + badged_size * 3 / 4) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, badged[at..][0..4]);
    try std.testing.expectError(error.InvalidImage, badge(&.{}, 0, 0, badged));
}

test "the icon's pixel art is an egg: see-through corners, an opaque middle" {
    const art = try pixels();
    try std.testing.expectEqual(@as(u8, 0), art[0][0][3]);
    try std.testing.expectEqual(@as(u8, 255), art[size / 2][size / 2][3]);
}
