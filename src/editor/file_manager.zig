//! Showing a folder in the system's file manager (Explorer, Finder, or whatever the desktop
//! uses), or a file in the app the system opens it with.
const builtin = @import("builtin");
const std = @import("std");
const sdl3 = @import("eggy").sdl_adapter.sdl;

/// Open `dir` (absolute) in the file manager. Returns once one is launched, not once it shows.
pub fn showFolder(gpa: std.mem.Allocator, dir: []const u8) !void {
    const url = try folderUrl(gpa, dir);
    defer gpa.free(url);
    try sdl3.openURL(url);
}

/// Open `file` (absolute) in the app the system opens it with.
pub fn openFile(gpa: std.mem.Allocator, file: []const u8) !void {
    const url = try folderUrl(gpa, file);
    defer gpa.free(url);
    try sdl3.openURL(url);
}

/// What SDL's `openURL` takes for `dir`: a `file://` URL, except on Windows, whose shell opens a
/// folder's own path. Caller-owned.
fn folderUrl(gpa: std.mem.Allocator, dir: []const u8) ![:0]u8 {
    if (builtin.os.tag == .windows) return gpa.dupeZ(u8, dir);
    return std.fmt.allocPrintSentinel(gpa, "file://{f}", .{std.fmt.alt(std.Uri.Component{ .raw = dir }, .formatPath)}, 0);
}

test "a folder's URL escapes what a URL can't hold" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const url = try folderUrl(std.testing.allocator, "/home/me/My Game");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("file:///home/me/My%20Game", url);
}
