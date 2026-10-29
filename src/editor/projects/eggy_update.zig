//! How big a change to the linked Eggy codebase is, measured against the Eggy this editor was
//! built from: its commits since then, read with git and sorted by their Conventional Commit
//! type (`!` or `BREAKING CHANGE:` marks one that can break a game's code), and its version.
const std = @import("std");

/// How much an update could disturb a game's code.
pub const Size = enum {
    /// Nothing marked breaking: rebuild without asking.
    small,
    /// Some changes are marked breaking: ask before rebuilding.
    breaking,
    /// A major version, or many breaking changes: ask, with the whole changelog.
    extreme,
};

/// A commit's kind, for grouping the changelog.
pub const Kind = enum { feat, fix, perf, refactor, docs, other };

/// One commit since the build, as the changelog shows it.
pub const Change = struct {
    summary: []const u8,
    kind: Kind,
    breaking: bool,
};

/// What changed in the Eggy codebase since this editor was built; strings live in the arena
/// `measure` was given.
pub const Update = struct {
    size: Size,
    /// Newest first, as git lists them.
    changes: []const Change,
    /// Eggy's version when this editor was built, and now.
    from_version: []const u8,
    to_version: []const u8,
    /// The commit the codebase is at, so agreeing to it isn't asked again.
    head: []const u8,

    /// How many changes are marked breaking.
    pub fn breakingCount(self: Update) usize {
        var count: usize = 0;
        for (self.changes) |change| count += @intFromBool(change.breaking);
        return count;
    }
};

/// Breaking changes from which an update counts as extreme even without a major version.
const extreme_breaking_count = 5;

/// The commit `codebase` is checked out at, in `arena`; null when it isn't a git checkout or git
/// can't be run.
pub fn head(arena: std.mem.Allocator, io: std.Io, codebase: []const u8) ?[]const u8 {
    const output = git(arena, io, codebase, &.{ "git", "rev-parse", "HEAD" }) orelse return null;
    const trimmed = std.mem.trim(u8, output, " \r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// Measure `codebase` against the build: its commits since `built_head` (none when that is null
/// or git can't tell) and its version against `built_version`. Null when it is still at the
/// commit and version the editor was built from. Strings live in `arena`.
// ponytail: runs git on the main thread; move it to a worker if large histories make refocusing stall.
pub fn measure(arena: std.mem.Allocator, io: std.Io, codebase: []const u8, built_head: ?[]const u8, built_version: []const u8) !?Update {
    const now_head = head(arena, io, codebase) orelse "";
    const to_version = try readVersion(arena, io, codebase) orelse built_version;
    const moved = if (built_head) |built| !std.mem.eql(u8, built, now_head) else false;
    if (!moved and std.mem.eql(u8, to_version, built_version)) return null;

    // `%x1e` ends each commit and `%x1f` parts its subject from its body, neither of which
    // commit messages hold.
    const log = if (moved) git(arena, io, codebase, &.{
        "git",                                                       "log", "--no-merges", "--format=%s%x1f%b%x1e",
        try std.fmt.allocPrint(arena, "{s}..HEAD", .{built_head.?}),
    }) orelse "" else "";
    const changes = try parseLog(arena, log);
    return .{
        .size = sizeOf(changes, built_version, to_version),
        .changes = changes,
        .from_version = built_version,
        .to_version = to_version,
        .head = now_head,
    };
}

/// Each commit `git log` printed, by its Conventional Commit header and body.
fn parseLog(arena: std.mem.Allocator, log: []const u8) ![]const Change {
    var changes: std.ArrayList(Change) = .empty;
    var commits = std.mem.splitScalar(u8, log, 0x1e);
    while (commits.next()) |commit| {
        const trimmed = std.mem.trim(u8, commit, " \r\n");
        if (trimmed.len == 0) continue;
        const subject_end = std.mem.indexOfScalar(u8, trimmed, 0x1f) orelse trimmed.len;
        const subject = trimmed[0..subject_end];
        const body = trimmed[@min(trimmed.len, subject_end + 1)..];
        try changes.append(arena, .{ .summary = subject, .kind = kindOf(subject), .breaking = isBreaking(subject, body) });
    }
    return changes.items;
}

/// The type a header such as `feat(editor)!: summary` starts with.
fn kindOf(subject: []const u8) Kind {
    const type_end = std.mem.indexOfAny(u8, subject, "(!:") orelse return .other;
    return std.meta.stringToEnum(Kind, subject[0..type_end]) orelse .other;
}

/// Whether a commit says it breaks something: `!` before its header's colon, or a
/// `BREAKING CHANGE:` footer.
fn isBreaking(subject: []const u8, body: []const u8) bool {
    if (std.mem.indexOfScalar(u8, subject, ':')) |colon| if (colon > 0 and subject[colon - 1] == '!') return true;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "BREAKING CHANGE:") or std.mem.startsWith(u8, line, "BREAKING-CHANGE:")) return true;
    }
    return false;
}

fn sizeOf(changes: []const Change, from_version: []const u8, to_version: []const u8) Size {
    var breaking: usize = 0;
    for (changes) |change| breaking += @intFromBool(change.breaking);
    const version_change = versionChange(from_version, to_version);
    if (version_change == .major or breaking >= extreme_breaking_count) return .extreme;
    if (version_change == .breaking or breaking > 0) return .breaking;
    return .small;
}

/// What a version change promises under semver: a new major version (or the first stable one)
/// is major; a new minor version before 1.0 may break; anything else shouldn't.
fn versionChange(from: []const u8, to: []const u8) enum { none, breaking, major } {
    const old = std.SemanticVersion.parse(from) catch return .none;
    const new = std.SemanticVersion.parse(to) catch return .none;
    if (new.major != old.major) return .major;
    if (new.major == 0 and new.minor != old.minor) return .breaking;
    return .none;
}

/// The `.version` in `codebase`'s `build.zig.zon`; null if it can't be read.
fn readVersion(arena: std.mem.Allocator, io: std.Io, codebase: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(arena, &.{ codebase, "build.zig.zon" });
    const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0) catch return null;
    const Manifest = struct { version: []const u8 };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(Manifest, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &diagnostics, .ignore_unknown_fields = true }) catch return null;
    return manifest.version;
}

/// `argv`'s standard output when it succeeds in `cwd`, else null.
fn git(arena: std.mem.Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(arena, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4 << 20),
        .stderr_limit = .limited(64 << 10),
    }) catch return null;
    if (!result.term.success()) return null;
    return result.stdout;
}

test "commits are sorted by their header, and ! or a BREAKING CHANGE footer marks them breaking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const log = "feat(core)!: rename App.world\x1f\x1e\n" ++
        "fix(editor): stop a crash\x1fBREAKING CHANGE: Hook.draw takes a context\n\x1e\n" ++
        "docs: explain hooks\x1f\x1e\n" ++
        "Update README.md\x1f\x1e\n";
    const changes = try parseLog(arena.allocator(), log);
    try std.testing.expectEqual(4, changes.len);
    try std.testing.expectEqualStrings("feat(core)!: rename App.world", changes[0].summary);
    try std.testing.expect(changes[0].breaking and changes[0].kind == .feat);
    try std.testing.expect(changes[1].breaking and changes[1].kind == .fix);
    try std.testing.expect(!changes[2].breaking and changes[2].kind == .docs);
    try std.testing.expect(!changes[3].breaking and changes[3].kind == .other);
}

test "an update's size follows its breaking changes and its version" {
    const feature = Change{ .summary = "feat: a", .kind = .feat, .breaking = false };
    const breaking = Change{ .summary = "feat!: b", .kind = .feat, .breaking = true };
    try std.testing.expectEqual(.small, sizeOf(&.{feature}, "0.1.0", "0.1.1"));
    try std.testing.expectEqual(.breaking, sizeOf(&.{ feature, breaking }, "0.1.0", "0.1.0"));
    try std.testing.expectEqual(.breaking, sizeOf(&.{feature}, "0.1.0", "0.2.0"));
    const five_breaking: [5]Change = @splat(breaking);
    try std.testing.expectEqual(.extreme, sizeOf(&five_breaking, "0.1.0", "0.1.0"));
    try std.testing.expectEqual(.extreme, sizeOf(&.{}, "0.9.0", "1.0.0"));
    try std.testing.expectEqual(.small, sizeOf(&.{}, "1.2.0", "1.3.0"));
}
