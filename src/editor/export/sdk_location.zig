//! Where this computer's macOS SDK is, remembered for every project in Eggy's data folder
//! (`macos_sdk.zon`): it is a place on this machine, not part of any one game.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;

const file_name = "macos_sdk.zon";
const Saved = struct { path: []const u8 = "" };

/// The SDK path last saved, into `buffer`; null when none was, or it can't be read.
///
/// ```zig
/// var buffer: [512]u8 = undefined;
/// if (sdk_location.load(&buffer)) |path| try settings.sdk.set(path);
/// ```
pub fn load(buffer: []u8) ?[]const u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var folder = openDataFolder(io) orelse return null;
    defer folder.close(io);
    return read(io, folder, buffer);
}

/// Remember `path` for the next Export window, in any project. Failures are logged.
///
/// ```zig
/// sdk_location.save("/home/me/SDKs/MacOSX.sdk");
/// ```
pub fn save(path: []const u8) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var folder = openDataFolder(io) orelse return;
    defer folder.close(io);
    write(io, folder, path) catch |err| std.log.warn("cannot remember the macOS SDK's folder: {t}", .{err});
}

/// `path` with a leading `~` (alone, or before a `/`) as the home folder, in `arena`; else as is.
pub fn expandHome(arena: std.mem.Allocator, path: []const u8) []const u8 {
    if (!std.mem.eql(u8, path, "~") and !std.mem.startsWith(u8, path, "~/")) return path;
    const home = std.c.getenv("HOME") orelse return path;
    return std.mem.concat(arena, u8, &.{ std.mem.span(home), path[1..] }) catch path;
}

fn openDataFolder(io: std.Io) ?std.Io.Dir {
    const pref = sdl3.filesystem.getPrefPath("eggy", "eggy") catch return null;
    defer sdl3.free(pref);
    return std.Io.Dir.cwd().openDir(io, pref, .{}) catch null;
}

fn read(io: std.Io, folder: std.Io.Dir, buffer: []u8) ?[]const u8 {
    var scratch: [2048]u8 = undefined;
    const text = folder.readFile(io, file_name, scratch[0 .. scratch.len - 1]) catch return null;
    scratch[text.len] = 0;
    var fba_buffer: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
    const saved = std.zon.parse.fromSliceAlloc(Saved, fba.allocator(), scratch[0..text.len :0], null, .{ .ignore_unknown_fields = true }) catch return null;
    if (saved.path.len == 0 or saved.path.len > buffer.len) return null;
    @memcpy(buffer[0..saved.path.len], saved.path);
    return buffer[0..saved.path.len];
}

fn write(io: std.Io, folder: std.Io.Dir, path: []const u8) !void {
    var text_buffer: [2048]u8 = undefined;
    var text: std.Io.Writer = .fixed(&text_buffer);
    try std.zon.stringify.serialize(Saved{ .path = path }, .{}, &text);
    try text.writeByte('\n');
    try folder.writeFile(io, .{ .sub_path = file_name, .data = text.buffered() });
}

test "the SDK's folder is remembered as it was typed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [512]u8 = undefined;
    try std.testing.expect(read(io, tmp.dir, &buffer) == null);
    try write(io, tmp.dir, "/home/me/SDKs/My \"Mac\".sdk");
    try std.testing.expectEqualStrings("/home/me/SDKs/My \"Mac\".sdk", read(io, tmp.dir, &buffer).?);
}

test "a leading tilde is the home folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.SkipZigTest);
    try std.testing.expectEqualStrings(try std.mem.concat(arena.allocator(), u8, &.{ home, "/SDKs" }), expandHome(arena.allocator(), "~/SDKs"));
    try std.testing.expectEqualStrings("/opt/~sdk", expandHome(arena.allocator(), "/opt/~sdk"));
    try std.testing.expectEqualStrings("~other/sdk", expandHome(arena.allocator(), "~other/sdk"));
}
