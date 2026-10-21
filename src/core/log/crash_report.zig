//! The file a fatal error or panic leaves beside the run's log: what failed and during what, its
//! trace with source locations, and the end of the log, so a crash can be read after the fact.
const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");

/// Where the failure's trace comes from.
pub const Trace = union(enum) {
    /// An error's return trace, from `@errorReturnTrace()` where it was caught.
    error_return: *const std.builtin.StackTrace,
    /// The stack where the report is written, from this return address on (a panic's).
    current: ?usize,
    none,
};

/// How much of the log's end the report quotes.
const log_tail_bytes = 16 * 1024;

/// Write a crash report for a failure during `stage` (such as "frame"), described by `message`,
/// next to the run's log as `<log name>-crash.txt`. Returns its path in `path_buffer`, or null
/// without a log file or if the report can't be written: reporting a crash never fails the
/// handling of it.
pub fn write(io: std.Io, stage: []const u8, message: []const u8, trace: Trace, path_buffer: []u8) ?[]const u8 {
    const log_path = log.filePath() orelse return null;
    const path = std.fmt.bufPrint(path_buffer, "{s}-crash.txt", .{log_path[0 .. log_path.len - ".log".len]}) catch return null;
    const report = std.Io.Dir.cwd().createFile(io, path, .{}) catch return null;
    defer report.close(io);
    var buffer: [1024]u8 = undefined;
    var file_writer = report.writerStreaming(io, &buffer);
    writeReport(io, &file_writer.interface, stage, message, trace) catch return null;
    return path;
}

fn writeReport(io: std.Io, writer: *std.Io.Writer, stage: []const u8, message: []const u8, trace: Trace) !void {
    try writer.print("Fatal error during {s}: {s}\n", .{ stage, message });
    try writer.print("{t} {t}-{t}, Zig {s}, {t} build\n\n", .{ builtin.cpu.arch, builtin.os.tag, builtin.abi, builtin.zig_version_string, builtin.mode });

    // Where it happened, with each frame's source when it can be found.
    const terminal: std.Io.Terminal = .{ .writer = writer, .mode = .no_color };
    switch (trace) {
        .error_return => |error_trace| {
            try writer.writeAll("Error return trace:\n");
            try std.debug.writeErrorReturnTrace(error_trace, terminal);
        },
        .current => |first_address| {
            try writer.writeAll("Stack trace:\n");
            try std.debug.writeCurrentStackTrace(.{ .first_address = first_address }, terminal);
        },
        .none => try writer.writeAll("No trace (built without error return traces).\n"),
    }

    // What led up to it.
    var tail_buffer: [log_tail_bytes]u8 = undefined;
    try writer.print("\nThe end of the log ({s}):\n{s}", .{ log.filePath() orelse "none", log.readTail(io, &tail_buffer) });
    try writer.flush();
}

test "a report names the failure and quotes no log without one" {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeReport(std.testing.io, &writer, "frame", "OutOfMemory", .none);
    const report = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, report, "Fatal error during frame: OutOfMemory\n"));
    try std.testing.expect(std.mem.indexOf(u8, report, "The end of the log (none):") != null);
}
