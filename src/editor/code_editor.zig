//! Opening a project's code in the code editor people chose (Edit > Preferences, Code editor):
//! the file, with the project's folder so the editor knows the workspace.
const std = @import("std");
const file_manager = @import("file_manager.zig");

/// The code editors Eggy knows how to start, or the system's default app for the file.
pub const Choice = enum { vscode, vscodium, cursor, zed, sublime_text, system };

/// Open `file` (absolute) of the project in `project_dir` with `choice`. Returns once the editor
/// is started, not once it shows; fails when it isn't installed (not on the PATH).
// ponytail: starts the command by name, so on Windows `code.cmd` and friends need a shell; go through `cmd /c` there if Windows users miss it.
pub fn open(gpa: std.mem.Allocator, choice: Choice, project_dir: []const u8, file: []const u8) !void {
    const program = command(choice) orelse return file_manager.openFile(gpa, file);
    var threaded: std.Io.Threaded = .init_single_threaded;
    _ = try std.process.spawn(threaded.io(), .{
        .argv = &.{ program, project_dir, file },
        .cwd = .{ .path = project_dir },
        .stdin = .ignore,
    });
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
