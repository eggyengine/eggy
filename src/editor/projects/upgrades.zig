//! Which other Eggy the open project could build against: a newer packaged engine (File >
//! Upgrade Editor) or the Eggy codebase being developed on this machine (File > Link Developer
//! Eggy), for the menus and status bar.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const engine = @import("engine.zig");
const job = @import("job.zig");

pub const Upgrades = struct {
    /// Holds `current` and `label`, for the editor's lifetime.
    arena: std.heap.ArenaAllocator,
    /// Holds `developer_dir`, until the next `refresh`.
    records: std.heap.ArenaAllocator,
    /// The Eggy the project built this editor with; null without a project, or if unreadable.
    current: ?engine.ProjectEngine = null,
    /// `current` for the status bar: a packaged engine's short version, or the linked codebase.
    label: ?[]const u8 = null,
    /// The Eggy codebase being developed, from the last `refresh`.
    developer_dir: ?[]const u8 = null,
    can_upgrade: bool = false,
    can_link: bool = false,

    /// Read which Eggy the project in `project_dir` (absolute; null without a project) uses,
    /// after recording `source_dir`, the Eggy this editor was built from, as the codebase being
    /// developed if it is a checkout. Failures leave the choices off.
    pub fn init(gpa: std.mem.Allocator, project_dir: ?[]const u8, source_dir: []const u8) Upgrades {
        var self = Upgrades{ .arena = .init(gpa), .records = .init(gpa) };
        const folders = job.editorFolders(gpa) catch return self;
        defer gpa.free(folders.resources_dir);
        defer gpa.free(folders.engines_dir);
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        engine.markDeveloper(io, folders.engines_dir, source_dir) catch |err| std.log.warn("cannot record the Eggy codebase {s}: {t}", .{ source_dir, err });
        if (project_dir) |dir| self.readCurrent(io, dir, folders.engines_dir);
        self.refresh();
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
        self.label = switch (current) {
            .packaged => |version| version[0..@min(8, version.len)],
            .linked => |codebase| std.fmt.allocPrint(arena, "linked to {s}", .{codebase}) catch null,
            .fetched => null,
        };
    }

    pub fn deinit(self: *Upgrades) void {
        self.records.deinit();
        self.arena.deinit();
    }

    /// Look again for a newer engine and the codebase being developed; another editor may have
    /// unpacked or recorded one since.
    pub fn refresh(self: *Upgrades) void {
        const gpa = self.arena.child_allocator;
        _ = self.records.reset(.retain_capacity);
        const folders = job.editorFolders(gpa) catch return;
        defer gpa.free(folders.resources_dir);
        defer gpa.free(folders.engines_dir);
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const latest = engine.latest(self.records.allocator(), io, folders.engines_dir) catch null;
        self.developer_dir = engine.developer(self.records.allocator(), io, folders.engines_dir) catch null;
        const current = self.current orelse return;
        self.can_upgrade = current.canUpgrade(latest);
        self.can_link = current.canLink(self.developer_dir);
    }

    /// Log why File > Upgrade Editor (`.upgrade`) or Link Developer Eggy (`.link`) can't run.
    pub fn logUnavailable(self: *const Upgrades, choice: enum { upgrade, link }) void {
        const current = self.current orelse return std.log.info("{t}: open a project first; it changes the open project's Eggy", .{choice});
        switch (current) {
            .fetched => std.log.info("{t}: the project gets Eggy by URL, so its build.zig.zon picks the version", .{choice}),
            .linked => |codebase| if (choice == .upgrade)
                std.log.info("upgrade: the project is linked to the Eggy codebase at {s}, so it doesn't upgrade", .{codebase})
            else
                std.log.info("link: the project is already linked to {s}", .{codebase}),
            .packaged => if (choice == .upgrade)
                std.log.info("upgrade: the project already uses the newest Eggy", .{})
            else
                std.log.info("link: no Eggy checkout is recorded; run an editor built from your Eggy checkout once", .{}),
        }
    }

    /// Ask, over `window`, whether to link project `title` to the codebase being developed, with
    /// the warning that it can't be undone. Blocks until answered; false if it can't be shown.
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
