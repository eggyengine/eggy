//! A cheap stamp of a project's sources (their newest change and how many files there are),
//! to tell whether rebuilding its editor could change anything.
const std = @import("std");

/// Folders of build output, caches and history, which the editor's build doesn't read. `.eggy`
/// (preferences) only goes into the runtime, which its own build picks up.
const ignored = [_][]const u8{ ".zig-cache", "zig-out", "zig-pkg", ".git", "node_modules", ".eggy" };

pub const Stamp = struct {
    newest_ns: i96 = 0,
    files: usize = 0,

    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.newest_ns == b.newest_ns and a.files == b.files;
    }
};

/// The stamp of every file under `dirs` (absolute), less the `ignored` folders. Unreadable files
/// and folders are skipped.
// ponytail: walks the folders on each call; switch to OS file watching if projects grow large enough for it to lag.
pub fn take(gpa: std.mem.Allocator, io: std.Io, dirs: []const []const u8) Stamp {
    var stamp = Stamp{};
    for (dirs) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = dir.walkSelectively(gpa) catch continue;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| switch (entry.kind) {
            .directory => {
                for (ignored) |name| {
                    if (std.mem.eql(u8, entry.basename, name)) break;
                } else walker.enter(io, entry) catch {};
            },
            .file => {
                const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
                stamp.newest_ns = @max(stamp.newest_ns, stat.mtime.nanoseconds);
                stamp.files += 1;
            },
            else => {},
        };
    }
    return stamp;
}

test "a stamp changes when a source file is added, and ignores build output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.createDirPath(io, "zig-out/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/bin/game", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const before = take(std.testing.allocator, io, &.{path});
    try std.testing.expectEqual(@as(usize, 1), before.files);
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/bin/game_editor", .data = "" });
    try std.testing.expect(before.eql(take(std.testing.allocator, io, &.{path})));
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try std.testing.expect(!before.eql(take(std.testing.allocator, io, &.{path})));
}
