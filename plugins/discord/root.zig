//! Discord: shows what you're doing in the Eggy editor as your Discord status (Rich Presence),
//! through the Discord app's local IPC: the project, the open scene, and whether you're
//! editing or playtesting, with the time since the editor opened.
const std = @import("std");
const eggy = @import("eggy");
const activity = @import("activity.zig");
const session = @import("session.zig");
const ipc = @import("ipc.zig");
const log = std.log.scoped(.discord);

/// Eggy's application at discord.com/developers: the status says you're playing Eggy.
const eggy_application_id: u64 = 1568076420712767519;

/// How often the editor's project and scene are read again for the status.
const refresh_ms = 1000;

pub const Plugin = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Connected, or looking for Discord while it is closed; null until the editor runs.
    client: ?*ipc.Client = null,
    /// What Discord was last told, so an unchanged status isn't sent again.
    shown: activity.Activity = .{},
    /// When the status was last worked out, in the editor.
    refreshed_ms: i64 = 0,

    pub const Preferences = struct {
        application_id: u64 = 0,
        show_scene: bool = true,

        pub const descriptions = .{
            .application_id = "Your own app's Application ID from discord.com/developers, to show its name in place of Eggy's. 0 shows Eggy.",
            .show_scene = "Name the open scene in your status.",
        };
    };

    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Plugin {
        var self: Plugin = .{ .gpa = gpa, .io = app.process_init.io };
        // Play and Stop restart plugins; in the editor, connect again at once so the status
        // carries on while the game runs, when editor frames don't.
        if (session.inEditor()) self.connect(app);
        return self;
    }

    pub fn deinit(self: *Plugin) void {
        if (self.client) |client| client.destroy();
    }

    /// Editing or paused: say so, with the project and scene.
    pub fn editorUpdate(self: *Plugin, editor: *eggy.editor.Context) !void {
        session.markEditor();
        if (self.client == null) self.connect(editor.app);
        if (self.client == null) return;

        const now_ms = std.Io.Clock.awake.now(self.io).toMilliseconds();
        if (now_ms - self.refreshed_ms < refresh_ms) return;
        self.refreshed_ms = now_ms;

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const status = try editor.status(arena);
        const settings = try editor.projectSettings(arena);
        const scene = if (editor.app.preferences(Preferences).show_scene) status.open_scene orelse "" else "";
        session.remember(settings.title, scene);
        const play: activity.Play = if (status.play == .paused) .paused else .editing;
        self.show(activity.describe(settings.title, scene, play));
    }

    /// Playing in the editor: playtesting what the last editor frame had open.
    pub fn update(self: *Plugin, app: *eggy.App) !void {
        _ = app;
        if (self.client == null or !session.inEditor()) return;
        var title_buffer: [activity.max_line_bytes]u8 = undefined;
        var scene_buffer: [256]u8 = undefined;
        const remembered = session.recall(&title_buffer, &scene_buffer);
        self.show(activity.describe(remembered.title, remembered.scene, .playing));
    }

    /// Start the client as Eggy's application, or the one set in Preferences.
    fn connect(self: *Plugin, app: *eggy.App) void {
        const chosen = app.preferences(Preferences).application_id;
        const id = if (chosen != 0) chosen else eggy_application_id;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const paths = ipc.socketPaths(arena_state.allocator(), app.process_init.environ_map) catch |err| return log.err("Discord: couldn't start: {t}", .{err});
        // ponytail: Play and Stop restart plugins, so the connection is made again each time and
        // Discord may blink the status; keep one client across restarts if that shows.
        self.client = ipc.Client.start(self.gpa, paths, id) catch |err| return log.err("Discord: couldn't start: {t}", .{err});
        self.shown = .{};
    }

    fn show(self: *Plugin, next: activity.Activity) void {
        const client = self.client orelse return;
        if (next.eql(&self.shown)) return;
        client.show(next, session.since(self.io));
        self.shown = next;
    }
};

test {
    // Compiles the hooks, which no test calls.
    std.testing.refAllDecls(Plugin);
    _ = activity;
    _ = session;
    _ = ipc;
}
