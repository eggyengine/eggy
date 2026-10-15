//! `eggy_package_models`: packaging's step for models, run by `addGame` when it builds the game.
//! Each model file named gets imported (with its descriptor's settings) and written as an
//! `.eggmodel`, which the runtime loads without an importer.
//!
//!     eggy_package_models <project dir> <output dir> <model path>...
const std = @import("std");
const assets = @import("eggy_assets");
const model_import = @import("eggy_model_import");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.log.err("usage: eggy_package_models <project dir> <output dir> <model path>...", .{});
        return error.Usage;
    }
    var project = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer project.close(io);
    var output = try std.Io.Dir.cwd().createDirPathOpen(io, args[2], .{});
    defer output.close(io);

    var failed = false;
    for (args[3..]) |path| packageModel(gpa, io, project, args[1], output, path) catch |err| {
        std.log.err("cannot package {s}: {t}", .{ path, err });
        failed = true;
    };
    if (failed) return error.PackagingFailed;
}

/// Import the model at `path` (in `project`, found at `project_dir`) and write it into `output`
/// as `<path>.eggmodel`.
fn packageModel(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, project_dir: []const u8, output: std.Io.Dir, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const descriptor = try assets.descriptor.read(arena.allocator(), io, project, path);
    const settings = if (descriptor) |found| found.model else assets.descriptor.ModelImport{};

    const full_path = try std.fs.path.joinZ(arena.allocator(), &.{ project_dir, path });
    var model = model_import.import(gpa, full_path, settings) catch |err| {
        std.log.err("{s}: {s}", .{ path, model_import.lastError() });
        return err;
    };
    defer model.deinit(gpa);

    const out_path = try std.fmt.allocPrint(arena.allocator(), "{s}" ++ assets.model.extension, .{path});
    if (std.fs.path.dirname(out_path)) |folder| try output.createDirPath(io, folder);
    var file = try output.createFile(io, out_path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try assets.model.write(&writer.interface, model);
}
