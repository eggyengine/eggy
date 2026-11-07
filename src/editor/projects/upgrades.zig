//! Which other Eggy the open project could build against: a newer packaged engine (File >
//! Upgrade Editor), which is the commit the Eggy source (the `eggy_source` preference) is at once
//! a background check has read it, else the newest engine unpacked; or the Eggy codebase being
//! developed on this machine (File > Link Developer Eggy), for the menus and status bar.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const engine = @import("engine.zig");
const job = @import("job.zig");
const eggy_source = @import("eggy_source.zig");

/// How long a check of the Eggy source stands before refocusing the editor checks again.
const recheck_ms = 30 * std.time.ms_per_min;

pub const Upgrades = struct {
    /// Holds `current` and `label`, for the editor's lifetime.
    arena: std.heap.ArenaAllocator,
    /// Holds `developer_dir`, until the next `refresh`.
    records: std.heap.ArenaAllocator,
    /// The Eggy the project built this editor with; null without a project, or if unreadable.
    current: ?engine.ProjectEngine = null,
    /// The commit `current` was made from, when it is packaged and recorded one.
    current_commit: ?[]const u8 = null,
    /// The newest engine unpacked, from the last `refresh`.
    latest: ?engine.Engine = null,
    /// Reading the Eggy source's commit, or done reading it.
    check: ?*eggy_source.Check = null,
    /// When `check` started, in milliseconds since SDL started.
    checked_ms: u64 = 0,
    /// `current` for the status bar: a packaged engine's short commit (its directory's name when
    /// it recorded none), or the linked codebase.
    label: ?[]const u8 = null,
    /// The short commit File > Upgrade Editor moves to, while `can_upgrade` and it is known.
    /// Borrowed until the next `refresh`.
    upgrade_label: ?[]const u8 = null,
    /// The Eggy codebase being developed, from the last `refresh`.
    developer_dir: ?[]const u8 = null,
    can_upgrade: bool = false,
    can_link: bool = false,
    /// Whether File > Upgrade Editor can look for a newer Eggy: the project uses a packaged one.
    can_check: bool = false,
    /// Whether File > Upgrade Editor asked for the check under way, so `poll` answers it.
    asked: bool = false,

    /// Read which Eggy the project in `project_dir` (absolute; null without a project) uses,
    /// after recording `source_dir`, the Eggy this editor was built from, as the codebase being
    /// developed if it is a checkout. Failures leave the choices off.
    /// Desktop editor only: owns two arenas using `gpa`; all displayed paths/labels borrow
    /// them. May update the global developer-engine record; project/record failures are
    /// logged or treated as unavailable. Pair with `deinit`.
    ///
    /// ```zig
    /// var upgrades = Upgrades.init(gpa, project_dir, source_dir, prefs.eggy_source);
    /// defer upgrades.deinit(); // Existing allocator and absolute optional project/source paths.
    /// ```
    pub fn init(gpa: std.mem.Allocator, project_dir: ?[]const u8, source_dir: []const u8, eggy_source_text: []const u8) Upgrades {
        var self = Upgrades{ .arena = .init(gpa), .records = .init(gpa) };
        const folders = job.editorFolders(gpa) catch return self;
        defer gpa.free(folders.resources_dir);
        defer gpa.free(folders.engines_dir);
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        engine.markDeveloper(io, folders.engines_dir, source_dir) catch |err| std.log.warn("cannot record the Eggy codebase {s}: {t}", .{ source_dir, err });
        if (project_dir) |dir| self.readCurrent(io, dir, folders.engines_dir);
        self.refresh(eggy_source_text);
        return self;
    }

    /// Set `current` and `label` from the project in `dir`; on failure, leave them null.
    fn readCurrent(self: *Upgrades, io: std.Io, dir: []const u8, engines_dir: []const u8) void {
        const arena = self.arena.allocator();
        const current = engine.projectEngine(arena, io, dir, engines_dir) catch |err| {
            std.log.warn("cannot tell which Eggy {s} uses: {t}", .{ dir, err });
            return;
        };
        self.current = current;
        self.can_check = current == .packaged;
        if (current == .packaged) {
            const engine_dir = std.fs.path.join(arena, &.{ engines_dir, current.packaged }) catch return;
            self.current_commit = engine.commitOf(arena, io, engine_dir);
        }
        self.label = switch (current) {
            .packaged => |name| if (self.current_commit) |commit| shortCommit(commit) else name[0..@min(8, name.len)],
            .linked => |codebase| std.fmt.allocPrint(arena, "linked to {s}", .{codebase}) catch null,
            .fetched => null,
        };
    }

    /// Free editor upgrade arenas once; invalidate current-engine, label and developer paths.
    ///
    /// ```zig
    /// var upgrades = Upgrades.init(gpa, project_dir, source_dir); // Existing host inputs.
    /// defer upgrades.deinit();
    /// ```
    pub fn deinit(self: *Upgrades) void {
        if (self.check) |check| check.destroy();
        self.records.deinit();
        self.arena.deinit();
    }

    /// Look again for a newer engine and the codebase being developed; another editor may have
    /// unpacked or recorded one since. Checks the Eggy source `eggy_source_text` again in the
    /// background when it changed, or the last check is old; `poll` takes its answer.
    /// Desktop editor only: resets record storage, invalidating previous developer-path borrows;
    /// current-engine/label storage is unchanged. Availability is best-effort and errors are
    /// not returned; callers should inspect the updated fields after success.
    ///
    /// ```zig
    /// upgrades.refresh(prefs.eggy_source); // Existing Upgrades, e.g. when the editor regains focus.
    /// ```
    pub fn refresh(self: *Upgrades, eggy_source_text: []const u8) void {
        const gpa = self.arena.child_allocator;
        _ = self.records.reset(.retain_capacity);
        self.latest = null;
        self.developer_dir = null;
        self.recheck(eggy_source_text);
        defer self.decide();
        const folders = job.editorFolders(gpa) catch return;
        defer gpa.free(folders.resources_dir);
        defer gpa.free(folders.engines_dir);
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const records = self.records.allocator();
        if (engine.latest(records, io, folders.engines_dir) catch null) |name| {
            const dir = std.fs.path.join(records, &.{ folders.engines_dir, name }) catch return;
            self.latest = .{ .name = name, .commit = engine.commitOf(records, io, dir) };
        }
        self.developer_dir = engine.developer(records, io, folders.engines_dir) catch null;
    }

    /// What a check File > Upgrade Editor asked for (`checkNow`) found.
    pub const Answer = union(enum) {
        /// A newer Eggy: `can_upgrade` is set.
        newer,
        up_to_date,
        /// Why it couldn't look, for people: static text.
        failed: []const u8,
    };

    /// Take the Eggy source check's answer once it has one, updating `can_upgrade`; returns it
    /// when `checkNow` asked for it, once. Call each frame.
    ///
    /// ```zig
    /// if (upgrades.poll()) |answer| report(answer);
    /// ```
    pub fn poll(self: *Upgrades) ?Answer {
        const check = self.check orelse return null;
        const outcome = check.take() orelse return null;
        const was = self.can_upgrade;
        self.decide();
        if (self.can_upgrade and !was) std.log.info("a newer Eggy is at {s}: File > Upgrade Editor", .{check.text});
        if (!self.asked) return null;
        self.asked = false;
        if (self.can_upgrade) return .newer;
        return switch (outcome.*) {
            .commit => .up_to_date,
            .failed => |why| .{ .failed = why },
        };
    }

    /// Whether a check File > Upgrade Editor asked for is still reading.
    pub fn checking(self: *const Upgrades) bool {
        const check = self.check orelse return false;
        return self.asked and check.take() == null;
    }

    /// Look at the Eggy source `eggy_source_text` again now, for File > Upgrade Editor; `poll`
    /// answers once it has read it. Fails only when the check can't start (`describe` words it).
    ///
    /// ```zig
    /// upgrades.checkNow(prefs.eggy_source) catch |err| toast(eggy_source.describe(err));
    /// ```
    pub fn checkNow(self: *Upgrades, eggy_source_text: []const u8) !void {
        self.asked = false;
        if (self.check) |check| check.destroy();
        self.check = null;
        defer self.decide();
        try self.startCheck(eggy_source_text);
        self.asked = true;
    }

    /// The Eggy source's commit to upgrade to, borrowed until the next `refresh`; null until a
    /// check found one, when Upgrade Editor moves to the newest engine unpacked.
    ///
    /// ```zig
    /// try host.startBuild(.{ .upgrade = upgrades.sourceCommit() });
    /// ```
    pub fn sourceCommit(self: *const Upgrades) ?job.SourceCommit {
        const check = self.check orelse return null;
        const commit = remoteCommit(check) orelse return null;
        return .{ .url = check.source.url, .commit = commit };
    }

    /// Start checking `text` unless a check of it is under way or recent.
    fn recheck(self: *Upgrades, text: []const u8) void {
        const now_ms = sdl3.timer.getMillisecondsSinceInit();
        if (self.check) |check| {
            const fresh = check.take() == null or now_ms -| self.checked_ms < recheck_ms;
            if (std.mem.eql(u8, check.text, text) and fresh) return;
            check.destroy();
            self.check = null;
            self.asked = false;
        }
        self.startCheck(text) catch |err| std.log.warn("cannot check the Eggy source {s} for a newer Eggy: {s}", .{ text, eggy_source.describe(err) });
    }

    fn startCheck(self: *Upgrades, text: []const u8) !void {
        self.check = try eggy_source.Check.start(self.arena.child_allocator, text);
        self.checked_ms = sdl3.timer.getMillisecondsSinceInit();
    }

    /// Set `can_upgrade` and `can_link`: the project upgrades to the Eggy source's commit once
    /// known, else to the newest engine unpacked.
    fn decide(self: *Upgrades) void {
        const current = self.current orelse return;
        const newest: ?engine.Engine = if (self.sourceCommit()) |source| .{ .name = eggy_source.engineName(source.commit), .commit = source.commit } else self.latest;
        self.can_upgrade = current.canUpgrade(self.current_commit, newest);
        self.upgrade_label = if (!self.can_upgrade) null else if (newest) |found| if (found.commit) |commit| shortCommit(commit) else null else null;
        self.can_link = current.canLink(self.developer_dir);
    }

    /// Log why File > Upgrade Editor (`.upgrade`) or Link Developer Eggy (`.link`) can't run.
    /// Desktop editor only: reports the cached state; does not refresh records, show dialogs
    /// or change a dependency.
    ///
    /// ```zig
    /// upgrades.logUnavailable(.upgrade); // Existing Upgrades when its menu action is disabled.
    /// ```
    pub fn logUnavailable(self: *const Upgrades, choice: enum { upgrade, link }) void {
        const current = self.current orelse return std.log.info("{t}: open a project first; it changes the open project's Eggy", .{choice});
        switch (current) {
            .fetched => std.log.info("{t}: the project gets Eggy by URL, so its build.zig.zon picks the version", .{choice}),
            .linked => |codebase| if (choice == .upgrade)
                std.log.info("upgrade: the project is linked to the Eggy codebase at {s}, so it doesn't upgrade", .{codebase})
            else
                std.log.info("link: the project is already linked to {s}", .{codebase}),
            .packaged => if (choice == .upgrade) {
                if (self.check) |check| if (check.take()) |outcome| if (outcome.* == .failed) {
                    return std.log.info("upgrade: the project uses the newest Eggy unpacked; checking {s} failed: {s}", .{ check.text, outcome.failed });
                };
                std.log.info("upgrade: the project already uses the newest Eggy", .{});
            } else std.log.info("link: no Eggy checkout is recorded; run an editor built from your Eggy checkout once", .{}),
        }
    }

    /// Ask, over `window`, whether to link project `title` to the codebase being developed, with
    /// the warning that it can't be undone. Blocks until answered; false if it can't be shown.
    /// Desktop editor only: borrows the parent SDL window and title, returns only consent and
    /// performs no linking. Missing developer path, allocation failure or dialog failure returns
    /// false; dialog errors are logged.
    ///
    /// ```zig
    /// const approved = upgrades.confirmLink(app.window.window, "Space Game");
    /// // Existing Upgrades and editor App pointer; start a link job only if approved.
    /// ```
    pub fn confirmLink(self: *const Upgrades, window: sdl3.video.Window, title: []const u8) bool {
        // ponytail: blocks the editor's loop while the dialog is up; fine for a one-off question.
        const codebase = self.developer_dir orelse return false;
        var arena = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer arena.deinit();
        const message = std.fmt.allocPrintSentinel(arena.allocator(),
            \\Link {s} to the Eggy codebase at {s}?
            \\
            \\The project will build against that codebase from now on, with every change you make to it.
            \\
            \\This can't be undone: Upgrade Editor won't offer packaged versions of Eggy to it again.
        , .{ title, codebase }, 0) catch return false;
        const link_button = 1;
        const answer = sdl3.message_box.show(.{
            .flags = .{ .warning_dialog = true },
            .parent_window = window,
            .title = "Link Developer Eggy",
            .message = message,
            .buttons = &.{
                .{ .value = 0, .text = "Cancel", .flags = .{ .mark_default_with_escape_key = true } },
                .{ .value = link_button, .text = "Link", .flags = .{ .mark_default_with_return_key = true } },
            },
            .color_scheme = null,
        }) catch |err| {
            std.log.err("cannot ask whether to link the project: {t}", .{err});
            return false;
        };
        return answer == link_button;
    }
};

/// `commit` as Git abbreviates it, borrowed: its first 7 characters.
fn shortCommit(commit: []const u8) []const u8 {
    return commit[0..@min(7, commit.len)];
}

/// The commit `check` found, borrowed from it; null while it reads or when it failed.
fn remoteCommit(check: *eggy_source.Check) ?[]const u8 {
    const outcome = check.take() orelse return null;
    return switch (outcome.*) {
        .commit => |*commit| commit,
        .failed => null,
    };
}
