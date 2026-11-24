//! Finding the developable project belonging to a launched editor.
const std = @import("std");
const project = @import("eggy").project;

/// An explicit project takes precedence over discovery. A missing value is an error.
/// Editor startup helper: scan sentinel-terminated process arguments, including argv[0].
/// Returns a borrowed, unnormalized directory after the first `--project`, null if absent,
/// or MissingProjectDirectory for a missing/empty value. Does not check disk.
///
/// ```zig
/// const dir = try explicitDirectory(&.{ "game_editor", "--project", "../game" });
/// ```
pub fn explicitDirectory(args: []const [*:0]const u8) !?[]const u8 {
    for (args, 0..) |arg, i| {
        if (!std.mem.eql(u8, std.mem.span(arg), "--project")) continue;
        if (i + 1 == args.len or std.mem.span(args[i + 1]).len == 0) return error.MissingProjectDirectory;
        return std.mem.span(args[i + 1]);
    }
    return null;
}

/// Find the nearest ancestor with a matching `eggy.zon` and both Zig build files. Prefer the
/// executable's ancestors, then the launch directory's (for builds using an external prefix).
/// The absolute directory is caller-owned; malformed or unreadable projects report an error.
/// Editor startup only: `name` must match the project's package name; both start directories
/// must exist. Null means neither ancestor chain matches; free a successful sentinel-terminated
/// result with `gpa`. Resolution, read/parse and allocation errors propagate.
///
/// ```zig
/// // Given allocator, I/O and existing editor/launch directory paths:
/// if (try find(gpa, io, "space_game", executable_dir, launch_dir)) |dir| {
///     defer gpa.free(dir);
///     std.log.info("Project: {s}", .{dir});
/// }
/// ```
pub fn find(gpa: std.mem.Allocator, io: std.Io, name: []const u8, executable_dir: []const u8, launch_dir: []const u8) !?[:0]u8 {
    if (try findAbove(gpa, io, name, executable_dir)) |dir| return dir;
    return findAbove(gpa, io, name, launch_dir);
}

fn findAbove(gpa: std.mem.Allocator, io: std.Io, name: []const u8, start: []const u8) !?[:0]u8 {
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, start, gpa);
    defer gpa.free(absolute);
    var candidate: []const u8 = absolute;
    while (true) {
        if (try matches(gpa, io, name, candidate)) return try gpa.dupeSentinel(u8, candidate, 0);
        const parent = std.fs.path.dirname(candidate) orelse return null;
        if (std.mem.eql(u8, parent, candidate)) return null;
        candidate = parent;
    }
}

fn matches(gpa: std.mem.Allocator, io: std.Io, name: []const u8, path: []const u8) !bool {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const config = project.load(arena.allocator(), io, dir) catch |err| return switch (err) {
        error.FileNotFound => false,
        else => err,
    };
    if (!std.mem.eql(u8, name, config.name)) return false;
    for ([_][]const u8{ "build.zig", "build.zig.zon" }) |file| {
        const stat = dir.statFile(io, file, .{}) catch |err| return switch (err) {
            error.FileNotFound => false,
            else => err,
        };
        if (stat.kind != .file) return false;
    }
    return true;
}
