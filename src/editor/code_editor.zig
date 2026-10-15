//! Opening a project's code in the code editor people chose (Edit > Preferences, Code editor):
//! the file, with the project's folder so the editor knows the workspace.
const builtin = @import("builtin");
const std = @import("std");
const file_manager = @import("file_manager.zig");

/// The code editors Eggy knows how to start, or the system's default app for the file.
pub const Choice = enum { vscode, vscodium, cursor, zed, sublime_text, system };

/// Open `file` (absolute) of the project in `project_dir` with `choice`. Returns once the editor
/// is started, not once it shows; fails when it isn't installed (not on the PATH).
// ponytail: starts the command by name, so on Windows `code.cmd` and friends need a shell; go through `cmd /c` there if Windows users miss it.
pub fn open(gpa: std.mem.Allocator, choice: Choice, project_dir: []const u8, file: []const u8) !void {
    const program = command(choice) orelse return file_manager.openFile(gpa, file);
    try start(gpa, program, project_dir, file);
}

/// Start `program` with the project's folder and `file`, from the project's folder.
fn start(gpa: std.mem.Allocator, program: []const u8, project_dir: []const u8, file: []const u8) !void {
    // The editor's own environment, so the command is looked up on its PATH.
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = processEnviron() });
    defer threaded.deinit();
    // ponytail: the child isn't waited for, so a launcher that exits (`code` does) lingers as a zombie until the editor quits; reap it if that ever piles up.
    _ = try std.process.spawn(threaded.io(), .{
        .argv = &.{ program, project_dir, file },
        .cwd = .{ .path = project_dir },
        .stdin = .ignore,
    });
}

fn processEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => .{ .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) } },
    };
}

/// The command that starts `choice`; null for the system's default app.
fn command(choice: Choice) ?[]const u8 {
    return switch (choice) {
        .vscode => "code",
        .vscodium => "codium",
        .cursor => "cursor",
        .zed => "zed",
        .sublime_text => "subl",
        .system => null,
    };
}

test "each code editor has its command, and the system's default has none" {
    try std.testing.expectEqualStrings("code", command(.vscode).?);
    try std.testing.expect(command(.system) == null);
}

test "a command on the PATH starts, given the folder and the file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try start(std.testing.allocator, "true", "/", "/");
}
