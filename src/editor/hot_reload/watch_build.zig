//! A `zig build game-library --watch -fincremental` kept running beside an open project, which
//! rebuilds the game's library moments after its code is saved.
const std = @import("std");
const builtin = @import("builtin");
const build_output = @import("../projects/build_output.zig");
const export_process = @import("../projects/export_process.zig");
const process_environ = @import("../process_environ.zig");
const log = std.log.scoped(.hot_reload);

/// Where Zig's incremental compilation can rebuild the library: its own backend, which it picks for
/// Debug on x86_64 Linux. Elsewhere the editor rebuilds when it comes back into focus.
// ponytail: Linux x86_64 Debug only; widen as Zig's self-hosted backends reach other targets.
pub const supported = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64 and builtin.mode == .debug;

/// What happened since `poll` was last called.
pub const Event = enum {
    none,
    /// A build finished and installed the library.
    built,
    /// A build failed; its errors went to the Console.
    failed,
    /// Zig stopped watching (its errors, if any, went to the Console).
    ended,
};

pub const WatchBuild = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    project_dir: []u8,
    process: export_process.Process,
    reader: std.Io.Future(void),
    /// Builds finished and failed, and whether Zig stopped, as the reader thread saw them.
    built: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(u32) = .init(0),
    stopped: std.atomic.Value(bool) = .init(false),
    /// `built` and `failed` as `poll` last saw them.
    seen_built: u32 = 0,
    seen_failed: u32 = 0,

    /// Start watching the project at absolute `project_dir`, building into its `zig-out` with
    /// `cache_dir` as the Zig cache when given (the one the editor's other builds share).
    /// The first build compiles the library from scratch; later ones only what changed.
    /// Spawn failures propagate; a missing `zig` says so in the Console, and `poll` then ends.
    ///
    /// ```zig
    /// const watch = try WatchBuild.start(gpa, project_dir, cache_dir);
    /// defer watch.deinit();
    /// ```
    pub fn start(gpa: std.mem.Allocator, project_dir: []const u8, cache_dir: ?[]const u8) !*WatchBuild {
        const self = try gpa.create(WatchBuild);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .threaded = .init(gpa, .{ .environ = process_environ.current() }), .project_dir = try gpa.dupe(u8, project_dir), .process = undefined, .reader = undefined };
        errdefer gpa.free(self.project_dir);
        errdefer self.threaded.deinit();
        const io = self.threaded.io();

        // A shell leads the process group and ends all of it, compilers included, once Zig stops
        // or the editor does: its stdin is a pipe from the editor, which closes even on a crash.
        // Debounced, so the several writes of one save make one build.
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "/bin/sh", "-c", "exec 3<&0; \"$@\" </dev/null 3<&- & zig=$!; (read _ <&3; kill 0) & wait $zig; kill 0", "sh" });
        try argv.appendSlice(gpa, &.{ "zig", "build", "game-library", "--watch", "-fincremental", "--debounce", "50", "--summary", "line", "--color", "off" });
        if (cache_dir) |dir| try argv.appendSlice(gpa, &.{ "--cache-dir", dir });
        self.process = try export_process.Process.spawn(io, .{
            .argv = argv.items,
            .cwd = .{ .path = self.project_dir },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .pipe,
        });
        errdefer self.process.stop(io);
        self.reader = try io.concurrent(follow, .{self});
        return self;
    }

    /// Stop Zig and every compiler it keeps running, and free the watch.
    pub fn deinit(self: *WatchBuild) void {
        const io = self.threaded.io();
        // Killing the tree closes the pipe, which ends the reader.
        self.process.terminate();
        self.reader.await(io);
        self.process.stop(io);
        self.threaded.deinit();
        self.gpa.free(self.project_dir);
        self.gpa.destroy(self);
    }

    /// What happened since the last call, the latest first when several did. Main thread only.
    pub fn poll(self: *WatchBuild) Event {
        const built = self.built.load(.acquire);
        const failed = self.failed.load(.acquire);
        defer {
            self.seen_built = built;
            self.seen_failed = failed;
        }
        if (built != self.seen_built) return .built;
        if (failed != self.seen_failed) return .failed;
        if (self.stopped.load(.acquire)) return .ended;
        return .none;
    }

    /// Read Zig's output until it ends: diagnostics go to the Console, and each build's summary
    /// line counts the build.
    fn follow(self: *WatchBuild) void {
        defer self.stopped.store(true, .release);
        self.followOutput() catch |err| log.err("cannot follow the save rebuild: {t}", .{err});
    }

    fn followOutput(self: *WatchBuild) !void {
        var diagnostics = build_output.Stream{ .gpa = self.gpa, .project_dir = self.project_dir };
        defer diagnostics.deinit();
        var buffer: [4096]u8 = undefined;
        var reader = self.process.child.stderr.?.readerStreaming(self.threaded.io(), &buffer);
        var continuation = false;
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => if (reader.interface.bufferedLen() > 0) try reader.interface.take(reader.interface.bufferedLen()) else break,
                error.StreamTooLong => try reader.interface.take(reader.interface.bufferedLen()),
                else => return reader.err orelse err,
            };
            if (continuation) try diagnostics.continueLine(line) else try diagnostics.line(line);
            continuation = !std.mem.endsWith(u8, line, "\n");
            if (!continuation) if (summaryOutcome(line)) |outcome| {
                try diagnostics.finish();
                switch (outcome) {
                    .built => _ = self.built.fetchAdd(1, .release),
                    .failed => _ = self.failed.fetchAdd(1, .release),
                    else => unreachable,
                }
            };
        }
        try diagnostics.finish();
    }
};

/// Whether `line` is the summary that ends a build, and how the build went.
fn summaryOutcome(line: []const u8) ?Event {
    const summary = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.startsWith(u8, summary, "Build Summary:")) return null;
    return if (std.mem.indexOf(u8, summary, "failed") != null) .failed else .built;
}

test "a build's summary line says how it went" {
    try std.testing.expectEqual(Event.built, summaryOutcome("Build Summary: 89/89 steps succeeded\n").?);
    try std.testing.expectEqual(Event.failed, summaryOutcome("Build Summary: 85/89 steps succeeded (1 failed)\n").?);
    try std.testing.expectEqual(@as(?Event, null), summaryOutcome("src/main.zig:3:5: error: expected ';'\n"));
}
