//! Help > About Eggy: the version, links and credits, with a small hatch hidden in the illustrated egg.
const std = @import("std");
const builtin = @import("builtin");
const eggy = @import("eggy");
const ui = eggy.ui;
const ToolWindow = @import("tool_window.zig").ToolWindow;
const page_style = @import("page_style.zig");
const restyle = page_style.restyle;
const smallText = page_style.smallText;

const hatch_taps = 7;
const egg_id = "about-egg";

const View = struct {
    taps: u8 = 0,
    hatched_at_ms: ?u64 = null,
    closed: bool = false,
    /// A link pressed this frame, for the window to open.
    open_url: ?[:0]const u8 = null,

    fn tap(self: *View, now_ms: u64) void {
        if (self.hatched_at_ms != null) return;
        self.taps += 1;
        if (self.taps == hatch_taps) self.hatched_at_ms = now_ms;
    }

    /// Build the internal About page in an active UI frame, recording link/close actions
    /// for `AboutWindow.update`; frame allocations belong to `context`.
    ///
    /// ```zig
    /// // Inside this file, with an active context frame:
    /// var view = View{};
    /// view.build(context);
    /// ```
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
        const egg = context.builder().node(id, .{ .height = 160, .width = 140 }, .{ .custom = .{ .context = glyph, .draw = drawEgg } }, &.{}) catch |err| {
            context.err = err;
            return;
        };
        egg.cursor = .pointer;
        egg.accessibility = .{ .role = .button, .label = "Eggy egg" };
        // Everything centred under the egg: name and version, what it is, where to find it.
        context.begin(.column);
        context.element(egg);
        context.heading(1, "Eggy");
        centerText(context);
        const version = std.fmt.allocPrint(context.builder().allocator, "Version {s}", .{@import("build_options").version}) catch "Version";
        context.badge(version, .secondary);
        restyle(context, .{ .width = context.font.measure(version, context.theme.small_text_size) + 20 });
        context.muted(if (self.hatched_at_ms != null) "Chirp! Your next game starts with a little idea." else "A game engine for making games in Zig.");
        centerText(context);
        context.begin(.row);
        for (links) |link| if (context.buttonVariant(link.label, .link)) {
            self.open_url = link.url;
        };
        context.end();
        restyle(context, .{ .direction = .row, .gap = 4 });
        if (context.last_added) |row| row.style.justify = .center;
        context.muted(std.fmt.allocPrint(context.builder().allocator, "Zig {s} · {s}-{s} · SDL3, Vitellus, Weeoui, Clutch", .{ builtin.zig_version_string, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) }) catch "");
        smallText(context, 12);
        centerText(context);
        madeWithLove(context);
        if (context.button("Close")) self.closed = true;
        context.end();
        restyle(context, .{ .width = context.contentWidth(), .align_items = .center, .gap = 10 });
    }
};

/// Centre the wrapped text `context` added last, as the rest of the page is.
fn centerText(context: *ui.Context) void {
    const element = context.last_added orelse return;
    if (element.paint_kind == .text) element.paint_kind.text.alignment = .center;
}

/// "Made with ♥ by the eggyengine team", the heart drawn, since the UI font has no emoji.
fn madeWithLove(context: *ui.Context) void {
    const b = context.builder();
    const size = context.theme.text_size;
    const row = b.node(0, .{ .direction = .row, .gap = 4, .align_items = .center, .justify = .center }, .none, &.{
        b.node(0, .{}, .{ .text = .{ .value = "Made with", .size = size } }, &.{}) catch return,
        b.node(0, .{ .width = 12, .height = 12 }, .{ .custom = .{ .context = &drawHeart, .draw = drawHeart } }, &.{}) catch return,
        b.node(0, .{}, .{ .text = .{ .value = "by the eggyengine team", .size = size } }, &.{}) catch return,
    }) catch return;
    row.accessibility.label = "Made with love by the eggyengine team";
    context.element(row);
}

fn drawHeart(_: *const anyopaque, canvas: *ui.Canvas, rect: ui.Rect) !void {
    const red = [4]f32{ 0.9, 0.25, 0.3, 1 };
    const r = rect.w / 4;
    try disc(canvas, .{ rect.x + r, rect.y + r + 1 }, .{ r, r }, red);
    try disc(canvas, .{ rect.x + 3 * r, rect.y + r + 1 }, .{ r, r }, red);
    try canvas.triangle(.{ .{ rect.x + 0.2, rect.y + r + 2 }, .{ rect.x + rect.w - 0.2, rect.y + r + 2 }, .{ rect.x + rect.w / 2, rect.y + rect.h } }, .{ red, red, red });
}

const links = [_]struct { label: []const u8, url: [:0]const u8 }{
    .{ .label = "Documentation", .url = "https://eggyengine.github.io/eggy" },
    .{ .label = "GitHub", .url = "https://github.com/eggyengine/eggy" },
};

const Glyph = struct { cracks: u8, hatch: f32 };

fn disc(canvas: *ui.Canvas, center: [2]f32, radii: [2]f32, color: [4]f32) !void {
    for (0..32) |i| {
        const a = @as(f32, @floatFromInt(i)) * std.math.tau / 32;
        const b = @as(f32, @floatFromInt(i + 1)) * std.math.tau / 32;
        try canvas.triangle(.{ center, .{ center[0] + @cos(a) * radii[0], center[1] + @sin(a) * radii[1] }, .{ center[0] + @cos(b) * radii[0], center[1] + @sin(b) * radii[1] } }, .{ color, color, color });
    }
}

/// Where the shell breaks, across the egg's middle (offsets from its centre); a tap cracks one
/// segment more, and the last tap breaks it open.
const break_line = [_][2]f32{ .{ -38, 0 }, .{ -25, 2 }, .{ -15, -6 }, .{ -5, 4 }, .{ 5, -5 }, .{ 15, 5 }, .{ 25, -2 }, .{ 38, 0 } };

/// The shell above the break line (`top`) or below it, out to `radii`, moved by `offset`.
fn shellHalf(canvas: *ui.Canvas, center: [2]f32, radii: [2]f32, top: bool, offset: [2]f32, color: [4]f32) !void {
    var points: [break_line.len + 17][2]f32 = undefined;
    for (break_line, points[0..break_line.len]) |p, *point| point.* = .{ center[0] + std.math.clamp(p[0], -radii[0], radii[0]) + offset[0], center[1] + p[1] + offset[1] };
    // The rim, from the line's right end round to its left: under the egg, or over it.
    for (points[break_line.len..], 0..) |*point, i| {
        const a = @as(f32, @floatFromInt(i)) * std.math.pi / 16;
        const turn = if (top) -a else a;
        point.* = .{ center[0] + @cos(turn) * radii[0] + offset[0], center[1] + @sin(turn) * radii[1] + offset[1] };
    }
    // A fan from inside the half; it sees every point of the line and the rim.
    const hub = [2]f32{ center[0] + offset[0], center[1] + offset[1] + (if (top) -radii[1] else radii[1]) * 0.6 };
    for (points, 0..) |a, i| {
        const b = points[(i + 1) % points.len];
        try canvas.triangle(.{ hub, a, b }, .{ color, color, color });
    }
}

fn drawEgg(raw: *const anyopaque, canvas: *ui.Canvas, rect: ui.Rect) !void {
    const glyph: *const Glyph = @ptrCast(@alignCast(raw));
    const center = rect.center();
    const shell = [4]f32{ 1, 0.78, 0.36, 1 };
    const dark = [4]f32{ 0.45, 0.24, 0.09, 1 };
    const y = center.y + 18;
    if (glyph.hatch > 0) {
        // The chick rises from the lower shell, wearing the top of it.
        const chick = [4]f32{ 1, 0.92, 0.35, 1 };
        const head_y = y + 5 - 30 * glyph.hatch;
        try disc(canvas, .{ center.x, y + 10 }, .{ 27, 27 }, chick);
        try disc(canvas, .{ center.x, head_y }, .{ 22, 22 }, chick);
        try disc(canvas, .{ center.x - 8, head_y - 1 }, .{ 2.5, 3.5 }, dark);
        try disc(canvas, .{ center.x + 8, head_y - 1 }, .{ 2.5, 3.5 }, dark);
        const beak = [4]f32{ 0.95, 0.42, 0.1, 1 };
        try canvas.triangle(.{ .{ center.x - 5, head_y + 6 }, .{ center.x + 5, head_y + 6 }, .{ center.x, head_y + 12 } }, .{ beak, beak, beak });
        try shellHalf(canvas, .{ center.x, y }, .{ 38, 49 }, false, .{ 0, -2 }, dark);
        try shellHalf(canvas, .{ center.x, y }, .{ 35, 46 }, false, .{ 0, 0 }, shell);
        const lift = [2]f32{ 6 * glyph.hatch, -35 * glyph.hatch };
        try shellHalf(canvas, .{ center.x, y }, .{ 38, 49 }, true, .{ lift[0], lift[1] + 2 }, dark);
        try shellHalf(canvas, .{ center.x, y }, .{ 35, 46 }, true, lift, shell);
        return;
    }
    try disc(canvas, .{ center.x, y }, .{ 38, 49 }, dark);
    try disc(canvas, .{ center.x, y - 1 }, .{ 35, 46 }, shell);
    try disc(canvas, .{ center.x - 13, y - 23 }, .{ 7, 15 }, .{ 1, 0.95, 0.78, 1 });
    for (0..@min(glyph.cracks, break_line.len - 1)) |i| {
        // The line's ends lie on the rim; the crack starts and stops inside it.
        const a = [2]f32{ center.x + std.math.clamp(break_line[i][0], -30, 30), y + break_line[i][1] };
        const b = [2]f32{ center.x + std.math.clamp(break_line[i + 1][0], -30, 30), y + break_line[i + 1][1] };
        try canvas.triangle(.{ a, b, .{ a[0], a[1] + 2 } }, .{ dark, dark, dark });
        try canvas.triangle(.{ b, .{ b[0], b[1] + 2 }, .{ a[0], a[1] + 2 } }, .{ dark, dark, dark });
    }
}

/// A heap-owned editor tool; its UI and surface close before the shared editor font.
pub const AboutWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    view: View = .{},

    /// Allocate the editor's About window. SDL, `graphics`, and the borrowed `font`
    /// must remain alive until `close`; allocation/window/surface errors propagate.
    ///
    /// ```zig
    /// // Editor host with initialized graphics and shared font:
    /// const about = try AboutWindow.open(gpa, graphics, font);
    /// defer about.close(graphics);
    /// ```
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font) !*AboutWindow {
        const self = try gpa.create(AboutWindow);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "About Eggy", .{ 480, 520 }, .{}) };
        return self;
    }
    /// Destroy the About window and free `self`; use the graphics device that opened it.
    ///
    /// ```zig
    /// // Editor shutdown, before destroying graphics or the shared font:
    /// about.close(graphics); // `about` is invalid afterward.
    /// ```
    pub fn close(self: *AboutWindow, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.gpa.destroy(self);
    }
    /// Test for this window's close request or Escape without consuming the event.
    /// Other windows' events return false; the host remains responsible for `close`.
    ///
    /// ```zig
    /// if (about.closeRequested(event)) {
    ///     about.close(graphics);
    ///     return;
    /// }
    /// _ = about.handle(event);
    /// ```
    pub fn closeRequested(self: *const AboutWindow, event: eggy.Event) bool {
        return self.window.owns(event) and (event == .window_close_requested or (event == .key_down and event.key_down.scancode == .escape));
    }
    /// Route this window's event to its UI; true means the host must not route it again.
    /// Does not destroy the window on close requests.
    ///
    /// ```zig
    /// // After checking closeRequested in the editor event loop:
    /// if (about.handle(event)) return;
    /// ```
    pub fn handle(self: *AboutWindow, event: eggy.Event) bool {
        if (!self.window.owns(event)) return false;
        self.window.handle(event);
        return true;
    }
    /// Present an About frame using the editor's borrowed style and open clicked URLs.
    /// Return false when Close was pressed; rendering errors propagate, URL failures log.
    ///
    /// ```zig
    /// // In the editor frame loop; clear the host's pointer after closing:
    /// if (!try about.update(graphics, style)) {
    ///     about.close(graphics);
    ///     return;
    /// }
    /// ```
    pub fn update(self: *AboutWindow, graphics: *eggy.Graphics, style: *const ui.Context) !bool {
        try self.window.present(graphics, style, &self.view);
        if (self.view.open_url) |url| eggy.sdl_adapter.sdl.openURL(url) catch |err| std.log.err("cannot open {s}: {t}", .{ url, err });
        self.view.open_url = null;
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
