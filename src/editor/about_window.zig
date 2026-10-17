//! Help > About Eggy, with a small hatch hidden in the illustrated egg.
const std = @import("std");
const builtin = @import("builtin");
const eggy = @import("eggy");
const ui = eggy.ui;
const ToolWindow = @import("tool_window.zig").ToolWindow;

const hatch_taps = 7;
const egg_id = "about-egg";

const View = struct {
    taps: u8 = 0,
    hatched_at_ms: ?u64 = null,
    closed: bool = false,

    fn tap(self: *View, now_ms: u64) void {
        if (self.hatched_at_ms != null) return;
        self.taps += 1;
        if (self.taps == hatch_taps) self.hatched_at_ms = now_ms;
    }

    pub fn build(self: *View, context: *ui.Context) void {
        const id = context.idFor(egg_id);
        if (context.activated(id)) self.tap(context.time_ms);
        const glyph = context.builder().allocator.create(Glyph) catch |err| {
            context.err = err;
            return;
        };
        glyph.* = .{
            .cracks = self.taps,
            .hatch = if (self.hatched_at_ms) |start| @min(1, @as(f32, @floatFromInt(context.time_ms -| start)) / 700) else 0,
        };
        const egg = context.builder().node(id, .{ .height = 140, .width = 140 }, .{ .custom = .{ .context = glyph, .draw = drawEgg } }, &.{}) catch |err| {
            context.err = err;
            return;
        };
        egg.cursor = .pointer;
        egg.accessibility = .{ .role = .button, .label = "Eggy egg" };
        context.element(egg);
        context.heading(1, "Eggy");
        context.label("Version {s}", .{@import("build_options").version});
        context.muted("A game engine for making games in Zig.");
        context.label("Zig {s} | {s}-{s}", .{ builtin.zig_version_string, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
        context.muted("Built with SDL3, Vitellus, Weeoui and Clutch.");
        context.muted("eggyengine.github.io/eggy");
        context.muted("github.com/eggyengine/eggy");
        if (self.hatched_at_ms != null) {
            context.label("Chirp! Your next game starts with a little idea.", .{});
        } else context.muted("Made from scratch. Handle with care.");
        if (context.button("Close")) self.closed = true;
    }
};

const Glyph = struct { cracks: u8, hatch: f32 };

fn disc(canvas: *ui.Canvas, center: [2]f32, radii: [2]f32, color: [4]f32) !void {
    for (0..32) |i| {
        const a = @as(f32, @floatFromInt(i)) * std.math.tau / 32;
        const b = @as(f32, @floatFromInt(i + 1)) * std.math.tau / 32;
        try canvas.triangle(.{ center, .{ center[0] + @cos(a) * radii[0], center[1] + @sin(a) * radii[1] }, .{ center[0] + @cos(b) * radii[0], center[1] + @sin(b) * radii[1] } }, .{ color, color, color });
    }
}

fn drawEgg(raw: *const anyopaque, canvas: *ui.Canvas, rect: ui.Rect) !void {
    const glyph: *const Glyph = @ptrCast(@alignCast(raw));
    const center = rect.center();
    const shell = [4]f32{ 1, 0.78, 0.36, 1 };
    const dark = [4]f32{ 0.45, 0.24, 0.09, 1 };
    const y = center.y + 8;
    try disc(canvas, .{ center.x, y }, .{ 38, 49 }, dark);
    try disc(canvas, .{ center.x, y - 1 }, .{ 35, 46 }, shell);
    if (glyph.hatch > 0) {
        // The chick rises behind the remaining shell, entirely in the About window.
        const head_y = y + 5 - 30 * glyph.hatch;
        try disc(canvas, .{ center.x, head_y }, .{ 25, 25 }, .{ 1, 0.92, 0.35, 1 });
        try disc(canvas, .{ center.x - 9, head_y - 2 }, .{ 2.5, 3.5 }, dark);
        try disc(canvas, .{ center.x + 9, head_y - 2 }, .{ 2.5, 3.5 }, dark);
        const beak = [4]f32{ 0.95, 0.42, 0.1, 1 };
        try canvas.triangle(.{ .{ center.x - 5, head_y + 6 }, .{ center.x + 5, head_y + 6 }, .{ center.x, head_y + 12 } }, .{ beak, beak, beak });
        try canvas.roundRect(.{ .x = center.x - 33, .y = y + 17, .w = 66, .h = 25 }, .{ shell[0], shell[1], shell[2] }, 12);
        return;
    }
    try disc(canvas, .{ center.x - 13, y - 23 }, .{ 7, 15 }, .{ 1, 0.95, 0.78, 1 });
    const crack = [_][2]f32{ .{ -25, 2 }, .{ -15, -6 }, .{ -5, 4 }, .{ 5, -5 }, .{ 15, 5 }, .{ 25, -2 } };
    for (0..@min(glyph.cracks, crack.len - 1)) |i| {
        const a = [2]f32{ center.x + crack[i][0], y + crack[i][1] };
        const b = [2]f32{ center.x + crack[i + 1][0], y + crack[i + 1][1] };
        try canvas.triangle(.{ a, b, .{ a[0], a[1] + 2 } }, .{ dark, dark, dark });
        try canvas.triangle(.{ b, .{ b[0], b[1] + 2 }, .{ a[0], a[1] + 2 } }, .{ dark, dark, dark });
    }
}

/// A heap-owned editor tool; its UI and surface close before the shared editor font.
pub const AboutWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    view: View = .{},

    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font) !*AboutWindow {
        const self = try gpa.create(AboutWindow);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "About Eggy", .{ 480, 520 }, .{}) };
        return self;
    }
    pub fn close(self: *AboutWindow, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.gpa.destroy(self);
    }
    pub fn closeRequested(self: *const AboutWindow, event: eggy.Event) bool {
        return self.window.owns(event) and (event == .window_close_requested or (event == .key_down and event.key_down.scancode == .escape));
    }
    pub fn handle(self: *AboutWindow, event: eggy.Event) bool {
        if (!self.window.owns(event)) return false;
        self.window.handle(event);
        return true;
    }
    pub fn update(self: *AboutWindow, graphics: *eggy.Graphics, style: *const ui.Context) !bool {
        try self.window.present(graphics, style, &self.view);
        return !self.view.closed;
    }
};

test "the About egg hatches on exactly seven activations and stays hatched" {
    var view = View{};
    for (0..hatch_taps - 1) |_| view.tap(100);
    try std.testing.expect(view.hatched_at_ms == null);
    view.tap(250);
    try std.testing.expectEqual(@as(?u64, 250), view.hatched_at_ms);
    view.tap(300);
    try std.testing.expectEqual(@as(u8, hatch_taps), view.taps);
}

test "About fits its window before and after hatching and supports keyboard activation" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    context.density = .compact;
    var view = View{};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 480, .h = 520 };
    context.newFrame(viewport);
    view.build(&context);
    try std.testing.expect((try context.render()).len > 0);
    const egg = context.last_root.?.find(context.last_focusables.items[0]).?;
    try std.testing.expectEqual(@as(@TypeOf(egg.accessibility.role), .button), egg.accessibility.role);
    context.focus = egg.id;
    for (0..hatch_taps) |_| {
        context.handle(.{ .key_down = .{ .key = .enter, .modifiers = .{}, .repeat = false } });
        context.newFrame(viewport);
        view.build(&context);
        _ = try context.render();
    }
    try std.testing.expect(view.hatched_at_ms != null);
    context.time_ms = 1000;
    context.newFrame(viewport);
    view.build(&context);
    _ = try context.render();
    const close = context.last_root.?.find(context.last_focusables.items[context.last_focusables.items.len - 1]).?;
    try std.testing.expect(close.bounds.y + close.bounds.h <= viewport.h);
}
