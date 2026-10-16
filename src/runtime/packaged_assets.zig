//! Model and image files as the runtime draws them: the `.eggmodel`s and `.eggtexture`s
//! packaging made of them, installed in `data/` beside the game's `bin/` (see `addGame`), read
//! with no importer or decoder.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const log = std.log.scoped(.assets);

// ponytail: the web build has no `data/` to read; embed or fetch its models and textures once web games need them.
/// A loader for `eggy.model_cache.ModelCache` reading packaged models.
pub const models: eggy.model_cache.Loader = .{ .context = undefined, .load = loadModel };
/// A loader for `eggy.texture_cache.TextureCache` reading packaged textures.
pub const textures: eggy.texture_cache.Loader = .{ .context = undefined, .load = loadTexture };

fn loadModel(_: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ?eggy.assets.Model {
    return readPackaged(eggy.assets.Model, eggy.assets.model, gpa, path);
}

fn loadTexture(_: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ?eggy.assets.Texture {
    return readPackaged(eggy.assets.Texture, eggy.assets.texture, gpa, path);
}

/// What packaging made of the file at `path` (in the project), read by `format`'s `read`.
fn readPackaged(comptime T: type, comptime format: type, gpa: std.mem.Allocator, path: []const u8) ?T {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const base = sdl3.filesystem.getBasePath() catch |err| {
        log.err("cannot find where the game is: {t}", .{err});
        return null;
    };
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const packaged = std.fmt.bufPrint(&path_buffer, "{s}../data/{s}{s}", .{ base, path, format.extension }) catch return null;

    var file = std.Io.Dir.cwd().openFile(io, packaged, .{}) catch |err| {
        log.err("{s} wasn't packaged with the game ({s}: {t})", .{ path, packaged, err });
        return null;
    };
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return format.read(gpa, &reader.interface) catch |err| {
        log.err("cannot read {s}: {t}", .{ packaged, err });
        return null;
    };
}
