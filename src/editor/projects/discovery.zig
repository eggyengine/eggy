//! Finding the developable project belonging to a launched editor.
const std = @import("std");
const project = @import("eggy").project;

/// An explicit project takes precedence over discovery. A missing value is an error.
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
pub fn find(gpa: std.mem.Allocator, io: std.Io, name: []const u8, executable_dir: []const u8, launch_dir: []const u8) !?[]u8 {
    if (try findAbove(gpa, io, name, executable_dir)) |dir| return dir;
    return findAbove(gpa, io, name, launch_dir);
}

fn findAbove(gpa: std.mem.Allocator, io: std.Io, name: []const u8, start: []const u8) !?[]u8 {
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, start, gpa);
    defer gpa.free(absolute);
    var candidate: []const u8 = absolute;
    while (true) {
        if (try matches(gpa, io, name, candidate)) return try gpa.dupe(u8, candidate);
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

test "an editor in zig-out/bin finds its matching developable project" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "foobar_game/zig-out/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "foobar_game/eggy.zon", .data = ".{ .name = \"foobar_game\", .title = \"Foobar\" }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "foobar_game/build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "foobar_game/build.zig.zon", .data = "" });
    const bin = try tmp.dir.realPathFileAlloc(io, "foobar_game/zig-out/bin", std.testing.allocator);
    defer std.testing.allocator.free(bin);
    const root = try tmp.dir.realPathFileAlloc(io, "foobar_game", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const launch = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(launch);
    const found = (try find(std.testing.allocator, io, "foobar_game", bin, launch)).?;
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings(root, found);
    try std.testing.expect(try find(std.testing.allocator, io, "other_game", bin, launch) == null);

    try tmp.dir.deleteFile(io, "foobar_game/build.zig");
    try std.testing.expect(try find(std.testing.allocator, io, "foobar_game", bin, launch) == null);
}

test "a build with an external prefix finds the project in its launch directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "install/bin");
    try tmp.dir.createDirPath(io, "game");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/eggy.zon", .data = ".{ .name = \"game\", .title = \"Game\" }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "game/build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "game/build.zig.zon", .data = "" });
    const bin = try tmp.dir.realPathFileAlloc(io, "install/bin", std.testing.allocator);
    defer std.testing.allocator.free(bin);
    const root = try tmp.dir.realPathFileAlloc(io, "game", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const found = (try find(std.testing.allocator, io, "game", bin, root)).?;
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings(root, found);
}

test "explicit project arguments are preserved and incomplete arguments are rejected" {
    try std.testing.expectEqualStrings("../another-project", (try explicitDirectory(&.{ "game_editor", "--project", "../another-project" })).?);
    try std.testing.expect(try explicitDirectory(&.{"game_editor"}) == null);
    try std.testing.expectError(error.MissingProjectDirectory, explicitDirectory(&.{ "game_editor", "--project" }));
    try std.testing.expectError(error.MissingProjectDirectory, explicitDirectory(&.{ "game_editor", "--project", "" }));
}
