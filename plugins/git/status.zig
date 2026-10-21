//! The repository as the Git plugin last read it, and the parsers that turn git's output into it:
//! the branch and changed files (`git status`), branches and tags (`git for-each-ref`), commits
//! (`git log`), stashes, remotes and who commits.
const std = @import("std");

/// A file `git status` lists: its staged (`index`) and unstaged (`worktree`) status letters, as
/// in `git status --short` (' ' for none, '?' for untracked, 'U' and doubled letters in a
/// conflict).
pub const Change = struct {
    index: u8,
    worktree: u8,
    path: []const u8,

    pub fn isConflicted(change: Change) bool {
        return change.index == 'U' or change.worktree == 'U' or
            (change.index == 'A' and change.worktree == 'A') or
            (change.index == 'D' and change.worktree == 'D');
    }

    pub fn isUntracked(change: Change) bool {
        return change.index == '?';
    }

    pub fn isStaged(change: Change) bool {
        return !change.isConflicted() and change.index != ' ' and change.index != '?';
    }

    pub fn isUnstaged(change: Change) bool {
        return !change.isConflicted() and change.worktree != ' ';
    }

    /// The letter shown beside it in a list of `staged` or unstaged changes: M, A, D, R, C, or
    /// U for an untracked file.
    pub fn letter(change: Change, staged: bool) u8 {
        if (staged) return change.index;
        return if (change.isUntracked()) 'U' else change.worktree;
    }
};

/// A local or remote branch.
pub const Branch = struct {
    /// `main`, or `origin/main` for a remote one.
    name: []const u8,
    remote: bool,
    /// The branch checked out.
    current: bool = false,
    /// The branch it tracks (`origin/main`), if any.
    upstream: []const u8 = "",
    ahead: usize = 0,
    behind: usize = 0,
    /// Its upstream was deleted.
    gone: bool = false,
    commit: []const u8 = "",
    subject: []const u8 = "",
};

pub const Tag = struct { name: []const u8, commit: []const u8, subject: []const u8 };

pub const Commit = struct {
    /// Abbreviated, then in full.
    hash: []const u8,
    full_hash: []const u8,
    author: []const u8,
    /// How long ago, as git says it ("3 days ago").
    when: []const u8,
    /// The branches and tags pointing at it ("HEAD -> main, origin/main"), if any.
    refs: []const u8,
    subject: []const u8,
};

pub const Stash = struct {
    /// `stash@{0}`, which commands take.
    name: []const u8,
    subject: []const u8,
};

pub const Remote = struct { name: []const u8, url: []const u8 };

/// A command git stopped part way through, for conflicts to be resolved.
pub const Operation = enum {
    none,
    merging,
    rebasing,
    cherry_picking,
    reverting,

    /// The command, as `git <command> --continue` and `--abort` take it.
    pub fn command(operation: Operation) []const u8 {
        return switch (operation) {
            .none => "",
            .merging => "merge",
            .rebasing => "rebase",
            .cherry_picking => "cherry-pick",
            .reverting => "revert",
        };
    }

    pub fn title(operation: Operation) []const u8 {
        return switch (operation) {
            .none => "",
            .merging => "Merging",
            .rebasing => "Rebasing",
            .cherry_picking => "Cherry-picking",
            .reverting => "Reverting",
        };
    }
};

/// The repository as last read; every string lives in `arena`.
pub const State = struct {
    arena: std.heap.ArenaAllocator,
    repository: bool = false,
    branch: []const u8 = "",
    /// HEAD is a commit, not a branch.
    detached: bool = false,
    /// No commit yet, so unstaging can't restore from one.
    unborn: bool = false,
    /// The branch it tracks, and how far apart they are.
    upstream: []const u8 = "",
    ahead: usize = 0,
    behind: usize = 0,
    changes: []const Change = &.{},
    branches: []const Branch = &.{},
    tags: []const Tag = &.{},
    log: []const Commit = &.{},
    stashes: []const Stash = &.{},
    remotes: []const Remote = &.{},
    operation: Operation = .none,
    user_name: []const u8 = "",
    user_email: []const u8 = "",

    pub fn destroy(state: *State, gpa: std.mem.Allocator) void {
        state.arena.deinit();
        gpa.destroy(state);
    }

    /// How many changes are staged, unstaged and conflicted.
    pub fn counts(state: *const State) struct { staged: usize, unstaged: usize, conflicted: usize } {
        var staged: usize = 0;
        var unstaged: usize = 0;
        var conflicted: usize = 0;
        for (state.changes) |change| {
            staged += @intFromBool(change.isStaged());
            unstaged += @intFromBool(change.isUnstaged());
            conflicted += @intFromBool(change.isConflicted());
        }
        return .{ .staged = staged, .unstaged = unstaged, .conflicted = conflicted };
    }

    /// The remote a push or a tag goes to: the upstream's, else `origin`, else the first.
    pub fn pushRemote(state: *const State) ?[]const u8 {
        if (std.mem.indexOfScalar(u8, state.upstream, '/')) |slash| return state.upstream[0..slash];
        for (state.remotes) |remote| if (std.mem.eql(u8, remote.name, "origin")) return remote.name;
        return if (state.remotes.len > 0) state.remotes[0].name else null;
    }
};

/// Fill `state` from `git status --porcelain=v1 --branch` output: its `## branch...upstream
/// [ahead 1, behind 2]` line, then a line per file, `XY path` (or `XY old -> new`).
pub fn parseStatus(arena: std.mem.Allocator, state: *State, output: []const u8) !void {
    state.repository = true;
    var changes: std.ArrayList(Change) = .empty;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "## ")) {
            parseBranchLine(state, line[3..]);
            continue;
        }
        if (line.len < 4) continue;
        var path = line[3..];
        if (std.mem.indexOf(u8, path, " -> ")) |arrow| path = path[arrow + 4 ..];
        try changes.append(arena, .{ .index = line[0], .worktree = line[1], .path = std.mem.trim(u8, path, "\"") });
    }
    state.changes = changes.items;
}

fn parseBranchLine(state: *State, line: []const u8) void {
    var branch = line;
    if (std.mem.startsWith(u8, branch, "No commits yet on ")) {
        state.unborn = true;
        branch = branch["No commits yet on ".len..];
    }
    if (std.mem.startsWith(u8, branch, "HEAD (no branch)")) {
        state.detached = true;
        state.branch = "HEAD";
        return;
    }
    if (std.mem.indexOf(u8, branch, " [")) |at| {
        var parts = std.mem.tokenizeSequence(u8, std.mem.trimEnd(u8, branch[at + 2 ..], "]"), ", ");
        while (parts.next()) |part| {
            if (std.mem.startsWith(u8, part, "ahead ")) state.ahead = std.fmt.parseInt(usize, part[6..], 10) catch 0;
            if (std.mem.startsWith(u8, part, "behind ")) state.behind = std.fmt.parseInt(usize, part[7..], 10) catch 0;
        }
        branch = branch[0..at];
    }
    if (std.mem.indexOf(u8, branch, "...")) |dots| {
        state.upstream = branch[dots + 3 ..];
        branch = branch[0..dots];
    }
    state.branch = branch;
}

/// The `git for-each-ref` format `parseRefs` reads: a tab between fields, the subject last.
pub const refs_format = "%(HEAD)%09%(refname)%09%(upstream:short)%09%(upstream:track,nobracket)%09%(objectname:short)%09%(contents:subject)";

/// Fill `state`'s branches and tags from `git for-each-ref --format=<refs_format> refs/heads
/// refs/remotes refs/tags` output. Remotes' `HEAD` aliases are left out.
pub fn parseRefs(arena: std.mem.Allocator, state: *State, output: []const u8) !void {
    var branches: std.ArrayList(Branch) = .empty;
    var tags: std.ArrayList(Tag) = .empty;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const head = fields.next() orelse continue;
        const ref = fields.next() orelse continue;
        const upstream = fields.next() orelse "";
        const track = fields.next() orelse "";
        const commit = fields.next() orelse "";
        const subject = fields.rest();
        if (std.mem.startsWith(u8, ref, "refs/tags/")) {
            try tags.append(arena, .{ .name = ref["refs/tags/".len..], .commit = commit, .subject = subject });
            continue;
        }
        const remote = std.mem.startsWith(u8, ref, "refs/remotes/");
        const name = if (remote) ref["refs/remotes/".len..] else if (std.mem.startsWith(u8, ref, "refs/heads/")) ref["refs/heads/".len..] else continue;
        if (remote and std.mem.endsWith(u8, name, "/HEAD")) continue;
        var branch = Branch{ .name = name, .remote = remote, .current = std.mem.eql(u8, head, "*"), .upstream = upstream, .commit = commit, .subject = subject };
        var parts = std.mem.tokenizeSequence(u8, track, ", ");
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "gone")) branch.gone = true;
            if (std.mem.startsWith(u8, part, "ahead ")) branch.ahead = std.fmt.parseInt(usize, part[6..], 10) catch 0;
            if (std.mem.startsWith(u8, part, "behind ")) branch.behind = std.fmt.parseInt(usize, part[7..], 10) catch 0;
        }
        try branches.append(arena, branch);
    }
    state.branches = branches.items;
    state.tags = tags.items;
}

/// The `git log` format `parseLog` reads.
pub const log_format = "--format=%h%x09%H%x09%an%x09%ar%x09%D%x09%s";

/// Fill `state`'s commits from `git log <log_format>` output.
pub fn parseLog(arena: std.mem.Allocator, state: *State, output: []const u8) !void {
    var commits: std.ArrayList(Commit) = .empty;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const hash = fields.next() orelse continue;
        const full = fields.next() orelse continue;
        const author = fields.next() orelse continue;
        const when = fields.next() orelse continue;
        const refs = fields.next() orelse continue;
        try commits.append(arena, .{ .hash = hash, .full_hash = full, .author = author, .when = when, .refs = refs, .subject = fields.rest() });
    }
    state.log = commits.items;
}

/// Fill `state`'s stashes from `git stash list --format=%gd%x09%s` output.
pub fn parseStashes(arena: std.mem.Allocator, state: *State, output: []const u8) !void {
    var stashes: std.ArrayList(Stash) = .empty;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        try stashes.append(arena, .{ .name = line[0..tab], .subject = line[tab + 1 ..] });
    }
    state.stashes = stashes.items;
}

/// Fill `state`'s remotes from `git remote -v` output: `name<TAB>url (fetch)` and `(push)`,
/// each remote once.
pub fn parseRemotes(arena: std.mem.Allocator, state: *State, output: []const u8) !void {
    var remotes: std.ArrayList(Remote) = .empty;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const name = line[0..tab];
        if (remotes.items.len > 0 and std.mem.eql(u8, remotes.items[remotes.items.len - 1].name, name)) continue;
        const rest = line[tab + 1 ..];
        const url = if (std.mem.lastIndexOfScalar(u8, rest, ' ')) |space| rest[0..space] else rest;
        try remotes.append(arena, .{ .name = name, .url = url });
    }
    state.remotes = remotes.items;
}

test "git status gives the branch, how far it is from its upstream, and each change" {
    var state = State{ .arena = .init(std.testing.allocator) };
    defer state.arena.deinit();
    try parseStatus(state.arena.allocator(), &state,
        \\## main...origin/main [ahead 2, behind 1]
        \\M  src/main.zig
        \\ M build.zig
        \\R  old.zig -> new.zig
        \\?? notes.txt
        \\UU conflicted.zig
        \\
    );
    try std.testing.expectEqualStrings("main", state.branch);
    try std.testing.expectEqualStrings("origin/main", state.upstream);
    try std.testing.expectEqualStrings("origin", state.pushRemote().?);
    try std.testing.expect(!state.unborn and !state.detached);
    try std.testing.expectEqual(@as(usize, 2), state.ahead);
    try std.testing.expectEqual(@as(usize, 1), state.behind);
    try std.testing.expectEqual(@as(usize, 5), state.changes.len);
    try std.testing.expect(state.changes[0].isStaged() and !state.changes[0].isUnstaged());
    try std.testing.expect(!state.changes[1].isStaged() and state.changes[1].isUnstaged());
    try std.testing.expectEqualStrings("new.zig", state.changes[2].path);
    try std.testing.expectEqual(@as(u8, 'U'), state.changes[3].letter(false));
    // A conflict is neither staged nor unstaged until it is resolved.
    try std.testing.expect(state.changes[4].isConflicted() and !state.changes[4].isStaged() and !state.changes[4].isUnstaged());
    const counts = state.counts();
    try std.testing.expectEqual(@as(usize, 2), counts.staged);
    try std.testing.expectEqual(@as(usize, 2), counts.unstaged);
    try std.testing.expectEqual(@as(usize, 1), counts.conflicted);
}

test "a new repository has no commits and no upstream; a detached one has no branch" {
    var state = State{ .arena = .init(std.testing.allocator) };
    defer state.arena.deinit();
    try parseStatus(state.arena.allocator(), &state, "## No commits yet on main\nA  a.zig\n");
    try std.testing.expectEqualStrings("main", state.branch);
    try std.testing.expect(state.unborn and state.upstream.len == 0);
    var detached = State{ .arena = .init(std.testing.allocator) };
    defer detached.arena.deinit();
    try parseStatus(detached.arena.allocator(), &detached, "## HEAD (no branch)\n");
    try std.testing.expect(detached.detached);
}

test "refs give local and remote branches, with tracking, and tags" {
    var state = State{ .arena = .init(std.testing.allocator) };
    defer state.arena.deinit();
    try parseRefs(state.arena.allocator(), &state, "*\trefs/heads/main\torigin/main\tahead 1, behind 3\tabc1234\tFix the\ttab\n" ++
        " \trefs/heads/old\torigin/old\tgone\tdef5678\tOld work\n" ++
        " \trefs/remotes/origin/HEAD\t\t\tabc1234\tFix\n" ++
        " \trefs/remotes/origin/main\t\t\tabc1234\tFix\n" ++
        " \trefs/tags/v1.0.0\t\t\t0123abc\tRelease\n");
    try std.testing.expectEqual(@as(usize, 3), state.branches.len);
    const main = state.branches[0];
    try std.testing.expect(main.current and !main.remote);
    try std.testing.expectEqual(@as(usize, 1), main.ahead);
    try std.testing.expectEqual(@as(usize, 3), main.behind);
    try std.testing.expectEqualStrings("Fix the\ttab", main.subject);
    try std.testing.expect(state.branches[1].gone);
    try std.testing.expect(state.branches[2].remote);
    try std.testing.expectEqualStrings("origin/main", state.branches[2].name);
    try std.testing.expectEqualStrings("v1.0.0", state.tags[0].name);
}

test "log, stashes and remotes" {
    var state = State{ .arena = .init(std.testing.allocator) };
    defer state.arena.deinit();
    const a = state.arena.allocator();
    try parseLog(a, &state, "abc1234\tabc1234ffff\tSam\t2 days ago\tHEAD -> main, origin/main\tAdd a thing\n");
    try std.testing.expectEqualStrings("HEAD -> main, origin/main", state.log[0].refs);
    try std.testing.expectEqualStrings("Add a thing", state.log[0].subject);
    try parseStashes(a, &state, "stash@{0}\tOn main: halfway\nstash@{1}\tWIP on main: abc Fix\n");
    try std.testing.expectEqualStrings("stash@{1}", state.stashes[1].name);
    try parseRemotes(a, &state, "origin\thttps://example.com/r.git (fetch)\norigin\thttps://example.com/r.git (push)\nfork\tgit@example.com:me/r.git (fetch)\n");
    try std.testing.expectEqual(@as(usize, 2), state.remotes.len);
    try std.testing.expectEqualStrings("git@example.com:me/r.git", state.remotes[1].url);
}
