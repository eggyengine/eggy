//! The game's resources as packaging installed them in `data/` beside its `bin/` (see
//! `addGame`): models and images as the `.eggmodel`s and `.eggtexture`s made of them, read with
//! no importer or decoder, and every other file (scenes...) as it is (`openData`).
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

/// The game's `data/` folder.
pub fn openData(io: std.Io) !std.Io.Dir {
    const base = try sdl3.filesystem.getBasePath();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    return std.Io.Dir.cwd().openDir(io, try std.fmt.bufPrint(&path_buffer, "{s}../data", .{base}), .{});
}

/// What packaging made of the file at `path` (in the project), read by `format`'s `read`.
fn readPackaged(comptime T: type, comptime format: type, gpa: std.mem.Allocator, path: []const u8) ?T {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var data = openData(io) catch |err| {
        log.err("cannot find the game's data: {t}", .{err});
        return null;
    };
    defer data.close(io);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const packaged = std.fmt.bufPrint(&path_buffer, "{s}{s}", .{ path, format.extension }) catch return null;
    var file = data.openFile(io, packaged, .{}) catch |err| {
        log.err("{s} wasn't packaged with the game ({t})", .{ path, err });
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
