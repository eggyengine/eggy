//! Project Stats: a session stopwatch in the editor's status bar, like a speedpaint's timer, and
//! a Project Stats panel of how long the project has been worked on, by whom, on which days, and
//! what it is made of. A dev plugin: each person's record is kept in the project's
//! `.eggy/work_time/`, and exported games leave it out.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const sdl = eggy.sdl_adapter.sdl;
const record = @import("record.zig");
const panel_zig = @import("panel.zig");

/// The stopwatch menu's rows, in order.
const StatusRow = enum { reset, show_panel };

pub const Plugin = struct {
    gpa: std.mem.Allocator,
    /// This person's record and everyone else's, read once there is a project; null in the
    /// runtime and before then.
    tracker: ?record.Tracker = null,
    /// The project's folder (owned), and open, where the record is written.
    project_dir: ?[]u8 = null,
    project: ?std.Io.Dir = null,
    panel: panel_zig.Panel = .{},

    pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .key = "stats", .title = "Project Stats" }};
    pub const editor_status_items = [_]eggy.plugins.EditorStatusItem{.{ .key = "stopwatch", .title = "0:00:00", .side = .right, .items = &.{
        .{ .key = "reset", .title = "Reset Session" },
        .{ .key = "open", .title = "Show Project Stats" },
    } }};

    comptime {
        std.debug.assert(editor_status_items[0].items.len == @typeInfo(StatusRow).@"enum".field_names.len);
    }

    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Plugin {
        _ = app;
        return .{ .gpa = gpa };
    }

    /// Write the record, so a hot reload or the next editor goes on from it.
    pub fn deinit(self: *Plugin) void {
        if (self.tracker) |*tracker| {
            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.io();
            if (self.project) |project| tracker.save(io, project, nowRealMs(io));
            tracker.deinit();
        }
        if (self.project) |project| {
            var threaded: std.Io.Threaded = .init_single_threaded;
            project.close(threaded.io());
        }
        if (self.project_dir) |dir| self.gpa.free(dir);
    }

    pub fn editorPanelUi(self: *Plugin, panel: usize, editor: *eggy.editor.Context, context: *ui.Context) !void {
        _ = panel;
        const tracker = try self.track(editor) orelse return context.muted("Open a project to see its stats.");
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const settings = try editor.projectSettings(arena.allocator());
        self.panel.build(context, .{ .gpa = self.gpa, .title = settings.title, .project_dir = self.project_dir.?, .work = tracker, .entities = editor.app.world.entityCount(), .now_ms = sdl.timer.getMillisecondsSinceInit() });
    }

    /// Asked every frame, even while playing: count the time worked, and give the status bar
    /// the session's stopwatch.
    pub fn editorBarState(self: *Plugin, target: eggy.plugins.EditorBarTarget, editor: *eggy.editor.Context, bar: *eggy.plugins.EditorBarState) !void {
        if (target != .status) return;
        const tracker = try self.track(editor) orelse return;
        var buffer: [32]u8 = undefined;
        bar.setText(record.formatClock(&buffer, tracker.mine.sitting.stopwatch_ms));
    }

    pub fn editorBarAction(self: *Plugin, target: eggy.plugins.EditorBarTarget, editor: *eggy.editor.Context) !void {
        if (target != .status_item) return;
        switch (@as(StatusRow, @fromBackingInt(@intCast(target.status_item.item)))) {
            .reset => if (try self.track(editor)) |tracker| tracker.resetStopwatch(),
            .show_panel => try editor.showPanel("stats"),
        }
    }

    /// The tracker, following the editor's use up to now and writing the record now and then;
    /// read first if it hasn't been. Null without a project.
    fn track(self: *Plugin, editor: *eggy.editor.Context) !?*record.Tracker {
        const io = editor.app.process_init.io;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const project = try self.openProject(editor, io, arena.allocator()) orelse return null;
        if (self.tracker == null) self.tracker = try record.Tracker.load(self.gpa, io, project, record.userName(), nowRealMs(io));
        const tracker = &self.tracker.?;
        const status = try editor.status(arena.allocator());
        const now_ms = sdl.timer.getMillisecondsSinceInit();
        tracker.today = localDay() orelse tracker.today;
        tracker.follow(.{ .idle_ms = status.idle_ms, .unfocused_ms = status.unfocused_ms, .saves = status.saves, .plays = status.plays, .builds = status.builds }, now_ms);
        tracker.keep(io, project, now_ms, nowRealMs(io));
        return tracker;
    }

    /// The project's folder, opened the first time; null without a project.
    fn openProject(self: *Plugin, editor: *eggy.editor.Context, io: std.Io, arena: std.mem.Allocator) !?std.Io.Dir {
        if (self.project) |project| return project;
        const path = editor.projectFolder(arena) catch |err| switch (err) {
            error.NoProject => return null,
            else => return err,
        };
        self.project = try std.Io.Dir.cwd().openDir(io, path, .{});
        self.project_dir = try self.gpa.dupe(u8, path);
        return self.project;
    }
};

fn nowRealMs(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

/// Today, in days since 1970-01-01 in local time; null if the clock can't be read.
fn localDay() ?i32 {
    const now = sdl.time.Time.getCurrent() catch return null;
    const local = sdl.time.DateTime.fromTime(now, true) catch return null;
    const seconds = @divFloor(now.value, std.time.ns_per_s) + local.utc_offset;
    return @intCast(@divFloor(seconds, std.time.s_per_day));
}

test {
    _ = record;
    _ = panel_zig;
    std.testing.refAllDecls(Plugin);
}
