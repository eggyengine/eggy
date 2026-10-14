//! Build tool: `tar <output> [<archive path> <file>]...` writes the files into an uncompressed
//! tarball at `output`, each under its archive path. Timestamps are zero so the output only
//! changes when the files do.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const output_path = args.next() orelse return error.MissingOutputPath;

    var output = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer output.close(io);
    var output_buffer: [64 * 1024]u8 = undefined;
    var output_writer = output.writer(io, &output_buffer);
    var tar: std.tar.Writer = .{ .underlying_writer = &output_writer.interface };

    // Each remaining pair of arguments is one file: where it goes in the archive, then where it is.
    while (args.next()) |archive_path| {
        const file_path = args.next() orelse return error.MissingFilePath;
        var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
        defer file.close(io);
        var file_buffer: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &file_buffer);
        try tar.writeFile(archive_path, &file_reader, 0);
    }

    try tar.finishPedantically();
    try output_writer.interface.flush();
}
