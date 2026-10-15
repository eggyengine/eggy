//! Model files as the runtime draws them: the `.eggmodel`s packaging made of them, installed in
//! `data/` beside the game's `bin/` (see `addGame`), read with no importer.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const log = std.log.scoped(.models);

/// A loader for `eggy.model_cache.ModelCache` reading packaged models.
// ponytail: the web build has no `data/` to read; embed or fetch its models once web games need them.
pub const loader: eggy.model_cache.Loader = .{ .context = undefined, .load = load };

fn load(_: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ?eggy.assets.Model {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const base = sdl3.filesystem.getBasePath() catch |err| {
        log.err("cannot find where the game is: {t}", .{err});
        return null;
    };
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const packaged = std.fmt.bufPrint(&path_buffer, "{s}../data/{s}{s}", .{ base, path, eggy.assets.model.extension }) catch return null;

    var file = std.Io.Dir.cwd().openFile(io, packaged, .{}) catch |err| {
        log.err("{s} wasn't packaged with the game ({s}: {t})", .{ path, packaged, err });
        return null;
    };
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return eggy.assets.model.read(gpa, &reader.interface) catch |err| {
        log.err("cannot read {s}: {t}", .{ packaged, err });
        return null;
    };
}
