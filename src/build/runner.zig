//! Running this build's runner directly, past `zig build`. `zig build` compiles the runner and
//! starts it without the progress pipe it was given (`ZIG_PROGRESS`), so whatever started it
//! sees only "Compile Build Script"; started directly, the runner reports every step. The
//! export's nested build runs it that way (so its steps show under the export), and so does the
//! editor, which asks for the command line through `EGGY_RUNNER_FILE` (see `record`).
const std = @import("std");

/// The environment variable naming a file `record` writes the runner's command line into.
pub const file_variable = "EGGY_RUNNER_FILE";

/// The command line that starts this build's runner for `b` (the project's own builder), less
/// the steps and options to run: the runner, then the paths it is always given.
pub fn argv(b: *std.Build) []const []const u8 {
    const self_exe = std.process.executablePathAlloc(b.graph.io, b.allocator) catch |err| std.debug.panic("cannot find the build runner: {t}", .{err});
    return b.allocator.dupe([]const u8, &.{
        self_exe,
        b.graph.zig_exe,
        absolute(b, b.graph.zig_lib_directory),
        absolute(b, b.build_root),
        absolute(b, b.cache_root),
        absolute(b, b.graph.global_cache_root),
        "--seed",
        "0",
    }) catch @panic("OOM");
}

/// When `EGGY_RUNNER_FILE` is set, write `argv(b)` into that file, an argument a line.
pub fn record(b: *std.Build) void {
    const path = b.graph.environ_map.get(file_variable) orelse return;
    var text: std.ArrayList(u8) = .empty;
    for (argv(b)) |arg| text.print(b.allocator, "{s}\n", .{arg}) catch @panic("OOM");
    std.Io.Dir.cwd().writeFile(b.graph.io, .{ .sub_path = path, .data = text.items }) catch |err| std.log.warn("cannot write {s}: {t}", .{ path, err });
}

fn absolute(b: *std.Build, directory: std.Build.Cache.Directory) []const u8 {
    const path = directory.path orelse ".";
    if (std.fs.path.isAbsolute(path)) return path;
    return directory.handle.realPathFileAlloc(b.graph.io, ".", b.allocator) catch path;
}
