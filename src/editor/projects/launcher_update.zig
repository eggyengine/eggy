//! Whether a newer launcher than this one is out: on a worker, reads Eggy's GitHub releases, finds
//! the one this launcher was built from (by its commit) and, when a newer release of the same
//! kind (a nightly, or a stable release) is listed above it, offers that one. A launcher built
//! outside a release, such as from a checkout, finds none and offers nothing.
const std = @import("std");
const process_environ = @import("../process_environ.zig");

/// Eggy's releases, newest first.
const releases_url = "https://api.github.com/repos/eggyengine/eggy/releases?per_page=30";
/// The most the release list may be.
const max_bytes = 4 << 20;

/// A release, as much of it as the check reads.
const Release = struct {
    tag_name: []const u8,
    name: ?[]const u8 = null,
    target_commitish: []const u8,
    html_url: []const u8,
    draft: bool = false,
};

/// A newer release than this launcher's, its text owned by the check.
pub const Newer = struct {
    /// Its title, as GitHub lists it ("Nightly 2026-11-08").
    name: []const u8,
    /// Its page, where it downloads from.
    url: [:0]const u8,
};

pub const Check = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    /// The commit this launcher was built from.
    commit: []const u8,
    worker: std.Io.Future(void) = undefined,

    // Shared with the worker, under `mutex`.
    mutex: std.Io.Mutex = .init,
    done: bool = false,
    newer: ?Newer = null,
    arena: std.heap.ArenaAllocator,

    /// Start looking for a release newer than the one built from `commit` (borrowed for the
    /// check's life); null for an empty commit, which no release has. Pair with `destroy`.
    ///
    /// ```zig
    /// const check = try Check.start(gpa, @import("build_options").commit);
    /// defer if (check) |found| found.destroy();
    /// ```
    pub fn start(gpa: std.mem.Allocator, commit: []const u8) !?*Check {
        if (commit.len == 0) return null;
        const self = try gpa.create(Check);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .threaded = .init(gpa, .{ .environ = process_environ.current() }), .commit = commit, .arena = .init(gpa) };
        errdefer self.threaded.deinit();
        self.worker = try self.threaded.io().concurrent(work, .{self});
        return self;
    }

    /// The newer release, once found; null while looking, or when there is none.
    pub fn take(self: *Check) ?Newer {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return if (self.done) self.newer else null;
    }

    /// Stop looking if it still is, and free it.
    pub fn destroy(self: *Check) void {
        const gpa = self.gpa;
        self.worker.cancel(self.threaded.io());
        self.threaded.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn work(self: *Check) void {
        // Quiet on failure: being offline isn't worth a word in a launcher.
        const found = self.read() catch |err| blk: {
            std.log.info("cannot check for a newer Eggy launcher: {t}", .{err});
            break :blk null;
        };
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.newer = found;
        self.done = true;
    }

    fn read(self: *Check) !?Newer {
        var client: std.http.Client = .{ .allocator = self.gpa, .io = self.threaded.io() };
        defer client.deinit();
        var body: std.Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        const result = try client.fetch(.{ .location = .{ .url = releases_url }, .response_writer = &body.writer });
        if (result.status.class() != .success) return error.HttpError;
        if (body.written().len > max_bytes) return error.FileTooBig;
        const arena = self.arena.allocator();
        const releases = try std.json.parseFromSliceLeaky([]const Release, arena, body.written(), .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        const release = newerThan(releases, self.commit) orelse return null;
        return .{ .name = release.name orelse release.tag_name, .url = try arena.dupeSentinel(u8, release.html_url, 0) };
    }
};

/// The newest release in `releases` (newest first) of the same kind as the one built from
/// `commit`, when that isn't it; null when `commit` is no release's or is the newest.
fn newerThan(releases: []const Release, commit: []const u8) ?Release {
    const own = for (releases) |release| {
        if (!release.draft and std.mem.eql(u8, release.target_commitish, commit)) break release;
    } else return null;
    for (releases) |release| {
        if (release.draft or isNightly(release) != isNightly(own)) continue;
        return if (std.mem.eql(u8, release.target_commitish, commit)) null else release;
    }
    return null;
}

fn isNightly(release: Release) bool {
    return std.mem.startsWith(u8, release.tag_name, "nightly");
}

test "a launcher is offered the newest release of its own kind, and nothing when it is that one" {
    const releases = [_]Release{
        .{ .tag_name = "nightly-2026-11-08", .target_commitish = "c3", .html_url = "n3" },
        .{ .tag_name = "v0.2.0", .target_commitish = "c2", .html_url = "r2" },
        .{ .tag_name = "nightly-2026-11-07", .target_commitish = "c1", .html_url = "n1" },
        .{ .tag_name = "v0.1.0", .target_commitish = "c0", .html_url = "r0" },
    };
    try std.testing.expectEqualStrings("n3", newerThan(&releases, "c1").?.html_url);
    try std.testing.expectEqualStrings("r2", newerThan(&releases, "c0").?.html_url);
    try std.testing.expect(newerThan(&releases, "c3") == null);
    try std.testing.expect(newerThan(&releases, "c2") == null);
    // Built outside any release: nothing to compare with.
    try std.testing.expect(newerThan(&releases, "local") == null);
}
