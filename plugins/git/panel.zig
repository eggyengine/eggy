//! The Git panel: the branch and the buttons that talk to remotes across the top, then tabs for
//! the changes (stage, discard, resolve, commit), History, Branches (and tags), Stashes and
//! Remotes (and who commits). Pressing a row shows its diff under it.
const std = @import("std");
const ui = @import("eggy").ui;
const status = @import("status.zig");
const repo_zig = @import("repo.zig");
const Repo = repo_zig.Repo;
const actions = @import("actions.zig");
const icons = @import("icons.zig");
const list_row = @import("list_row.zig");
const diff_view = @import("diff_view.zig");
const State = status.State;

pub const Tab = enum { changes, history, branches, stashes, remotes };

/// What the panel remembers between frames.
pub const Panel = struct {
    tab: usize = 0,
    message: ui.TextEdit(1024) = ui.TextEdit(1024).init("") catch unreachable,
    amend: bool = false,
    name: ui.TextEdit(128) = ui.TextEdit(128).init("") catch unreachable,
    stash_message: ui.TextEdit(256) = ui.TextEdit(256).init("") catch unreachable,
    stash_untracked: bool = true,
    remote_name: ui.TextEdit(64) = ui.TextEdit(64).init("") catch unreachable,
    remote_url: ui.TextEdit(512) = ui.TextEdit(512).init("") catch unreachable,
    user_name: ui.TextEdit(128) = ui.TextEdit(128).init("") catch unreachable,
    user_email: ui.TextEdit(128) = ui.TextEdit(128).init("") catch unreachable,
    /// Who commits was read into the fields above.
    identity_loaded: bool = false,
    /// The row whose diff shows (see `selectionKey`), empty for none.
    selected_buffer: [512]u8 = undefined,
    selected_len: usize = 0,
    armed: icons.Armed = .{},

    /// Show tab `tab` next.
    pub fn open(self: *Panel, tab: Tab) void {
        self.tab = @backingInt(tab);
    }

    /// Build the panel for `repo` (null without a project) on `context`.
    pub fn build(self: *Panel, repo: ?*Repo, context: *ui.Context) !void {
        const known = repo orelse return context.muted("Open a project to use Git.");
        const state = known.state orelse return context.muted("Reading the repository...");
        if (!state.repository) {
            context.muted("This project isn't a Git repository yet.");
            if (context.button("Create Repository") and !known.busy) actions.init(known);
            return report(known, context);
        }
        try self.buildHeader(known, state, context);
        report(known, context);
        if (state.operation != .none) buildOperation(known, state, context);

        // The tabs, each with how many it holds.
        const arena = context.builder().allocator;
        var locals: usize = 0;
        for (state.branches) |branch| locals += @intFromBool(!branch.remote);
        const labels = [_][]const u8{
            try std.fmt.allocPrint(arena, "Changes {d}##changes", .{state.changes.len}),
            "History##history",
            try std.fmt.allocPrint(arena, "Branches {d}##branches", .{locals}),
            try std.fmt.allocPrint(arena, "Stashes {d}##stashes", .{state.stashes.len}),
            try std.fmt.allocPrint(arena, "Remotes {d}##remotes", .{state.remotes.len}),
        };
        if (context.tabs(&labels, &self.tab)) self.select(known, "");
        switch (@as(Tab, @fromBackingInt(@intCast(self.tab)))) {
            .changes => try self.buildChanges(known, state, context),
            .history => try self.buildHistory(known, state, context),
            .branches => try self.buildBranches(known, state, context),
            .stashes => try self.buildStashes(known, state, context),
            .remotes => try self.buildRemotes(known, state, context),
        }
    }

    /// The branch, how far it is from its upstream, and fetch, pull, push and refresh.
    fn buildHeader(self: *Panel, repo: *Repo, state: *const State, context: *ui.Context) !void {
        _ = self;
        const arena = context.builder().allocator;
        const idle = !repo.busy;
        context.begin(.row);
        icons.mark(context, .branch, 14, .primary);
        list_row.clippedText(context, if (state.detached) "Detached HEAD" else state.branch, .foreground);
        if (state.ahead > 0) {
            icons.mark(context, .push, 12, .muted);
            context.muted(try std.fmt.allocPrint(arena, "{d}", .{state.ahead}));
        }
        if (state.behind > 0) {
            icons.mark(context, .pull, 12, .muted);
            context.muted(try std.fmt.allocPrint(arena, "{d}", .{state.behind}));
        }
        if (repo.busy) {
            context.spinner();
            restyle(context, .{ .width = 16, .height = 16 });
            context.muted(repo.running);
        }
        if (icons.button(context, "git-fetch", .fetch, "Fetch from every remote", idle)) actions.fetch(repo);
        if (icons.button(context, "git-pull", .pull, "Pull", idle and state.upstream.len > 0)) actions.pull(repo);
        if (icons.button(context, "git-push", .push, "Push", idle and !state.detached and !state.unborn)) actions.push(repo, state);
        if (icons.button(context, "git-refresh", .refresh, "Read the repository again", idle)) repo.refresh();
        endRow(context);
    }

    // Changes.

    fn buildChanges(self: *Panel, repo: *Repo, state: *const State, context: *ui.Context) !void {
        const arena = context.builder().allocator;
        const idle = !repo.busy;
        const counts = state.counts();

        // The commit: its message, Amend, and Commit.
        context.begin(.row);
        _ = context.textInput("##git-message", &self.message, if (self.amend) "Message (empty keeps the last one)" else "Commit message");
        restyle(context, .{ .grow = 1 });
        if (icons.button(context, "git-commit", .check, if (self.amend) "Amend the last commit" else "Commit the staged changes", idle)) self.commit(repo, counts.staged);
        endRow(context);
        context.begin(.row);
        _ = context.checkbox("Amend last commit", &self.amend);
        endRow(context);

        // Conflicts, until each is resolved.
        if (counts.conflicted > 0) {
            section(context, try std.fmt.allocPrint(arena, "Conflicts {d}", .{counts.conflicted}));
            endRow(context);
            for (state.changes) |change| if (change.isConflicted()) {
                const key = try selectionKey(arena, 'u', change.path);
                context.begin(.row);
                if (list_row.add(context, key, fileRow(change, '!', .removed, self.isSelected(key)))) self.toggle(repo, key);
                if (icons.button(context, try id(arena, "git-ours", change.path), .reset, "Keep ours: the version on this branch", idle)) actions.resolve(repo, change.path, .ours);
                if (icons.button(context, try id(arena, "git-theirs", change.path), .switch_to, "Keep theirs: the incoming version", idle)) actions.resolve(repo, change.path, .theirs);
                if (icons.button(context, try id(arena, "git-resolved", change.path), .check, "Mark resolved, as the file is now", idle)) actions.markResolved(repo, change.path);
                endRow(context);
                if (self.isSelected(key)) {
                    actions.showChange(repo, change, false, key);
                    showDiff(repo, key, context);
                }
            };
        }

        // Staged, then not.
        section(context, try std.fmt.allocPrint(arena, "Staged {d}", .{counts.staged}));
        if (icons.button(context, "git-unstage-all", .minus, "Unstage everything", idle and counts.staged > 0)) actions.unstageAll(repo, state);
        endRow(context);
        for (state.changes) |change| if (change.isStaged()) try self.changeRow(repo, state, change, true, context);

        section(context, try std.fmt.allocPrint(arena, "Changes {d}", .{counts.unstaged}));
        if (icons.dangerButton(context, "git-discard-all", .discard, "Discard every change", idle and counts.unstaged > 0, &self.armed)) actions.discardAll(repo, state);
        if (icons.button(context, "git-stage-all", .plus, "Stage everything", idle and counts.unstaged > 0)) actions.stageAll(repo);
        endRow(context);
        for (state.changes) |change| if (change.isUnstaged()) try self.changeRow(repo, state, change, false, context);
        if (state.changes.len == 0) context.muted("Nothing changed since the last commit.");
    }

    fn changeRow(self: *Panel, repo: *Repo, state: *const State, change: status.Change, staged: bool, context: *ui.Context) !void {
        const arena = context.builder().allocator;
        const idle = !repo.busy;
        const key = try selectionKey(arena, if (staged) 's' else 'w', change.path);
        const letter = change.letter(staged);
        context.begin(.row);
        if (list_row.add(context, key, fileRow(change, letter, letterTone(letter), self.isSelected(key)))) self.toggle(repo, key);
        if (staged) {
            if (icons.button(context, try id(arena, "git-unstage", change.path), .minus, "Unstage", idle)) actions.unstage(repo, state, change.path);
        } else {
            if (icons.dangerButton(context, try id(arena, "git-discard", change.path), .discard, if (change.isUntracked()) "Delete this new file" else "Discard the changes", idle, &self.armed)) actions.discard(repo, change);
            if (icons.button(context, try id(arena, "git-stage", change.path), .plus, "Stage", idle)) actions.stage(repo, change.path);
        }
        endRow(context);
        if (self.isSelected(key)) {
            actions.showChange(repo, change, staged, key);
            showDiff(repo, key, context);
        }
    }

    fn commit(self: *Panel, repo: *Repo, staged: usize) void {
        const message = std.mem.trim(u8, self.message.text(), " \t\r\n");
        if (!self.amend and staged == 0) return repo.say("Commit", "Stage the changes to commit first.", true);
        if (!self.amend and message.len == 0) return repo.say("Commit", "Write what the commit changes first.", true);
        actions.commit(repo, message, self.amend);
        self.message.set("") catch {};
        self.amend = false;
    }

    // History.

    fn buildHistory(self: *Panel, repo: *Repo, state: *const State, context: *ui.Context) !void {
        const arena = context.builder().allocator;
        const idle = !repo.busy;
        if (state.log.len == 0) return context.muted("No commits yet.");
        for (state.log) |entry| {
            const key = try selectionKey(arena, 'c', entry.full_hash);
            const selected = self.isSelected(key);
            context.begin(.row);
            if (list_row.add(context, key, .{ .lead = entry.hash, .name = entry.subject, .accent = entry.refs, .note = try std.fmt.allocPrint(arena, "{s}, {s}", .{ entry.author, entry.when }), .selected = selected })) self.toggle(repo, key);
            endRow(context);
            if (!selected) continue;

            // What can be done with it, then what it changed.
            context.begin(.row);
            _ = context.textInput("##git-commit-name", &self.name, "Branch or tag name");
            restyle(context, .{ .grow = 1 });
            const name = std.mem.trim(u8, self.name.text(), " ");
            if (icons.button(context, "git-branch-here", .branch, "New branch here, and switch to it", idle and name.len > 0)) {
                actions.createBranch(repo, name, entry.full_hash);
                self.name.set("") catch {};
            }
            if (icons.button(context, "git-tag-here", .tag, "Tag this commit", idle and name.len > 0)) {
                actions.createTag(repo, name, entry.full_hash);
                self.name.set("") catch {};
            }
            endRow(context);
            context.begin(.row);
            if (icons.button(context, "git-checkout", .switch_to, "Check out this commit (no branch)", idle)) actions.checkoutCommit(repo, entry.full_hash);
            if (icons.button(context, "git-cherry-pick", .cherry_pick, "Cherry-pick onto the current branch", idle)) actions.cherryPick(repo, entry.full_hash);
            if (icons.button(context, "git-revert", .discard, "Revert: a new commit undoing this one", idle)) actions.revert(repo, entry.full_hash);
            if (icons.button(context, "git-reset-soft", .reset, "Reset the branch here, keeping the changes since", idle)) actions.reset(repo, entry.full_hash, .mixed);
            if (icons.dangerButton(context, "git-reset-hard", .trash, "Reset the branch here, throwing away every change since", idle, &self.armed)) actions.reset(repo, entry.full_hash, .hard);
            endRow(context);
            actions.showCommit(repo, entry.full_hash, key);
            showDiff(repo, key, context);
        }
    }

    // Branches and tags.

    fn buildBranches(self: *Panel, repo: *Repo, state: *const State, context: *ui.Context) !void {
        const arena = context.builder().allocator;
        const idle = !repo.busy;

        // A new branch or tag, at the current commit.
        context.begin(.row);
        _ = context.textInput("##git-new-name", &self.name, "New branch or tag name");
        restyle(context, .{ .grow = 1 });
        const name = std.mem.trim(u8, self.name.text(), " ");
        if (icons.button(context, "git-new-branch", .branch, "New branch here, and switch to it", idle and name.len > 0)) {
            actions.createBranch(repo, name, "");
            self.name.set("") catch {};
        }
        if (icons.button(context, "git-new-tag", .tag, "Tag the current commit", idle and name.len > 0 and !state.unborn)) {
            actions.createTag(repo, name, "");
            self.name.set("") catch {};
        }
        endRow(context);

        for ([_]bool{ false, true }) |remote| {
            section(context, if (remote) "Remote" else "Local");
            endRow(context);
            for (state.branches) |branch| if (branch.remote == remote) {
                const key = try selectionKey(arena, 'b', branch.name);
                context.begin(.row);
                const note = if (branch.gone)
                    "upstream gone"
                else if (branch.ahead + branch.behind > 0)
                    try std.fmt.allocPrint(arena, "{d} ahead, {d} behind", .{ branch.ahead, branch.behind })
                else
                    "";
                if (list_row.add(context, key, .{ .mark = if (branch.current) .check else null, .name = branch.name, .detail = branch.subject, .note = note, .selected = self.isSelected(key) })) self.toggle(repo, key);
                if (!branch.current) {
                    if (icons.button(context, try id(arena, "git-switch", branch.name), .switch_to, "Switch to it", idle)) actions.switchTo(repo, state, branch);
                    if (icons.button(context, try id(arena, "git-merge", branch.name), .merge, "Merge it into the current branch", idle and !state.detached)) actions.merge(repo, branch.name);
                    if (icons.button(context, try id(arena, "git-rebase", branch.name), .rebase, "Rebase the current branch onto it", idle and !state.detached)) actions.rebase(repo, branch.name);
                    if (icons.dangerButton(context, try id(arena, "git-delete", branch.name), .trash, if (remote) "Delete it on its remote" else "Delete it", idle, &self.armed)) actions.deleteBranch(repo, branch);
                }
                endRow(context);
                if (self.isSelected(key)) {
                    actions.showCommit(repo, branch.name, key);
                    showDiff(repo, key, context);
                }
            };
        }

        section(context, "Tags");
        endRow(context);
        if (state.tags.len == 0) context.muted("No tags yet.");
        for (state.tags) |tag| {
            const key = try selectionKey(arena, 't', tag.name);
            context.begin(.row);
            if (list_row.add(context, key, .{ .mark = .tag, .name = tag.name, .detail = tag.subject, .note = tag.commit, .selected = self.isSelected(key) })) self.toggle(repo, key);
            if (icons.button(context, try id(arena, "git-push-tag", tag.name), .push, "Push the tag", idle and state.remotes.len > 0)) actions.pushTag(repo, state, tag.name);
            if (icons.dangerButton(context, try id(arena, "git-delete-tag", tag.name), .trash, "Delete the tag here", idle, &self.armed)) actions.deleteTag(repo, tag.name);
            endRow(context);
            if (self.isSelected(key)) {
                actions.showCommit(repo, tag.name, key);
                showDiff(repo, key, context);
            }
        }
    }

    // Stashes.

    fn buildStashes(self: *Panel, repo: *Repo, state: *const State, context: *ui.Context) !void {
        const arena = context.builder().allocator;
        const idle = !repo.busy;
        context.begin(.row);
        _ = context.textInput("##git-stash-message", &self.stash_message, "Stash message (optional)");
        restyle(context, .{ .grow = 1 });
        if (icons.button(context, "git-stash", .stash, "Stash the changes", idle and state.changes.len > 0)) {
            actions.stash(repo, std.mem.trim(u8, self.stash_message.text(), " "), self.stash_untracked);
            self.stash_message.set("") catch {};
        }
        endRow(context);
        context.begin(.row);
        _ = context.checkbox("Include new files", &self.stash_untracked);
        endRow(context);

        if (state.stashes.len == 0) return context.muted("No stashes.");
        for (state.stashes) |stash| {
            const key = try selectionKey(arena, 'z', stash.name);
            context.begin(.row);
            if (list_row.add(context, key, .{ .lead = stash.name, .name = stash.subject, .selected = self.isSelected(key) })) self.toggle(repo, key);
            if (icons.button(context, try id(arena, "git-pop", stash.name), .unstash, "Pop: apply it and drop it", idle)) actions.popStash(repo, stash.name);
            if (icons.button(context, try id(arena, "git-apply", stash.name), .plus, "Apply it, keeping it", idle)) actions.applyStash(repo, stash.name);
            if (icons.dangerButton(context, try id(arena, "git-drop", stash.name), .trash, "Drop it", idle, &self.armed)) actions.dropStash(repo, stash.name);
            endRow(context);
            if (self.isSelected(key)) {
                actions.showStash(repo, stash.name, key);
                showDiff(repo, key, context);
            }
        }
    }

    // Remotes and identity.

    fn buildRemotes(self: *Panel, repo: *Repo, state: *const State, context: *ui.Context) !void {
        const arena = context.builder().allocator;
        const idle = !repo.busy;
        if (state.remotes.len == 0) context.muted("No remotes: add one to push and pull.");
        for (state.remotes) |remote| {
            context.begin(.row);
            _ = list_row.add(context, try id(arena, "git-remote", remote.name), .{ .name = remote.name, .detail = remote.url });
            if (icons.button(context, try id(arena, "git-fetch-remote", remote.name), .fetch, "Fetch from it", idle)) actions.fetchRemote(repo, remote.name);
            if (icons.dangerButton(context, try id(arena, "git-remove-remote", remote.name), .trash, "Remove it", idle, &self.armed)) actions.removeRemote(repo, remote.name);
            endRow(context);
        }
        context.begin(.row);
        _ = context.textInput("##git-remote-name", &self.remote_name, "Name");
        restyle(context, .{ .width = 90 });
        _ = context.textInput("##git-remote-url", &self.remote_url, "https://github.com/me/game.git");
        restyle(context, .{ .grow = 1 });
        const name = std.mem.trim(u8, self.remote_name.text(), " ");
        const url = std.mem.trim(u8, self.remote_url.text(), " ");
        if (icons.button(context, "git-add-remote", .plus, "Add the remote", idle and name.len > 0 and url.len > 0)) {
            actions.addRemote(repo, name, url);
            self.remote_name.set("") catch {};
            self.remote_url.set("") catch {};
        }
        endRow(context);

        // Who this repository's commits are by.
        section(context, "Identity");
        endRow(context);
        if (!self.identity_loaded) {
            self.user_name.set(state.user_name) catch {};
            self.user_email.set(state.user_email) catch {};
            self.identity_loaded = true;
        }
        context.begin(.row);
        _ = context.textInput("##git-user-name", &self.user_name, "Your name");
        restyle(context, .{ .grow = 1 });
        _ = context.textInput("##git-user-email", &self.user_email, "you@example.com");
        restyle(context, .{ .grow = 1 });
        const user_name = std.mem.trim(u8, self.user_name.text(), " ");
        const user_email = std.mem.trim(u8, self.user_email.text(), " ");
        const changed = !std.mem.eql(u8, user_name, state.user_name) or !std.mem.eql(u8, user_email, state.user_email);
        if (icons.button(context, "git-identity", .check, "Save, for this repository", idle and changed and user_name.len > 0 and user_email.len > 0)) actions.setIdentity(repo, user_name, user_email);
        endRow(context);
    }

    // Selection: the row whose diff shows.

    fn isSelected(self: *const Panel, key: []const u8) bool {
        return std.mem.eql(u8, self.selected_buffer[0..self.selected_len], key);
    }

    /// Select the row `key`, or nothing when it already is.
    fn toggle(self: *Panel, repo: *Repo, key: []const u8) void {
        self.select(repo, if (self.isSelected(key)) "" else key);
    }

    fn select(self: *Panel, repo: *Repo, key: []const u8) void {
        const len = @min(key.len, self.selected_buffer.len);
        @memcpy(self.selected_buffer[0..len], key[0..len]);
        self.selected_len = len;
        if (len == 0) repo.hideDiff();
    }
};

/// What was being done when git stopped for conflicts, with Continue and Abort.
fn buildOperation(repo: *Repo, state: *const State, context: *ui.Context) void {
    const idle = !repo.busy;
    const conflicted = state.counts().conflicted;
    context.begin(.row);
    context.text(state.operation.title());
    list_row.clippedText(context, if (conflicted > 0) "Resolve the conflicts, then continue." else "Continue when ready.", .muted);
    if (icons.button(context, "git-continue", .check, "Continue", idle and conflicted == 0)) actions.continueOperation(repo, state.operation);
    if (icons.button(context, "git-abort", .x, "Abort, going back to before it started", idle)) actions.abortOperation(repo, state.operation);
    endRow(context);
}

/// The last command's output: an alert when it failed, a note when it said something.
fn report(repo: *Repo, context: *ui.Context) void {
    // Copied: a command started later this frame replaces the report.
    const arena = context.builder().allocator;
    const last = repo_zig.Report{ .title = arena.dupe(u8, repo.report.title) catch "", .output = arena.dupe(u8, repo.report.output) catch "", .failed = repo.report.failed };
    if (last.output.len == 0) return;
    if (last.failed) {
        context.alert(std.fmt.allocPrint(arena, "{s} failed", .{last.title}) catch last.title, last.output, true);
    } else {
        context.muted(last.output);
        restyleText(context, context.theme.small_text_size - 1);
    }
}

/// The diff of row `key`, once read.
fn showDiff(repo: *Repo, key: []const u8, context: *ui.Context) void {
    const diff = repo.diff orelse return context.muted("Reading...");
    if (!std.mem.eql(u8, diff.key, key)) return context.muted("Reading...");
    if (diff.lines.len == 1 and diff.text.len == 0) return context.muted("No differences.");
    diff_view.add(context, diff);
}

/// A file's row: its name, then the folder it is in.
fn fileRow(change: status.Change, letter: u8, tone: icons.Tone, selected: bool) list_row.Row {
    const slash = std.mem.lastIndexOfScalar(u8, std.mem.trimEnd(u8, change.path, "/"), '/');
    return .{
        .letter = letter,
        .letter_tone = tone,
        .name = if (slash) |at| change.path[at + 1 ..] else change.path,
        .detail = if (slash) |at| change.path[0..at] else "",
        .selected = selected,
    };
}

fn letterTone(letter: u8) icons.Tone {
    return switch (letter) {
        'A', 'U', '?' => .added,
        'D' => .removed,
        else => .primary,
    };
}

/// A key naming a row: its kind (`kind`), then what it is.
fn selectionKey(arena: std.mem.Allocator, kind: u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "git-row-{c}:{s}", .{ kind, name });
}

fn id(arena: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}:{s}", .{ prefix, name });
}

/// A small heading over a list, opening a row its buttons go in; close it with `endRow`.
fn section(context: *ui.Context, title: []const u8) void {
    context.begin(.row);
    context.muted(title);
    spacer(context);
}

/// Fill the rest of the row, pushing what follows to its right.
fn spacer(context: *ui.Context) void {
    context.begin(.row);
    context.end();
    restyle(context, .{ .grow = 1, .height = 1 });
    if (context.last_added) |element| element.id = 0;
}

/// Close a row, its items centred across it a few points apart.
fn endRow(context: *ui.Context) void {
    context.end();
    restyle(context, .{ .gap = 4 });
    if (context.last_added) |element| {
        element.style.align_items = .center;
        // A row only lays out its items; presses go to them.
        element.id = 0;
    }
}

/// Restyle the element `context` added last.
fn restyle(context: *ui.Context, layout: struct { width: ?f32 = null, height: ?f32 = null, grow: ?f32 = null, gap: ?f32 = null }) void {
    const element = context.last_added orelse return;
    if (layout.width) |width| element.style.width = width;
    if (layout.height) |height| element.style.height = height;
    if (layout.grow) |grow| element.style.grow = grow;
    if (layout.gap) |gap| element.style.gap = gap;
    element.style.wrap = false;
    element.style.max_width = null;
}

fn restyleText(context: *ui.Context, size: f32) void {
    const element = context.last_added orelse return;
    if (element.paint_kind == .text) element.paint_kind.text.size = size;
}

test "every tab fits a narrow panel, a row's diff open under it" {
    const gpa = std.testing.allocator;
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    const no_environ: std.process.Environ = if (@import("builtin").os.tag == .windows) .{ .block = .global } else .{ .block = .{ .slice = &.{} } };
    const repo = try Repo.create(gpa, &environ, no_environ, "/nowhere");
    defer repo.destroy();

    // A repository with a bit of everything, mid-merge.
    const state = try gpa.create(State);
    state.* = .{ .arena = .init(gpa), .operation = .merging };
    repo.state = state;
    const a = state.arena.allocator();
    try status.parseStatus(a, state, "## feature/a-rather-long-branch-name...origin/feature/a-rather-long-branch-name [ahead 2, behind 1]\nM  src/main.zig\n M resources/scene/a/very/deep/folder/with/a/long/path/start.scene.zon\n?? notes.txt\nUU build.zig\n");
    try status.parseRefs(a, state, "*\trefs/heads/main\torigin/main\tahead 1\tabc1234\tFix\n \trefs/remotes/origin/main\t\t\tabc1234\tFix\n \trefs/tags/v1.0.0\t\t\tabc1234\tRelease\n");
    try status.parseLog(a, state, "abc1234\tabc1234ff\tSomeone With A Long Name\t3 weeks ago\tHEAD -> main, origin/main, tag: v1.0.0\tA commit whose subject goes on for quite a while\n");
    try status.parseStashes(a, state, "stash@{0}\tOn main: halfway through\n");
    try status.parseRemotes(a, state, "origin\thttps://github.com/someone/a-game-with-a-long-name.git (fetch)\n");
    repo.say("Push", "fatal: the remote end hung up unexpectedly", true);

    // The selected row's diff, as read.
    const diff = try gpa.create(repo_zig.Diff);
    diff.* = .{ .arena = .init(gpa), .key = "", .text = "", .lines = &.{} };
    repo.diff = diff;

    var panel = Panel{};
    for ([_]f32{ 300, 640 }) |width| for (std.enums.values(Tab)) |tab| {
        panel.open(tab);
        const key = switch (tab) {
            .changes => "git-row-w:resources/scene/a/very/deep/folder/with/a/long/path/start.scene.zon",
            .history => "git-row-c:abc1234ff",
            .branches => "git-row-b:main",
            .stashes => "git-row-z:stash@{0}",
            // Nothing on the page: a selection kept from another tab.
            .remotes => "git-row-r:none",
        };
        panel.select(repo, key);
        diff.key = key;
        diff.text = "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new";
        diff.lines = &.{ .{ .start = 0, .end = 18 }, .{ .start = 19, .end = 30 }, .{ .start = 31, .end = 35 }, .{ .start = 36, .end = 40 } };
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = width, .h = 800 };
        context.newFrame(viewport);
        try panel.build(repo, &context);
        _ = try context.render();
        try expectInside(context.last_root.?, viewport);
    };
    // The test's diff isn't the repository's to free.
    diff.arena.deinit();
    gpa.destroy(diff);
    repo.diff = null;
}

/// Fail if an element of `element` reaches past `viewport`'s sides, outside a scrolling one.
fn expectInside(element: *const ui.Layout.Element, viewport: ui.Rect) !void {
    const box = element.bounds;
    if (box.w > 0 and (box.x < viewport.x - 0.5 or box.x + box.w > viewport.x + viewport.w + 0.5)) {
        std.debug.print("{t} at x {d:.1}, {d:.1} wide, leaves the {d:.0}-wide panel\n", .{ element.paint_kind, box.x, box.w, viewport.w });
        return error.ElementOutsideWindow;
    }
    // What scrolls (the tab bar, when narrow) may run past the panel.
    if (element.style.overflow == .scroll) return;
    for (element.children) |child| try expectInside(child, viewport);
}
