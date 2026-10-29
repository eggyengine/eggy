//! Opening a project's code in the code editor people chose (Edit > Preferences, Code editor):
//! the file and optional source position, with the project's folder as the workspace.
const builtin = @import("builtin");
const std = @import("std");
const file_manager = @import("file_manager.zig");

/// The code editors Eggy knows how to start, or the system's default app for the file.
pub const Choice = enum { vscode, vscodium, cursor, zed, sublime_text, system };

const Position = struct { line: u32, column: u32 };

/// Open `file` (absolute) of the project in `project_dir` with `choice`. Returns once the editor
/// is started, not once it shows; fails when it isn't installed (not on the PATH).
/// Paths are borrowed only for this call; temporary arguments use `gpa` and are freed.
/// This editor-host helper launches an external process, not a game hook.
/// ponytail: starts the command by name, so on Windows `code.cmd` and friends need a shell; go through `cmd /c` there if Windows users miss it.
///
/// ```zig
/// try code_editor.open(gpa, .vscode, "/home/me/game", "/home/me/game/src/main.zig");
/// ```
pub fn open(gpa: std.mem.Allocator, choice: Choice, project_dir: []const u8, file: []const u8) !void {
    try openPosition(gpa, choice, project_dir, file, null);
}

/// Open the project in `project_dir` (absolute) as a workspace in `choice`; the system's default
/// shows the folder in the file manager instead. Fails when the editor isn't on the PATH.
///
/// ```zig
/// try code_editor.openFolder(gpa, .vscode, "/home/me/game");
/// ```
pub fn openFolder(gpa: std.mem.Allocator, choice: Choice, project_dir: []const u8) !void {
    if (choice == .system) return file_manager.showFolder(gpa, project_dir);
    const program = command(choice) orelse return error.NoCodeEditorCommand;
    try start(gpa, project_dir, &.{ program, project_dir });
}

/// Open the one-based source position. The system default opens the file without positioning.
/// `project_dir` is the workspace/cwd and `file` is absolute; both are borrowed.
/// Zero line/column returns `InvalidSourcePosition`; allocation/launch failures propagate.
///
/// ```zig
/// try code_editor.openAt(gpa, .vscode, "/home/me/game", "/home/me/game/src/main.zig", 12, 5);
/// ```
pub fn openAt(gpa: std.mem.Allocator, choice: Choice, project_dir: []const u8, file: []const u8, line: u32, column: u32) !void {
    if (line == 0 or column == 0) return error.InvalidSourcePosition;
    try openPosition(gpa, choice, project_dir, file, .{ .line = line, .column = column });
}

fn openPosition(gpa: std.mem.Allocator, choice: Choice, project_dir: []const u8, file: []const u8, position: ?Position) !void {
    if (choice == .system) return file_manager.openFile(gpa, file);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try start(gpa, project_dir, try arguments(arena.allocator(), choice, project_dir, file, position));
}

fn arguments(arena: std.mem.Allocator, choice: Choice, project_dir: []const u8, file: []const u8, position: ?Position) ![]const []const u8 {
    const program = command(choice) orelse return error.NoCodeEditorCommand;
    const target = if (position) |at| try std.fmt.allocPrint(arena, "{s}:{d}:{d}", .{ file, at.line, at.column }) else file;
    const goto = position != null and switch (choice) {
        .vscode, .vscodium, .cursor => true,
        else => false,
    };
    const argv = try arena.alloc([]const u8, if (goto) 4 else 3);
    argv[0] = program;
    argv[1] = project_dir;
    if (goto) argv[2] = "--goto";
    argv[argv.len - 1] = target;
    return argv;
}

/// Start the code editor from the project's folder, inheriting the editor's environment.
fn start(gpa: std.mem.Allocator, project_dir: []const u8, argv: []const []const u8) !void {
    // The editor's own environment, so the command is looked up on its PATH.
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = processEnviron() });
    defer threaded.deinit();
    // ponytail: the child isn't waited for, so a launcher that exits (`code` does) lingers as a zombie until the editor quits; reap it if that ever piles up.
    _ = try std.process.spawn(threaded.io(), .{
        .argv = argv,
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
    try start(std.testing.allocator, "/", &.{ "true", "/", "/" });
}

test "source links use each editor's line and column arguments without splitting paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]Choice{ .vscode, .vscodium, .cursor, .zed, .sublime_text }) |choice| {
        const argv = try arguments(arena.allocator(), choice, "/my game", "/my game/src/root.zig", .{ .line = 69, .column = 9 });
        try std.testing.expectEqualStrings("/my game", argv[1]);
        try std.testing.expectEqualStrings("/my game/src/root.zig:69:9", argv[argv.len - 1]);
        if (choice == .vscode or choice == .vscodium or choice == .cursor) try std.testing.expectEqualStrings("--goto", argv[2]);
    }
    const ordinary = try arguments(arena.allocator(), .vscode, "/game", "/game/src/root.zig", null);
    try std.testing.expectEqual(@as(usize, 3), ordinary.len);
    try std.testing.expectEqualStrings("/game/src/root.zig", ordinary[2]);
}
