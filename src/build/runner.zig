//! Running this build's maker directly, past `zig build`. `zig build` starts the maker (Zig 0.17's
//! build runner) without the progress pipe it was given (`ZIG_PROGRESS`), so whatever started it
//! sees no steps; started directly, the maker reports every one. The export's nested build runs
//! it that way (so its steps show under the export), and so does the editor, which asks for the
//! command line through `EGGY_RUNNER_FILE` (see `record`).
const std = @import("std");
const builtin = @import("builtin");

/// The environment variable naming a file `record` writes the maker's command line into.
pub const file_variable = "EGGY_RUNNER_FILE";

/// The command line that starts this build's maker, less the steps and options to run: the maker,
/// `build`, then the paths it is always given. Null where it can't be found, so callers run
/// `zig build` instead. Arguments are in `b`'s arena, not shell-quoted text.
/// ponytail: Linux only, read from the maker's /proc entry (build.zig runs in the configurer it
/// starts); find the maker some other way if macOS builds want their steps shown.
///
/// ```zig
/// const nested = b.addSystemCommand(runner.argv(b) orelse &.{ b.graph.zig_exe, "build" });
/// nested.addArgs(&.{ "runtime", "-Doptimize=fast" });
/// ```
pub fn argv(b: *std.Build) ?[]const []const u8 {
    if (builtin.os.tag != .linux) return null;
    // Streamed: /proc reports a size of 0, which `readFileAlloc` would trust.
    const path = b.fmt("/proc/{d}/cmdline", .{std.os.linux.getppid()});
    const file = std.Io.Dir.cwd().openFile(b.graph.io, path, .{}) catch return null;
    defer file.close(b.graph.io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(b.graph.io, &buffer);
    const cmdline = reader.interface.allocRemaining(b.allocator, .limited(64 * 1024)) catch return null;
    // `maker build --zig-lib=… --zig=… --global-cache=… --seed=…`, then this build's own arguments.
    var parts = std.mem.splitScalar(u8, cmdline, 0);
    var args: [6][]const u8 = undefined;
    for (&args) |*arg| arg.* = parts.next() orelse return null;
    if (!std.mem.eql(u8, args[1], "build") or !std.mem.startsWith(u8, args[5], "--seed=")) return null;
    return b.allocator.dupe([]const u8, &args) catch @panic("OOM");
}

/// When `EGGY_RUNNER_FILE` is set, write `argv(b)` into that file, an argument a line (nothing
/// where `argv` can't say). Build-internal; unset means no side effects. Overwrites the named
/// file; write failures are warned, not propagated or treated as success.
///
/// ```zig
/// // During build-graph setup, to cooperate with an editor-launched build:
/// runner.record(b);
/// ```
pub fn record(b: *std.Build) void {
    const path = b.graph.environ_map.get(file_variable) orelse return;
    var text: std.ArrayList(u8) = .empty;
    for (argv(b) orelse return) |arg| text.print(b.allocator, "{s}\n", .{arg}) catch @panic("OOM");
    std.Io.Dir.cwd().writeFile(b.graph.io, .{ .sub_path = path, .data = text.items }) catch |err| std.log.warn("cannot write {s}: {t}", .{ path, err });
}
