//! Keeps the shaders this machine compiled between runs, in `<data folder>/shader-cache/`.
const std = @import("std");
const builtin = @import("builtin");
const sdl3 = @import("vitellus_sdl3").sdl;
const vit = @import("vitellus");
const Program = @import("log/log.zig").Program;

const log = std.log.scoped(.shaders);

// One per process, like the log file: renderers make shader modules through plain functions.
var cache: ?vit.ShaderDiskCache = null;

/// Open `program`'s cache folder. Call once, before the first shader is made. Desktop only (a
/// no-op elsewhere); without the folder, shaders compile every run.
pub fn open(io: std.Io, program: Program) void {
    if (builtin.os.tag == .emscripten or builtin.abi.isAndroid()) return;
    const dir = openDir(io, program) catch |err| {
        log.warn("shaders compile every run, with no cache folder: {t}", .{err});
        return;
    };
    cache = .{ .io = io, .dir = dir };
}

/// Close the folder `open` opened. Shaders made afterwards aren't cached.
pub fn close() void {
    const opened = cache orelse return;
    opened.dir.close(opened.io);
    cache = null;
}

/// The open cache, or null when there is none.
pub fn get() ?*const vit.ShaderDiskCache {
    return if (cache) |*opened| opened else null;
}

fn openDir(io: std.Io, program: Program) !std.Io.Dir {
    const pref = try sdl3.filesystem.getPrefPath("eggy", switch (program) {
        .editor => "eggy",
        .game => "games",
    });
    defer sdl3.free(pref);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}shader-cache", .{pref});
    return std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
}
