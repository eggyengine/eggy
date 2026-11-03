//! The editor's environment for the processes it starts, with the login shell's PATH when it was
//! opened from the desktop and so missed the shell profile that puts `zig` on PATH.
const std = @import("std");
const builtin = @import("builtin");

/// The process environment as it stands now, for `std.Io.Threaded`'s `.environ`, so children
/// see what `adoptShellPath` set.
pub fn current() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => .{ .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) } },
    };
}

/// When `zig` isn't on PATH, take PATH from the user's login shell (`$SHELL -ilc`), as zvm and
/// similar installers only add theirs in a shell profile, which a desktop launch never reads.
/// Call at startup, before other threads read the environment. Does nothing on Windows, whose
/// apps get PATH from the registry; a shell that fails or finds no `zig` leaves PATH as it was.
pub fn adoptShellPath(gpa: std.mem.Allocator) void {
    if (builtin.os.tag == .windows) return;
    const path = std.c.getenv("PATH");
    if (path != null and onPath(std.mem.span(path.?), "zig")) return;

    const shell_path = shellPath(gpa) catch |err| {
        std.log.warn("zig is not on PATH, and asking the login shell failed: {s}", .{@errorName(err)});
        return;
    } orelse return;
    defer gpa.free(shell_path);
    if (!onPath(shell_path, "zig")) return;
    if (setenv("PATH", shell_path, 1) != 0) return;
    std.log.info("zig found on the login shell's PATH", .{});
}

/// PATH as an interactive login shell sets it, or null if the shell didn't print one.
/// Caller-owned.
fn shellPath(gpa: std.mem.Allocator) !?[:0]u8 {
    const shell = if (std.c.getenv("SHELL")) |value| std.mem.span(value) else "/bin/sh";
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = current() });
    defer threaded.deinit();
    // Interactive too: zvm writes its PATH line into .zshrc/.bashrc. A marker sets PATH apart
    // from whatever the profile prints; `run` gives no stdin, so nothing it runs can wait on input.
    const result = try std.process.run(gpa, threaded.io(), .{
        .argv = &.{ shell, "-ilc", "printf '\\n" ++ marker ++ "%s\\n' \"$PATH\"" },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const line = markedLine(result.stdout) orelse return null;
    return try gpa.dupeSentinel(u8, line, 0);
}

const marker = "__EGGY_PATH__=";

/// The text after `marker` on its line in a shell's output.
fn markedLine(output: []const u8) ?[]const u8 {
    const start = (std.mem.lastIndexOf(u8, output, marker) orelse return null) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, output, start, '\n') orelse output.len;
    const line = std.mem.trimEnd(u8, output[start..end], "\r");
    return if (line.len == 0) null else line;
}

/// Whether a PATH-style list has an executable named `name` in one of its folders.
fn onPath(path: []const u8, name: []const u8) bool {
    var folders = std.mem.tokenizeScalar(u8, path, ':');
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    while (folders.next()) |folder| {
        const file = std.fmt.bufPrintSentinel(&buffer, "{s}/{s}", .{ folder, name }, 0) catch continue;
        if (std.c.access(file, std.c.X_OK) == 0) return true;
    }
    return false;
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

test "the shell's PATH is read past what its profile prints" {
    try std.testing.expectEqualStrings("/a:/b", markedLine("welcome!\n" ++ marker ++ "/a:/b\n").?);
    try std.testing.expectEqualStrings("/a", markedLine(marker ++ "/a\r\nbye\n").?);
    try std.testing.expect(markedLine("no marker\n") == null);
    try std.testing.expect(markedLine(marker ++ "\n") == null);
}

test "an executable is found only in a folder on the PATH" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(onPath("/nonexistent:/bin", "sh"));
    try std.testing.expect(!onPath("/nonexistent", "sh"));
}
