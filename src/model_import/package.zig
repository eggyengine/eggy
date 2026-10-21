//! Convert project assets to identity-only payloads and emit their compile-time Zig lookup.
const std = @import("std");
const assets = @import("eggy_assets");
const model_import = @import("eggy_model_import");

/// Build-tool entry point. Output contains no index: every filename is a canonical asset key.
/// Arguments after the three outputs are source-path, source-ID, kind and import-scale groups.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4 or (args.len - 4) % 4 != 0) {
        std.log.err("usage: eggy_package_assets <project dir> <output dir> <lookup.zig> [<path> <id> <kind> <scale>]...", .{});
        return error.Usage;
    }
    var project = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer project.close(io);
    var output = try std.Io.Dir.cwd().createDirPathOpen(io, args[2], .{});
    defer output.close(io);
    const files = try arena.alloc(assets.package.Entry, (args.len - 4) / 4);
    var aliases = assets.registry.Builder{ .gpa = gpa };
    defer aliases.deinit();
    for (files, 0..) |*entry, index| {
        const arg = args[4 + index * 4 ..][0..4];
        entry.* = .{
            .path = arg[0],
            .id = try assets.id.parse(arg[1]),
            .kind = std.meta.stringToEnum(assets.Kind, arg[2]) orelse return error.InvalidAssetKind,
            .model = .{ .scale = try std.fmt.parseFloat(f32, arg[3]) },
        };
        try aliases.claim(entry.id);
    }

    var failed = false;
    for (files) |entry| packageFile(gpa, arena, io, project, args[1], output, entry, &aliases) catch |err| {
        std.log.err("cannot package {s}: {t}", .{ entry.path, err });
        failed = true;
    };
    if (failed) return error.PackagingFailed;
    var file = try std.Io.Dir.cwd().createFile(io, args[3], .{});
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try aliases.write(&writer.interface);
    try writer.interface.flush();
}

fn packageFile(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, project: std.Io.Dir, project_dir: []const u8, output: std.Io.Dir, entry: assets.package.Entry, aliases: *assets.registry.Builder) !void {
    if (entry.kind == .folder) {
        try aliases.add(.{ .path = entry.path, .id = entry.id, .kind = .folder, .converted = false });
        return;
    }
    const conversion = assets.package.Conversion.of(entry.path);
    if (conversion == .copy) {
        try aliases.add(.{ .path = entry.path, .id = entry.id, .kind = entry.kind, .converted = false });
        var key: [assets.id.key_len]u8 = undefined;
        try project.copyFile(entry.path, output, assets.id.key(&key, entry.id), io, .{});
        return;
    }
    const full_path = try std.fs.path.joinZ(arena, &.{ project_dir, entry.path });
    switch (conversion) {
        .model => {
            var model = model_import.import(gpa, full_path, entry.model) catch |err| {
                std.log.err("{s}: {s}", .{ entry.path, model_import.lastError() });
                return err;
            };
            defer model.deinit(gpa);
            const children = try assets.subassets.list(arena, entry.id, entry.path, model.rig.clips);
            defer assets.subassets.free(arena, children);
            const geometry = children[0].id;
            for (children) |child| try aliases.claim(child.id);
            try aliases.add(.{ .path = entry.path, .id = geometry, .kind = .model, .converted = true });
            for (children) |child| {
                try aliases.add(.{ .path = child.path, .id = child.id, .kind = child.kind, .converted = child.kind == .model });
                if (child.clip_index) |index| {
                    try writePayload(io, output, child.id, assets.imported_clip, assets.imported_clip.File{
                        .source_model = geometry,
                        .clip = model.rig.clips[index],
                    });
                }
            }

            // Geometry keeps its rig and blend shapes; clips are independently addressable.
            const clips = model.rig.clips;
            model.rig.clips = &.{};
            defer model.rig.clips = clips;
            try writePayload(io, output, geometry, assets.model, model);
        },
        .texture => {
            try aliases.add(.{ .path = entry.path, .id = entry.id, .kind = .image, .converted = true });
            var texture = model_import.decodeImage(gpa, full_path) catch |err| {
                std.log.err("{s}: {s}", .{ entry.path, model_import.lastError() });
                return err;
            };
            defer texture.deinit(gpa);
            try writePayload(io, output, entry.id, assets.texture, texture);
        },
        .copy => unreachable,
    }
}

fn writePayload(io: std.Io, output: std.Io.Dir, identity: u64, comptime format: type, value: anytype) !void {
    var key: [assets.id.key_len]u8 = undefined;
    var file = try output.createFile(io, assets.id.key(&key, identity), .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try format.write(&writer.interface, value);
    try writer.interface.flush();
}
