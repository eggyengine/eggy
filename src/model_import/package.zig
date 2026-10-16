//! `eggy_package_assets`: packaging's step for models and images, run by `addGame` when it
//! builds the game. Each model file named gets imported (with its descriptor's settings) and
//! written as an `.eggmodel`, and each image file decoded and written as an `.eggtexture`, under
//! the name given (its id: see `assets.manifest`), which the runtime loads without an importer.
//!
//!     eggy_package_assets <project dir> <output dir> [<model or image path> <packaged name>]...
const std = @import("std");
const assets = @import("eggy_assets");
const model_import = @import("eggy_model_import");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.log.err("usage: eggy_package_assets <project dir> <output dir> [<model or image path> <packaged name>]...", .{});
        return error.Usage;
    }
    var project = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer project.close(io);
    var output = try std.Io.Dir.cwd().createDirPathOpen(io, args[2], .{});
    defer output.close(io);

    var failed = false;
    const pairs = args[3..];
    if (pairs.len % 2 != 0) return error.Usage;
    var i: usize = 0;
    while (i < pairs.len) : (i += 2) packageFile(gpa, io, project, args[1], output, pairs[i], pairs[i + 1]) catch |err| {
        std.log.err("cannot package {s}: {t}", .{ pairs[i], err });
        failed = true;
    };
    if (failed) return error.PackagingFailed;
}

/// Convert the model or image at `path` (in `project`, found at `project_dir`) and write it into
/// `output` as `name`.
fn packageFile(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, project_dir: []const u8, output: std.Io.Dir, path: []const u8, name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const full_path = try std.fs.path.joinZ(arena.allocator(), &.{ project_dir, path });
    const kind = assets.Kind.of(path);
    var file = try output.createFile(io, name, .{});
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
