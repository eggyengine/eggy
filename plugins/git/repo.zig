//! The project's repository, as the Git plugin talks to it: `git` runs in the project's folder on
//! a worker, one job at a time, and what a job finds (the repository's state, a diff, a command's
//! output) is handed to the editor's thread, which owns it from then on.
const std = @import("std");
const status = @import("status.zig");
const State = status.State;

/// How often the repository is read again on its own, for changes made outside the editor.
const refresh_interval_ms = 3000;
/// How many commits History lists.
const log_length = "200";
/// The most a command may print; more fails it.
const output_limit = 16 << 20;

/// A diff (of a file, a commit or a stash), its tabs as spaces, cut into lines.
pub const Diff = struct {
    arena: std.heap.ArenaAllocator,
    /// What it is a diff of, as `Repo.showDiff` was given it.
    key: []const u8,
    text: []const u8,
    lines: []const Line,

    pub const Line = struct { start: usize, end: usize };

    pub fn line(diff: *const Diff, index: usize) []const u8 {
        const at = diff.lines[index];
        return diff.text[at.start..at.end];
    }

    fn destroy(diff: *Diff, gpa: std.mem.Allocator) void {
        diff.arena.deinit();
        gpa.destroy(diff);
    }
};

/// What the last command (not a refresh or a diff) did.
pub const Report = struct {
    /// The action, as people read it ("Pull").
    title: []const u8 = "",
    output: []const u8 = "",
    failed: bool = false,
};

/// A job for the worker: commands to run one after the other, stopping at the first that fails.
const Job = struct {
    arena: std.heap.ArenaAllocator,
    kind: enum { refresh, action, diff },
    title: []const u8 = "",
    commands: []const []const []const u8 = &.{},
    /// For a diff: what it is a diff of.
    key: []const u8 = "",
};

/// The repository. `state`, `diff` and `report` belong to the editor's thread: only `update`
/// changes them, so what the panel built from them stays valid until the next `update`.
/// Heap-allocated so the plugin can move.
pub const Repo = struct {
    gpa: std.mem.Allocator,
    /// The worker's I/O, with the editor's environment so `git` is found on PATH.
    threaded: std.Io.Threaded,
    /// git's environment: the editor's, with prompts for credentials and editors turned off, so
    /// a push that needs a password fails instead of waiting forever.
    environ: std.process.Environ.Map,
    folder: []u8,
    worker: ?std.Io.Future(void) = null,
    /// When it last started reading the repository; the first update reads it at once.
    refreshed_ms: i64 = std.math.minInt(i64) / 2,

    // The editor's thread's.
    state: ?*State = null,
    diff: ?*Diff = null,
    report: Report = .{},
    report_arena: std.heap.ArenaAllocator,
    /// A job is on the worker.
    busy: bool = false,
    /// Its title, while `busy`.
    running: []const u8 = "",
    running_buffer: [64]u8 = undefined,
    /// The diff wanted next, run once the worker is free.
    wanted: ?*Job = null,

    // Shared with the worker, under `mutex`.
    mutex: std.Io.Mutex = .init,
    finished: bool = false,
    incoming_state: ?*State = null,
    incoming_diff: ?*Diff = null,
    incoming_report: ?Report = null,

    /// Open the repository (or the folder that will become one) at `folder`.
    pub fn create(gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map, environ: std.process.Environ, folder: []const u8) !*Repo {
        const self = try gpa.create(Repo);
        errdefer gpa.destroy(self);
        var map = try environ_map.clone(gpa);
        errdefer map.deinit();
        try map.put("GIT_TERMINAL_PROMPT", "0");
        try map.put("GIT_EDITOR", "true");
        try map.put("GIT_MERGE_AUTOEDIT", "no");
        self.* = .{ .gpa = gpa, .threaded = .init(gpa, .{ .environ = environ }), .environ = map, .folder = try gpa.dupe(u8, folder), .report_arena = .init(gpa) };
        return self;
    }

    /// Stop the job running, if any, and free everything.
    pub fn destroy(self: *Repo) void {
        const gpa = self.gpa;
        if (self.worker) |*worker| worker.cancel(self.io());
        self.threaded.deinit();
        if (self.wanted) |job| job.arena.deinit();
        inline for (.{ self.state, self.incoming_state }) |state| if (state) |known| known.destroy(gpa);
        inline for (.{ self.diff, self.incoming_diff }) |diff| if (diff) |known| known.destroy(gpa);
        if (self.incoming_report) |report| {
            gpa.free(report.title);
            gpa.free(report.output);
        }
        self.report_arena.deinit();
        self.environ.deinit();
        gpa.free(self.folder);
        gpa.destroy(self);
    }

    fn io(self: *Repo) std.Io {
        return self.threaded.io();
    }

    /// Once a frame, from the editor's thread: take what the last job found, then start the diff
    /// wanted, or read the repository again when it's time.
    pub fn update(self: *Repo) void {
        self.adoptFinished();
        if (self.busy) return;
        if (self.wanted) |job| {
            self.wanted = null;
            return self.startJob(job);
        }
        if (self.now() - self.refreshed_ms >= refresh_interval_ms) self.refresh();
    }

    /// Read the repository again now, unless a job is running.
    pub fn refresh(self: *Repo) void {
        if (self.busy) return;
        const job = self.newJob(.refresh, "Reading the repository") orelse return;
        self.startJob(job);
    }

    /// Run `commands` (each a git argv, copied) one after the other as the action `title`,
    /// stopping at the first that fails; then read the repository again. Does nothing while
    /// another job runs.
    pub fn run(self: *Repo, title: []const u8, commands: []const []const []const u8) void {
        if (self.busy) return;
        const job = self.newJob(.action, title) orelse return;
        job.commands = copyCommands(job.arena.allocator(), commands) catch return job.arena.deinit();
        self.startJob(job);
    }

    /// Show the output of `argv` (a diff) as `key`'s diff, once the worker is free; the current
    /// one stays until then. Asking again for the shown key does nothing.
    pub fn showDiff(self: *Repo, key: []const u8, argv: []const []const u8) void {
        if (self.diff) |shown| if (std.mem.eql(u8, shown.key, key)) return;
        if (self.wanted) |job| {
            if (std.mem.eql(u8, job.key, key)) return;
            job.arena.deinit();
            self.wanted = null;
        }
        const job = self.newJob(.diff, "Reading the diff") orelse return;
        const a = job.arena.allocator();
        job.key = a.dupe(u8, key) catch return job.arena.deinit();
        job.commands = copyCommands(a, &.{argv}) catch return job.arena.deinit();
        self.wanted = job;
    }

    /// Stop showing a diff.
    pub fn hideDiff(self: *Repo) void {
        if (self.diff) |diff| diff.destroy(self.gpa);
        self.diff = null;
        if (self.wanted) |job| job.arena.deinit();
        self.wanted = null;
    }

    /// Show `message` as `title`'s outcome, without running anything.
    pub fn say(self: *Repo, title: []const u8, message: []const u8, failed: bool) void {
        _ = self.report_arena.reset(.retain_capacity);
        const a = self.report_arena.allocator();
        self.report = .{ .title = a.dupe(u8, title) catch "", .output = a.dupe(u8, message) catch "", .failed = failed };
    }

    fn now(self: *Repo) i64 {
        return std.Io.Clock.awake.now(self.io()).toMilliseconds();
    }

    /// A job in its own arena (in a page of the heap: it moves to the worker).
    fn newJob(self: *Repo, kind: @FieldType(Job, "kind"), title: []const u8) ?*Job {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        const job = arena.allocator().create(Job) catch {
            arena.deinit();
            return null;
        };
        job.* = .{ .arena = undefined, .kind = kind, .title = arena.allocator().dupe(u8, title) catch "" };
        job.arena = arena;
        return job;
    }

    fn startJob(self: *Repo, job: *Job) void {
        // The last one has finished (`adoptFinished` saw it): collect its worker.
        if (self.worker) |*worker| worker.await(self.io());
        self.worker = null;
        self.busy = true;
        const title = job.title[0..@min(job.title.len, self.running_buffer.len)];
        @memcpy(self.running_buffer[0..title.len], title);
        self.running = self.running_buffer[0..title.len];
        if (job.kind != .diff) self.refreshed_ms = self.now();
        self.worker = self.io().concurrent(work, .{ self, job }) catch {
            job.arena.deinit();
            self.busy = false;
            return;
        };
    }

    /// Take what the finished job left, freeing what it replaces.
    fn adoptFinished(self: *Repo) void {
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        if (!self.finished) return;
        self.finished = false;
        self.busy = false;
        if (self.incoming_state) |state| {
            if (self.state) |old| old.destroy(self.gpa);
            self.state = state;
            self.incoming_state = null;
        }
        if (self.incoming_diff) |diff| {
            if (self.diff) |old| old.destroy(self.gpa);
            self.diff = diff;
            self.incoming_diff = null;
        }
        if (self.incoming_report) |report| {
            self.say(report.title, report.output, report.failed);
            self.gpa.free(report.title);
            self.gpa.free(report.output);
            self.incoming_report = null;
        }
    }

    /// The worker: run `job`, then hand over what it found, and the repository read again
    /// after an action.
    fn work(self: *Repo, job: *Job) void {
        defer job.arena.deinit();
        const a = job.arena.allocator();
        var report: ?Report = null;
        var diff: ?*Diff = null;
        switch (job.kind) {
            .refresh => {},
            .action => report = self.runAll(a, job) catch |err| .{ .title = job.title, .output = @errorName(err), .failed = true },
            .diff => diff = self.readDiff(job) catch |err| blk: {
                std.log.warn("git: cannot read a diff: {t}", .{err});
                break :blk null;
            },
        }
        const state = if (job.kind == .diff) null else self.read() catch |err| blk: {
            std.log.err("git: cannot read {s}: {t}", .{ self.folder, err });
            break :blk null;
        };

        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        if (state) |new| self.incoming_state = new;
        if (diff) |new| self.incoming_diff = new;
        if (report) |done| self.incoming_report = self.copyReport(done) catch null;
        self.finished = true;
    }

    fn copyReport(self: *Repo, report: Report) !Report {
        const title = try self.gpa.dupe(u8, report.title);
        errdefer self.gpa.free(title);
        return .{ .title = title, .output = try self.gpa.dupe(u8, std.mem.trim(u8, report.output, " \r\n")), .failed = report.failed };
    }

    /// Run `job`'s commands until one fails, collecting what they print.
    fn runAll(self: *Repo, arena: std.mem.Allocator, job: *const Job) !Report {
        var output: std.ArrayList(u8) = .empty;
        for (job.commands) |argv| {
            const result = try self.git(arena, argv);
            try output.appendSlice(arena, result.stdout);
            try output.appendSlice(arena, result.stderr);
            if (result.term != .exited or result.term.exited != 0) return .{ .title = job.title, .output = output.items, .failed = true };
        }
        return .{ .title = job.title, .output = output.items };
    }

    /// The output of `job`'s one command, whatever its exit code (`git diff --no-index` gives 1
    /// for a difference), as a diff.
    fn readDiff(self: *Repo, job: *const Job) !*Diff {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const result = try self.git(scratch.allocator(), job.commands[0]);
        const diff = try self.gpa.create(Diff);
        errdefer self.gpa.destroy(diff);
        diff.* = .{ .arena = .init(self.gpa), .key = "", .text = "", .lines = &.{} };
        errdefer diff.arena.deinit();
        const a = diff.arena.allocator();
        diff.key = try a.dupe(u8, job.key);
        const text = if (result.stdout.len > 0) result.stdout else result.stderr;
        diff.text = try expandTabs(a, text);
        diff.lines = try splitLines(a, diff.text);
        return diff;
    }

    fn git(self: *Repo, arena: std.mem.Allocator, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(arena, self.io(), .{
            .argv = argv,
            .cwd = .{ .path = self.folder },
            .environ_map = &self.environ,
            .stdout_limit = .limited(output_limit),
            .stderr_limit = .limited(output_limit),
        });
    }

    /// `argv`'s standard output when it succeeds, else null.
    fn gitOutput(self: *Repo, arena: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
        const result = self.git(arena, argv) catch return null;
        if (result.term != .exited or result.term.exited != 0) return null;
        return result.stdout;
    }

    /// The repository as it is now.
    fn read(self: *Repo) !*State {
        const state = try self.gpa.create(State);
        state.* = .{ .arena = .init(self.gpa) };
        errdefer state.destroy(self.gpa);
        const a = state.arena.allocator();
        // Not a repository: nothing else to read.
        const changes = self.gitOutput(a, &.{ "git", "status", "--porcelain=v1", "--branch", "--untracked-files=all" }) orelse return state;
        try status.parseStatus(a, state, changes);
        if (self.gitOutput(a, &.{ "git", "for-each-ref", "--format=" ++ status.refs_format, "refs/heads", "refs/remotes", "refs/tags" })) |refs| try status.parseRefs(a, state, refs);
        if (!state.unborn) if (self.gitOutput(a, &.{ "git", "log", "-n", log_length, status.log_format })) |log| try status.parseLog(a, state, log);
        if (self.gitOutput(a, &.{ "git", "stash", "list", "--format=%gd%x09%s" })) |stashes| try status.parseStashes(a, state, stashes);
        if (self.gitOutput(a, &.{ "git", "remote", "-v" })) |remotes| try status.parseRemotes(a, state, remotes);
        if (self.gitOutput(a, &.{ "git", "config", "user.name" })) |name| state.user_name = std.mem.trim(u8, name, " \r\n");
        if (self.gitOutput(a, &.{ "git", "config", "user.email" })) |email| state.user_email = std.mem.trim(u8, email, " \r\n");
        state.operation = self.readOperation(a);
        return state;
    }

    /// The command git stopped part way through, from the files it leaves in its folder.
    fn readOperation(self: *Repo, arena: std.mem.Allocator) status.Operation {
        const git_dir = std.mem.trim(u8, self.gitOutput(arena, &.{ "git", "rev-parse", "--absolute-git-dir" }) orelse return .none, " \r\n");
        const markers = [_]struct { name: []const u8, operation: status.Operation }{
            .{ .name = "rebase-merge", .operation = .rebasing },
            .{ .name = "rebase-apply", .operation = .rebasing },
            .{ .name = "MERGE_HEAD", .operation = .merging },
            .{ .name = "CHERRY_PICK_HEAD", .operation = .cherry_picking },
            .{ .name = "REVERT_HEAD", .operation = .reverting },
        };
        for (markers) |marker| {
            const path = std.fs.path.join(arena, &.{ git_dir, marker.name }) catch continue;
            if (std.Io.Dir.cwd().access(self.io(), path, .{})) return marker.operation else |_| {}
        }
        return .none;
    }
};

fn copyCommands(arena: std.mem.Allocator, commands: []const []const []const u8) ![]const []const []const u8 {
    const copies = try arena.alloc([]const []const u8, commands.len);
    for (copies, commands) |*copy, argv| {
        const args = try arena.alloc([]const u8, argv.len);
        for (args, argv) |*arg, original| arg.* = try arena.dupe(u8, original);
        copy.* = args;
    }
    return copies;
}

/// `text` with each tab as spaces to the next multiple of four columns.
fn expandTabs(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\t') == null) return arena.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    var column: usize = 0;
    for (text) |c| switch (c) {
        '\t' => {
            const spaces = 4 - column % 4;
            try out.appendNTimes(arena, ' ', spaces);
            column += spaces;
        },
        '\n' => {
            try out.append(arena, c);
            column = 0;
        },
        else => {
            try out.append(arena, c);
            column += 1;
        },
    };
    return out.items;
}

fn splitLines(arena: std.mem.Allocator, text: []const u8) ![]const Diff.Line {
    var lines: std.ArrayList(Diff.Line) = .empty;
    var start: usize = 0;
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    while (start <= trimmed.len) {
        const end = std.mem.indexOfScalarPos(u8, trimmed, start, '\n') orelse trimmed.len;
        try lines.append(arena, .{ .start = start, .end = std.mem.trimEnd(u8, trimmed[start..end], "\r").len + start });
        start = end + 1;
    }
    return lines.items;
}

test "a diff's tabs become spaces and it is cut into lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try expandTabs(a, "+\tx\n-ab\ty\r\n");
    try std.testing.expectEqualStrings("+   x\n-ab y\r\n", text);
    const lines = try splitLines(a, text);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("-ab y", text[lines[1].start..lines[1].end]);
}

test "a repository is read on a worker and handed over on update" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const folder = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(folder);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    if (std.c.getenv("PATH")) |path| try environ.put("PATH", std.mem.span(path));
    // The test's folder is inside Eggy's own repository: keep git from finding that.
    try environ.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(folder).?);
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const repo = try Repo.create(std.testing.allocator, &environ, .{ .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) } }, folder);
    defer repo.destroy();

    // Not a repository yet; then one, after Create.
    repo.update();
    while (repo.busy) : (try std.Io.sleep(io, .fromMilliseconds(5), .awake)) repo.update();
    const before = repo.state orelse return error.SkipZigTest; // no git here
    try std.testing.expect(!before.repository);
    repo.run("Create", &.{&.{ "git", "init", "-q" }});
    while (repo.busy) : (try std.Io.sleep(io, .fromMilliseconds(5), .awake)) repo.update();
    if (repo.report.failed) return error.SkipZigTest;
    try std.testing.expect(repo.state.?.repository and repo.state.?.unborn);
}
