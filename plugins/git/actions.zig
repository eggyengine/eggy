//! What each Git action runs, shared by the Git panel and the Git menu. Each starts the action on
//! the repository's worker (nothing happens while another runs) and reads the repository again
//! after it.
const std = @import("std");
const status = @import("status.zig");
const Repo = @import("repo.zig").Repo;
const State = status.State;
const Change = status.Change;

pub fn init(repo: *Repo) void {
    repo.run("Create repository", &.{&.{ "git", "init" }});
}

pub fn fetch(repo: *Repo) void {
    repo.run("Fetch", &.{&.{ "git", "fetch", "--all", "--prune" }});
}

pub fn fetchRemote(repo: *Repo, remote: []const u8) void {
    repo.run("Fetch", &.{&.{ "git", "fetch", "--prune", remote }});
}

pub fn pull(repo: *Repo) void {
    repo.run("Pull", &.{&.{ "git", "pull", "--no-edit" }});
}

/// Push the branch; one without an upstream gets one on the push remote.
pub fn push(repo: *Repo, state: *const State) void {
    if (state.upstream.len == 0) {
        const remote = state.pushRemote() orelse return repo.say("Push", "The repository has no remote to push to. Add one under Remotes.", true);
        return repo.run("Push", &.{&.{ "git", "push", "-u", remote, state.branch }});
    }
    repo.run("Push", &.{&.{ "git", "push" }});
}

pub fn stage(repo: *Repo, path: []const u8) void {
    repo.run("Stage", &.{&.{ "git", "add", "-A", "--", path }});
}

pub fn stageAll(repo: *Repo) void {
    repo.run("Stage all", &.{&.{ "git", "add", "-A" }});
}

pub fn unstage(repo: *Repo, state: *const State, path: []const u8) void {
    // Before the first commit there is nothing to restore from: take it out of the index.
    if (state.unborn) return repo.run("Unstage", &.{&.{ "git", "rm", "--cached", "-r", "-q", "--", path }});
    repo.run("Unstage", &.{&.{ "git", "restore", "--staged", "--", path }});
}

pub fn unstageAll(repo: *Repo, state: *const State) void {
    if (state.unborn) return repo.run("Unstage all", &.{&.{ "git", "rm", "--cached", "-r", "-q", "." }});
    repo.run("Unstage all", &.{&.{ "git", "restore", "--staged", "." }});
}

/// Throw away `change`'s unstaged edits; an untracked file is deleted.
pub fn discard(repo: *Repo, change: Change) void {
    if (change.isUntracked()) return repo.run("Discard", &.{&.{ "git", "clean", "-f", "-q", "--", change.path }});
    repo.run("Discard", &.{&.{ "git", "restore", "--worktree", "--", change.path }});
}

/// Throw away every unstaged edit, and delete untracked files (not ignored ones).
pub fn discardAll(repo: *Repo, state: *const State) void {
    if (state.unborn) return repo.run("Discard all", &.{&.{ "git", "clean", "-f", "-d", "-q" }});
    repo.run("Discard all", &.{ &.{ "git", "restore", "--worktree", "." }, &.{ "git", "clean", "-f", "-d", "-q" } });
}

/// Resolve a conflict by keeping one side (`ours` or `theirs`) and marking it resolved.
pub fn resolve(repo: *Repo, path: []const u8, side: enum { ours, theirs }) void {
    const flag = switch (side) {
        .ours => "--ours",
        .theirs => "--theirs",
    };
    repo.run("Resolve", &.{ &.{ "git", "checkout", flag, "--", path }, &.{ "git", "add", "--", path } });
}

/// Mark a conflict resolved, as the file is now.
pub fn markResolved(repo: *Repo, path: []const u8) void {
    repo.run("Mark resolved", &.{&.{ "git", "add", "--", path }});
}

/// Commit what is staged with `message`; `amend` replaces the last commit (keeping its message
/// when `message` is empty).
pub fn commit(repo: *Repo, message: []const u8, amend: bool) void {
    if (amend and message.len == 0) return repo.run("Amend", &.{&.{ "git", "commit", "--amend", "--no-edit" }});
    if (amend) return repo.run("Amend", &.{&.{ "git", "commit", "--amend", "-m", message }});
    repo.run("Commit", &.{&.{ "git", "commit", "-m", message }});
}

pub fn continueOperation(repo: *Repo, operation: status.Operation) void {
    repo.run("Continue", &.{&.{ "git", operation.command(), "--continue" }});
}

pub fn abortOperation(repo: *Repo, operation: status.Operation) void {
    repo.run("Abort", &.{&.{ "git", operation.command(), "--abort" }});
}

/// Switch to a local branch, or to a remote one through a new local branch tracking it.
pub fn switchTo(repo: *Repo, state: *const State, branch: status.Branch) void {
    if (!branch.remote) return repo.run("Switch branch", &.{&.{ "git", "switch", branch.name }});
    // A local branch of that name already exists: switch to it.
    const local = branch.name[(std.mem.indexOfScalar(u8, branch.name, '/') orelse return) + 1 ..];
    for (state.branches) |other| if (!other.remote and std.mem.eql(u8, other.name, local)) return repo.run("Switch branch", &.{&.{ "git", "switch", local }});
    repo.run("Switch branch", &.{&.{ "git", "switch", "--track", branch.name }});
}

/// Make branch `name` at `start` (a commit; HEAD when empty) and switch to it.
pub fn createBranch(repo: *Repo, name: []const u8, start: []const u8) void {
    if (start.len == 0) return repo.run("New branch", &.{&.{ "git", "switch", "-c", name }});
    repo.run("New branch", &.{&.{ "git", "switch", "-c", name, start }});
}

/// Delete a branch, merged or not; a remote one is deleted on its remote.
pub fn deleteBranch(repo: *Repo, branch: status.Branch) void {
    if (!branch.remote) return repo.run("Delete branch", &.{&.{ "git", "branch", "-D", branch.name }});
    const slash = std.mem.indexOfScalar(u8, branch.name, '/') orelse return;
    repo.run("Delete remote branch", &.{&.{ "git", "push", branch.name[0..slash], "--delete", branch.name[slash + 1 ..] }});
}

pub fn merge(repo: *Repo, branch: []const u8) void {
    repo.run("Merge", &.{&.{ "git", "merge", "--no-edit", branch }});
}

pub fn rebase(repo: *Repo, onto: []const u8) void {
    repo.run("Rebase", &.{&.{ "git", "rebase", onto }});
}

/// Check out a commit by itself, leaving no branch checked out.
pub fn checkoutCommit(repo: *Repo, hash: []const u8) void {
    repo.run("Check out commit", &.{&.{ "git", "switch", "--detach", hash }});
}

pub fn revert(repo: *Repo, hash: []const u8) void {
    repo.run("Revert", &.{&.{ "git", "revert", "--no-edit", hash }});
}

pub fn cherryPick(repo: *Repo, hash: []const u8) void {
    repo.run("Cherry-pick", &.{&.{ "git", "cherry-pick", hash }});
}

pub const ResetMode = enum {
    /// Keep the changes, staged.
    soft,
    /// Keep the changes, unstaged.
    mixed,
    /// Throw the changes away.
    hard,
};

pub fn reset(repo: *Repo, hash: []const u8, mode: ResetMode) void {
    const flag = switch (mode) {
        .soft => "--soft",
        .mixed => "--mixed",
        .hard => "--hard",
    };
    repo.run("Reset", &.{&.{ "git", "reset", flag, hash }});
}

/// Tag `target` (HEAD when empty) as `name`.
pub fn createTag(repo: *Repo, name: []const u8, target: []const u8) void {
    if (target.len == 0) return repo.run("New tag", &.{&.{ "git", "tag", name }});
    repo.run("New tag", &.{&.{ "git", "tag", name, target }});
}

pub fn deleteTag(repo: *Repo, name: []const u8) void {
    repo.run("Delete tag", &.{&.{ "git", "tag", "-d", name }});
}

pub fn pushTag(repo: *Repo, state: *const State, name: []const u8) void {
    const remote = state.pushRemote() orelse return repo.say("Push tag", "The repository has no remote to push to. Add one under Remotes.", true);
    var buffer: [256]u8 = undefined;
    const ref = std.fmt.bufPrint(&buffer, "refs/tags/{s}", .{name}) catch return repo.say("Push tag", "The tag's name is too long.", true);
    repo.run("Push tag", &.{&.{ "git", "push", remote, ref }});
}

/// Stash the changes as `message` (git's own when empty), with untracked files when
/// `untracked`.
pub fn stash(repo: *Repo, message: []const u8, untracked: bool) void {
    const with = if (untracked) "--include-untracked" else "--no-keep-index";
    if (message.len == 0) return repo.run("Stash", &.{&.{ "git", "stash", "push", with }});
    repo.run("Stash", &.{&.{ "git", "stash", "push", with, "-m", message }});
}

pub fn popStash(repo: *Repo, name: []const u8) void {
    repo.run("Pop stash", &.{&.{ "git", "stash", "pop", name }});
}

pub fn applyStash(repo: *Repo, name: []const u8) void {
    repo.run("Apply stash", &.{&.{ "git", "stash", "apply", name }});
}

pub fn dropStash(repo: *Repo, name: []const u8) void {
    repo.run("Drop stash", &.{&.{ "git", "stash", "drop", name }});
}

pub fn addRemote(repo: *Repo, name: []const u8, url: []const u8) void {
    repo.run("Add remote", &.{&.{ "git", "remote", "add", name, url }});
}

pub fn removeRemote(repo: *Repo, name: []const u8) void {
    repo.run("Remove remote", &.{&.{ "git", "remote", "remove", name }});
}

/// Set who this repository's commits are by.
pub fn setIdentity(repo: *Repo, name: []const u8, email: []const u8) void {
    repo.run("Set identity", &.{ &.{ "git", "config", "user.name", name }, &.{ "git", "config", "user.email", email } });
}

// Diffs.

/// Show `change`'s staged or unstaged diff.
pub fn showChange(repo: *Repo, change: Change, staged: bool, key: []const u8) void {
    if (change.isUntracked()) return repo.showDiff(key, &.{ "git", "diff", "--no-color", "--no-index", "--", "/dev/null", change.path });
    if (staged) return repo.showDiff(key, &.{ "git", "diff", "--no-color", "--cached", "--", change.path });
    repo.showDiff(key, &.{ "git", "diff", "--no-color", "--", change.path });
}

/// Show a commit: who made it, when, its message, the files it changed and how.
pub fn showCommit(repo: *Repo, hash: []const u8, key: []const u8) void {
    repo.showDiff(key, &.{ "git", "show", "--no-color", "--stat", "--patch", "--format=commit %H%nAuthor: %an <%ae>%nDate:   %ad%n%n%B", hash });
}

pub fn showStash(repo: *Repo, name: []const u8, key: []const u8) void {
    repo.showDiff(key, &.{ "git", "stash", "show", "--no-color", "--stat", "--patch", name });
}
