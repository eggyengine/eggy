//! A project's tile, as the launcher and the build window show it: its logo when it has one, else
//! its initial on a colour picked from its title, so a project keeps its colour everywhere.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const logo = @import("logo.zig");

/// The logo of the project in `project_dir` (its `eggy.zon`'s `.icon`), packed into `font`'s
/// atlas; null when it has none or it can't be read, which is logged.
/// ponytail: the font's atlas never frees a sprite, so each load takes new room; give logos their own textures if windows showing them open often.
///
/// ```zig
/// const sprite = project_tile.loadLogo(gpa, font, "/home/me/game", "resources/icon.png");
/// ```
pub fn loadLogo(gpa: std.mem.Allocator, font: *ui.Font, project_dir: []const u8, icon_path: []const u8) ?ui.Glyph {
    const pixels = gpa.create(logo.Pixels) catch return null;
    defer gpa.destroy(pixels);
    logo.decode(gpa, project_dir, icon_path, pixels) catch |err| {
        std.log.warn("cannot show {s}'s logo {s}: {t}", .{ project_dir, icon_path, err });
        return null;
    };
    return font.addSprite(pixels, logo.side, logo.side) catch null;
}

/// The logo of the project in `project_dir`, read from its `eggy.zon`; null without one.
///
/// ```zig
/// const sprite = project_tile.projectLogo(gpa, font, "/home/me/game");
/// ```
pub fn projectLogo(gpa: std.mem.Allocator, font: *ui.Font, project_dir: []const u8) ?ui.Glyph {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, project_dir, .{}) catch return null;
    defer dir.close(io);
    const config = eggy.project.load(arena.allocator(), io, dir) catch return null;
    return loadLogo(gpa, font, project_dir, config.icon orelse return null);
}

/// How a tile is drawn.
pub const Look = enum {
    /// In colour.
    normal,
    /// Faded: a project whose folder is gone.
    missing,
};

/// Draw `title`'s tile in `r`: `sprite` when given, else its initial on its colour, with corners
/// rounded by `radius` points.
///
/// ```zig
/// try project_tile.draw(c, .{ .x = 0, .y = 0, .w = 40, .h = 40 }, "Space", null, 8, .normal);
/// ```
pub fn draw(c: *ui.Canvas, r: ui.Rect, title: []const u8, sprite: ?ui.Glyph, radius: f32, look: Look) !void {
    const t = c.theme;
    const text_size = r.h * 0.4;
    if (sprite) |glyph| return c.image(r, glyph, if (look == .missing) 0.5 else 1);
    if (look == .missing) {
        try c.roundRectStroke(r, t.border, radius, 1.5);
        return c.textIn(r, initial(title), text_size, t.muted_foreground, .center);
    }
    const colors = colorsFor(title, isDark(t));
    try c.roundRect(r, colors.fill, radius);
    try c.textIn(r, initial(title), text_size, colors.ink, .center);
}

/// `dir` with the home folder shortened to `~`, in `arena` (or `dir` itself).
///
/// ```zig
/// const shown = project_tile.homeRelative(arena, "/home/me/game"); // "~/game"
/// ```
pub fn homeRelative(arena: std.mem.Allocator, dir: []const u8) []const u8 {
    const home = eggy.sdl_adapter.sdl.filesystem.getUserFolder(.home) catch return dir;
    const trimmed = std.mem.trimEnd(u8, home, "/\\");
    if (trimmed.len == 0 or !std.mem.startsWith(u8, dir, trimmed)) return dir;
    return std.fmt.allocPrint(arena, "~{s}", .{dir[trimmed.len..]}) catch dir;
}

/// The first character of `title`, upper-cased when it's a letter.
pub fn initial(title: []const u8) []const u8 {
    if (title.len == 0) return "?";
    const len = std.unicode.utf8ByteSequenceLength(title[0]) catch 1;
    if (len == 1 and std.ascii.isLower(title[0])) return uppers[title[0] - 'a' ..][0..1];
    return title[0..@min(len, title.len)];
}
const uppers = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

/// A tile's colours, picked from `title`, for a dark or light theme.
pub fn colorsFor(title: []const u8, dark: bool) struct { fill: ui.Color, ink: ui.Color } {
    const dark_tiles = [_][2]u24{ .{ 0x3A2E14, 0xF5C969 }, .{ 0x26301F, 0xB8D49A }, .{ 0x2B2838, 0xBDB6EC }, .{ 0x3A231E, 0xF2A88F } };
    const light_tiles = [_][2]u24{ .{ 0xFCEFD2, 0x7A4E00 }, .{ 0xE4EED9, 0x3D5A22 }, .{ 0xE6E3F6, 0x463E8A }, .{ 0xF8E1DA, 0x8A3B26 } };
    const tiles = if (dark) dark_tiles else light_tiles;
    const pair = tiles[std.hash.Wyhash.hash(0, title) % tiles.len];
    return .{ .fill = hex(pair[0]), .ink = hex(pair[1]) };
}

/// `value` (0xRRGGBB) as a colour.
pub fn hex(value: u24) ui.Color {
    return .{ @as(f32, @floatFromInt(value >> 16)) / 255, @as(f32, @floatFromInt((value >> 8) & 0xFF)) / 255, @as(f32, @floatFromInt(value & 0xFF)) / 255 };
}

/// Whether `theme` is a dark one.
pub fn isDark(theme: ui.Theme) bool {
    const bg = theme.background;
    return 0.3 * bg[0] + 0.59 * bg[1] + 0.11 * bg[2] < 0.5;
}

test "a tile shows the title's first character, upper-cased" {
    try std.testing.expectEqualStrings("N", initial("nido"));
    try std.testing.expectEqualStrings("F", initial("Foobar"));
    try std.testing.expectEqualStrings("\u{e9}", initial("\u{e9}clair"));
    try std.testing.expectEqualStrings("?", initial(""));
}

test "a project keeps its colour" {
    try std.testing.expectEqual(colorsFor("Space", true), colorsFor("Space", true));
}
