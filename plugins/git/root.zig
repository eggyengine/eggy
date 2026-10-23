//! Git, from the editor: a Git panel (changes, history, branches and tags, stashes, remotes), a
//! Git menu on the top bar, and the branch in the status bar with a menu of its own. A dev
//! plugin: it runs the `git` on PATH in the project's folder, and exported games leave it out.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const actions = @import("actions.zig");
const panel_zig = @import("panel.zig");
const Repo = @import("repo.zig").Repo;
const State = @import("status.zig").State;

/// The Git menu's rows, in order; `editorBarAction` and `editorBarState` switch on them.
const MenuRow = enum { open_panel, commit, stage_all, unstage_all, fetch, pull, push, stash, pop_stash, branches, history, refresh, create };
/// The status bar menu's rows.
const StatusRow = enum { open_panel, fetch, pull, push, refresh };

pub const Plugin = struct {
    /// The project's repository, opened by the first editor hook; null in the runtime.
    repo: ?*Repo = null,
    panel: panel_zig.Panel = .{},

    pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .key = "git", .title = "Git" }};
    pub const editor_menus = [_]eggy.plugins.EditorMenu{.{ .key = "git", .title = "Git", .items = &.{
        .{ .key = "open", .title = "Open Git Panel" },
        .{ .key = "commit", .title = "Commit..." },
        .{ .key = "stage_all", .title = "Stage All" },
        .{ .key = "unstage_all", .title = "Unstage All" },
        .{ .key = "fetch", .title = "Fetch" },
        .{ .key = "pull", .title = "Pull" },
        .{ .key = "push", .title = "Push" },
        .{ .key = "stash", .title = "Stash Changes" },
        .{ .key = "pop_stash", .title = "Pop Latest Stash" },
        .{ .key = "branches", .title = "Branches..." },
        .{ .key = "history", .title = "History..." },
        .{ .key = "refresh", .title = "Refresh" },
        .{ .key = "create", .title = "Create Repository" },
    } }};
    pub const editor_status_items = [_]eggy.plugins.EditorStatusItem{.{ .key = "branch", .title = "Git", .side = .left, .items = &.{
        .{ .key = "open", .title = "Open Git Panel" },
        .{ .key = "fetch", .title = "Fetch" },
        .{ .key = "pull", .title = "Pull" },
        .{ .key = "push", .title = "Push" },
        .{ .key = "refresh", .title = "Refresh" },
    } }};

    comptime {
        std.debug.assert(editor_menus[0].items.len == @typeInfo(MenuRow).@"enum".field_names.len);
        std.debug.assert(editor_status_items[0].items.len == @typeInfo(StatusRow).@"enum".field_names.len);
    }

    /// Stop any git command still running and close the repository.
    pub fn deinit(self: *Plugin) void {
        if (self.repo) |repo| repo.destroy();
        self.repo = null;
    }

    /// Open the repository once there is a project; take what git found, and read it again
    /// every few seconds.
    pub fn editorUpdate(self: *Plugin, editor: *eggy.editor.Context) !void {
        const repo = self.open(editor) orelse return;
        repo.update();
    }

    pub fn editorPanelUi(self: *Plugin, panel: usize, editor: *eggy.editor.Context, context: *ui.Context) !void {
        _ = panel;
        try self.panel.build(self.open(editor), context);
    }

    /// The status bar's branch and changes; the menus' rows greyed out when they can't run.
    pub fn editorBarState(self: *Plugin, target: eggy.plugins.EditorBarTarget, editor: *eggy.editor.Context, bar: *eggy.plugins.EditorBarState) !void {
        const repo = self.open(editor);
        const state: ?*const State = if (repo) |known| known.state else null;
        const idle = if (repo) |known| !known.busy else false;
        const ready = state != null and state.?.repository;
        switch (target) {
            .status => {
                const current = state orelse return;
                if (!current.repository) return bar.setText("Git: no repository");
                var buffer: [eggy.plugins.EditorBarState.max_text]u8 = undefined;
                const branch = if (current.detached) "detached" else current.branch;
                bar.setText(if (current.changes.len == 0)
                    std.fmt.bufPrint(&buffer, "Git: {s}", .{branch}) catch "Git"
                else
                    std.fmt.bufPrint(&buffer, "Git: {s} \u{2022} {d} changed", .{ branch, current.changes.len }) catch "Git");
            },
            .status_item => |row| bar.enabled = switch (@as(StatusRow, @fromBackingInt(@intCast(row.item)))) {
                .open_panel => true,
                .refresh => idle,
                .fetch, .pull, .push => idle and ready,
            },
            .menu_item => |row| bar.enabled = switch (@as(MenuRow, @fromBackingInt(@intCast(row.item)))) {
                .open_panel, .commit, .branches, .history => repo != null,
                .create => idle and state != null and !state.?.repository,
                .refresh => idle,
                .stage_all, .unstage_all, .stash => idle and ready and state.?.changes.len > 0,
                .pop_stash => idle and ready and state.?.stashes.len > 0,
                .fetch, .pull, .push => idle and ready,
            },
        }
    }

    pub fn editorBarAction(self: *Plugin, target: eggy.plugins.EditorBarTarget, editor: *eggy.editor.Context) !void {
        const repo = self.open(editor) orelse return;
        switch (target) {
            .status => try editor.showPanel("git"),
            .status_item => |row| switch (@as(StatusRow, @fromBackingInt(@intCast(row.item)))) {
                .open_panel => try editor.showPanel("git"),
                .fetch => self.runMenu(repo, .fetch),
                .pull => self.runMenu(repo, .pull),
                .push => self.runMenu(repo, .push),
                .refresh => repo.refresh(),
            },
            .menu_item => |row| {
                const chosen: MenuRow = @fromBackingInt(@intCast(row.item));
                switch (chosen) {
                    .open_panel => {},
                    .commit => self.panel.open(.changes),
                    .branches => self.panel.open(.branches),
                    .history => self.panel.open(.history),
                    else => return self.runMenu(repo, chosen),
                }
                try editor.showPanel("git");
            },
        }
    }

    /// Run the action a menu row stands for.
    fn runMenu(self: *Plugin, repo: *Repo, row: MenuRow) void {
        _ = self;
        if (row == .refresh) return repo.refresh();
        if (row == .create) return actions.init(repo);
        const state = repo.state orelse return;
        switch (row) {
            .stage_all => actions.stageAll(repo),
            .unstage_all => actions.unstageAll(repo, state),
            .fetch => actions.fetch(repo),
            .pull => actions.pull(repo),
            .push => actions.push(repo, state),
            .stash => actions.stash(repo, "", true),
            .pop_stash => if (state.stashes.len > 0) actions.popStash(repo, state.stashes[0].name),
            else => {},
        }
    }

    /// The repository, opened on the project's folder the first time a hook asks; null without
    /// a project, or when it can't be opened (logged once).
    fn open(self: *Plugin, editor: *eggy.editor.Context) ?*Repo {
        if (self.repo) |repo| return repo;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const folder = editor.projectFolder(arena.allocator()) catch return null;
        const process = editor.app.process_init;
        self.repo = Repo.create(process.gpa, process.environ_map, process.minimal.environ, folder) catch |err| {
            std.log.err("git: cannot open {s}: {t}", .{ folder, err });
            return null;
        };
        return self.repo;
    }
};

test {
    _ = @import("status.zig");
    _ = @import("repo.zig");
    _ = @import("diff_view.zig");
    _ = @import("panel.zig");
}

test "the plugin compiles" {
    std.testing.refAllDecls(Plugin);
}
