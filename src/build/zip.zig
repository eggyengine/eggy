//! Build tool: `zip <output> <folder> <root>` writes every file under `folder` into a zip archive
//! at `output`, under `<root>/`, deflated. Executable files stay executable when unzipped on
//! Linux and macOS. Timestamps are fixed, so the archive only changes when the files do.
const std = @import("std");
const zip = std.zip;
const flate = std.compress.flate;

/// 1980-01-01 00:00, the earliest time a zip records.
const dos_date: u16 = (0 << 9) | (1 << 5) | 1;
/// Made by Unix (so file modes are kept), zip version 2.0.
const made_by: u16 = (3 << 8) | 20;

/// Build-tool entry point: archive regular files below a folder, under the supplied root name.
/// Creates/overwrites output, sorts paths and fixes timestamps for reproducibility, preserving
/// executable permissions. Requires exactly three arguments; allocation, traversal and write
/// errors propagate and may leave a partial archive. Inputs come from the trusted export graph.
///
/// ```sh
/// eggy_zip my_game.zip ./zig-out/export/my_game my_game
/// ```
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.Usage;
    var folder = try std.Io.Dir.cwd().openDir(io, args[2], .{ .iterate = true });
    defer folder.close(io);

    // Every file, sorted, so the same folder always zips the same way.
    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try folder.walk(init.arena.allocator());
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.mem.replaceOwned(u8, init.arena.allocator(), entry.path, std.fs.path.sep_str, "/");
        try paths.append(init.arena.allocator(), path);
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn before(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.before);

    var output = try std.Io.Dir.cwd().createFile(io, args[1], .{});
    defer output.close(io);
    var output_buffer: [64 * 1024]u8 = undefined;
    var writer = output.writer(io, &output_buffer);
    const out = &writer.interface;

    // Each file's local header and deflated contents, then the directory of them all.
    var central: std.Io.Writer.Allocating = .init(gpa);
    defer central.deinit();
    var offset: u64 = 0;
    for (paths.items) |path| {
        const name = try std.fmt.allocPrint(init.arena.allocator(), "{s}/{s}", .{ args[3], path });
        const contents = try folder.readFileAlloc(io, path, gpa, .limited(1 << 32));
        defer gpa.free(contents);
        const stat = try folder.statFile(io, path, .{});
        const executable = isExecutable(stat.permissions, path);
        const deflated = try deflate(gpa, contents);
        defer gpa.free(deflated);
        const crc = std.hash.Crc32.hash(contents);

        const local = zip.LocalFileHeader{
            .signature = zip.local_file_header_sig,
            .version_needed_to_extract = 20,
            .flags = @bitCast(@as(u16, 0)),
            .compression_method = .deflate,
            .last_modification_time = 0,
            .last_modification_date = dos_date,
            .crc32 = crc,
            .compressed_size = @intCast(deflated.len),
            .uncompressed_size = @intCast(contents.len),
            .filename_len = @intCast(name.len),
            .extra_len = 0,
        };
        try out.writeStruct(local, .little);
        try out.writeAll(name);
        try out.writeAll(deflated);

        const entry = zip.CentralDirectoryFileHeader{
            .signature = zip.central_file_header_sig,
            .version_made_by = made_by,
            .version_needed_to_extract = 20,
            .flags = @bitCast(@as(u16, 0)),
            .compression_method = .deflate,
            .last_modification_time = 0,
            .last_modification_date = dos_date,
            .crc32 = crc,
            .compressed_size = @intCast(deflated.len),
            .uncompressed_size = @intCast(contents.len),
            .filename_len = @intCast(name.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = @as(u32, if (executable) 0o100755 else 0o100644) << 16,
            .local_file_header_offset = @intCast(offset),
        };
        try central.writer.writeStruct(entry, .little);
        try central.writer.writeAll(name);
        offset += @sizeOf(zip.LocalFileHeader) + name.len + deflated.len;
    }
    try out.writeAll(central.written());
    try out.writeStruct(zip.EndRecord{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(paths.items.len),
        .record_count_total = @intCast(paths.items.len),
        .central_directory_size = @intCast(central.written().len),
        .central_directory_offset = @intCast(offset),
        .comment_len = 0,
    }, .little);
    try out.flush();
}

/// Whether a file with `permissions` at `path` runs: by its mode, or where the system building
/// has none (Windows), by being in `bin/`.
fn isExecutable(permissions: std.Io.File.Permissions, path: []const u8) bool {
    const Permissions = std.Io.File.Permissions;
    if (@hasDecl(Permissions, "has_executable_bit") and Permissions.has_executable_bit and @hasDecl(Permissions, "toMode")) return permissions.toMode() & 0o111 != 0;
    return std.mem.startsWith(u8, path, "bin/");
}

/// `contents` deflated (raw, as zip stores it), caller-owned.
fn deflate(gpa: std.mem.Allocator, contents: []const u8) ![]u8 {
    var result: std.Io.Writer.Allocating = .init(gpa);
    errdefer result.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var compress = try flate.Compress.init(&result.writer, window, .raw, .default);
    try compress.writer.writeAll(contents);
    try compress.finish();
    return result.toOwnedSlice();
}
