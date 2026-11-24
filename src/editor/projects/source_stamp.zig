//! A cheap stamp of a project's sources (their newest change and how many files there are),
//! to tell whether rebuilding its editor could change anything.
const std = @import("std");

/// Folders of build output, caches and history, which the editor's build doesn't read. `.eggy`
/// (preferences) only goes into the runtime, which its own build picks up.
const ignored = [_][]const u8{ ".zig-cache", "zig-out", "zig-pkg", ".git", "node_modules", ".eggy" };

pub const Stamp = struct {
    newest_ns: i96 = 0,
    files: usize = 0,

    /// Compare editor rebuild stamps by newest nanosecond mtime and file count, not contents.
    /// Equal stamps can miss edits preserving both values; this is a cheap change heuristic.
    ///
    /// ```zig
    /// const unchanged = before.eql(after); // Two previously taken Stamp values.
    /// ```
    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.newest_ns == b.newest_ns and a.files == b.files;
    }

    fn add(self: *Stamp, stat: std.Io.File.Stat) void {
        self.newest_ns = @max(self.newest_ns, stat.mtime.nanoseconds);
        self.files += 1;
    }
};

/// The stamp of every file at or under `paths` (absolute files and folders), less the `ignored`
/// folders. Unreadable and missing files and folders are skipped.
/// ponytail: walks the folders on each call; switch to OS file watching if projects grow large enough for it to lag.
/// Editor-only: `gpa` backs temporary walkers; returned counters own no memory. I/O/allocation
/// failures skip directories or end traversal, so an incomplete stamp is possible.
///
/// ```zig
/// const stamp = take(gpa, io, &.{project_dir}); // Existing allocator/I/O and absolute path.
/// ```
pub fn take(gpa: std.mem.Allocator, io: std.Io, paths: []const []const u8) Stamp {
    var stamp = Stamp{};
    for (paths) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
            if (err == error.NotDir) if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| stamp.add(stat) else |_| {};
            continue;
        };
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
                stamp.add(entry.dir.statFile(io, entry.basename, .{}) catch continue);
            },
            else => {},
        };
    }
    return stamp;
}
