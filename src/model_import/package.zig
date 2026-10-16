//! `eggy_package_assets`: packaging's step for models and images, run by `addGame` when it
//! builds the game. Each model file named gets imported (with its descriptor's settings) and
//! written as an `.eggmodel`, and each image file decoded and written as an `.eggtexture`, which
//! the runtime loads without an importer.
//!
//!     eggy_package_assets <project dir> <output dir> <model or image path>...
const std = @import("std");
const assets = @import("eggy_assets");
const model_import = @import("eggy_model_import");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.log.err("usage: eggy_package_assets <project dir> <output dir> <model or image path>...", .{});
        return error.Usage;
    }
    var project = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer project.close(io);
    var output = try std.Io.Dir.cwd().createDirPathOpen(io, args[2], .{});
    defer output.close(io);

    var failed = false;
    for (args[3..]) |path| packageFile(gpa, io, project, args[1], output, path) catch |err| {
        std.log.err("cannot package {s}: {t}", .{ path, err });
        failed = true;
    };
    if (failed) return error.PackagingFailed;
}

/// Convert the model or image at `path` (in `project`, found at `project_dir`) and write it into
/// `output` as `<path>.eggmodel` or `<path>.eggtexture`.
fn packageFile(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, project_dir: []const u8, output: std.Io.Dir, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const full_path = try std.fs.path.joinZ(arena.allocator(), &.{ project_dir, path });
    const kind = assets.Kind.of(path);
    const out_path = try std.fmt.allocPrint(arena.allocator(), "{s}{s}", .{ path, if (kind == .model) assets.model.extension else assets.texture.extension });
    if (std.fs.path.dirname(out_path)) |folder| try output.createDirPath(io, folder);
    var file = try output.createFile(io, out_path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);

    switch (kind) {
        .model => {
            const descriptor = try assets.descriptor.read(arena.allocator(), io, project, path);
            const settings = if (descriptor) |found| found.model else assets.descriptor.ModelImport{};
            var model = model_import.import(gpa, full_path, settings) catch |err| {
                std.log.err("{s}: {s}", .{ path, model_import.lastError() });
                return err;
            };
            defer model.deinit(gpa);
            try assets.model.write(&writer.interface, model);
        },
        .image => {
            var texture = model_import.decodeImage(gpa, full_path) catch |err| {
                std.log.err("{s}: {s}", .{ path, model_import.lastError() });
                return err;
            };
            defer texture.deinit(gpa);
            try assets.texture.write(&writer.interface, texture);
        },
        else => return error.NotModelOrImage,
    }
    try writer.interface.flush();
}
