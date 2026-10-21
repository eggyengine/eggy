//! Frame stats: frames per second, the average frame time and the slowest frame of the last
//! second, in a corner of the game. F3 shows and hides them.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;

/// How many frames the averages cover at most; the window is a second, or this many frames.
const max_samples = 240;
const window_s: f32 = 1;
/// From the window's edge, in points.
const margin = 8;

pub const Corner = enum { top_left, top_right, bottom_left, bottom_right };

pub const Plugin = struct {
    shown: bool = true,
    /// The last frames' times, in seconds, oldest first from `next` round.
    samples: [max_samples]f32 = @splat(0),
    next: usize = 0,
    count: usize = 0,

    pub const Preferences = struct {
        corner: Corner = .top_right,
        show_at_start: bool = true,

        pub const descriptions = .{
            .corner = "Where the stats sit in the game's window.",
            .show_at_start = "Show them when the game starts; F3 shows and hides them.",
        };
    };

    /// Turns on the game's UI layer, which the stats are drawn in.
    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Plugin {
        _ = gpa;
        _ = try app.gameUi();
        return .{ .shown = app.preferences(Preferences).show_at_start };
    }

    /// F3 shows or hides the stats.
    pub fn event(self: *Plugin, app: *eggy.App, curr_event: eggy.Event) !void {
        _ = app;
        if (curr_event == .key_down and curr_event.key_down.scancode == .func3 and !curr_event.key_down.repeat) self.shown = !self.shown;
    }

    /// Count this frame, then draw the stats over the game.
    pub fn gameUi(self: *Plugin, app: *eggy.App, context: *ui.Context) !void {
        self.record(app.time.unscaled_delta_s);
        if (!self.shown or self.count == 0) return;
        const stats = self.summarize();
        const arena = context.builder().allocator;
        const b = context.builder();
        const size = context.theme.small_text_size;
        const lines = [_][]const u8{
            try std.fmt.allocPrint(arena, "{d:.0} fps", .{stats.fps}),
            try std.fmt.allocPrint(arena, "{d:.1} ms average", .{stats.average_ms}),
            try std.fmt.allocPrint(arena, "{d:.1} ms slowest", .{stats.slowest_ms}),
        };
        var children: [lines.len]*ui.Layout.Element = undefined;
        for (&children, lines) |*child, line| child.* = try b.node(0, .{}, .{ .text = .{ .value = line, .size = size } }, &.{});
        const width: f32 = 132;
        const height = @as(f32, @floatFromInt(lines.len)) * size * 1.5 + 16;
        const card = try b.node(0, .{ .width = width, .gap = 2, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 }, .z_index = 400 }, .{ .surface = .card }, &children);
        const view = context.viewport;
        const corner = app.preferences(Preferences).corner;
        const left = corner == .top_left or corner == .bottom_left;
        const top = corner == .top_left or corner == .top_right;
        card.overlay = .{ .point = .init(
            if (left) view.x + margin else view.x + view.w - width - margin,
            if (top) view.y + margin else view.y + view.h - height - margin,
        ) };
        context.element(card);
    }

    fn record(self: *Plugin, delta_s: f32) void {
        if (delta_s <= 0) return;
        self.samples[self.next] = delta_s;
        self.next = (self.next + 1) % max_samples;
        self.count = @min(self.count + 1, max_samples);
    }

    const Stats = struct { fps: f32, average_ms: f32, slowest_ms: f32 };

    /// The frames of the last second (newest back), as frames per second, their average and
    /// their slowest.
    fn summarize(self: *const Plugin) Stats {
        var total_s: f32 = 0;
        var slowest_s: f32 = 0;
        var frames: usize = 0;
        while (frames < self.count and total_s < window_s) : (frames += 1) {
            const sample = self.samples[(self.next + max_samples - 1 - frames) % max_samples];
            total_s += sample;
            slowest_s = @max(slowest_s, sample);
        }
        const average_s = total_s / @as(f32, @floatFromInt(frames));
        return .{ .fps = 1 / average_s, .average_ms = average_s * 1000, .slowest_ms = slowest_s * 1000 };
    }
};

test "the stats cover the last second of frames" {
    var plugin = Plugin{};
    // Two seconds at 50 fps, then a second of 25 fps with one slow frame.
    for (0..100) |_| plugin.record(0.02);
    for (0..24) |_| plugin.record(0.04);
    plugin.record(0.04 * 1.5);
    const stats = plugin.summarize();
    try std.testing.expectApproxEqAbs(@as(f32, 60), stats.slowest_ms, 0.01);
    try std.testing.expect(stats.fps > 23 and stats.fps < 25);
}

test "the plugin compiles" {
    std.testing.refAllDecls(Plugin);
}
