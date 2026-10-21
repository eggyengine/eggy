//! The Git plugin's symbols, drawn as strokes on a 16-point grid (the editor's font has no
//! arrows or branch marks), and the small buttons and marks that show them.
const std = @import("std");
const ui = @import("eggy").ui;

pub const Icon = enum {
    plus,
    minus,
    check,
    x,
    push,
    pull,
    fetch,
    refresh,
    discard,
    branch,
    merge,
    rebase,
    switch_to,
    trash,
    stash,
    unstash,
    tag,
    commit,
    cherry_pick,
    reset,
};

/// A button showing `icon`, 26 points square; `tip` shows while the pointer rests on it and
/// names it for screen readers. `key` makes its id unique on the page. Returns true when it is
/// pressed and `enabled`.
pub fn button(context: *ui.Context, key: []const u8, icon: Icon, tip: []const u8, enabled: bool) bool {
    return iconButton(context, key, icon, tip, if (enabled) .normal else .disabled);
}

/// `button` for an action that loses work: the first press arms it (it turns red), and a second
/// press within a few seconds runs it. `armed` remembers which one is armed, across frames.
pub fn dangerButton(context: *ui.Context, key: []const u8, icon: Icon, tip: []const u8, enabled: bool, armed: *Armed) bool {
    const id = context.idFor(key);
    const is_armed = armed.id == id and context.time_ms -| armed.since_ms < Armed.window_ms;
    const pressed = iconButton(context, key, icon, if (is_armed) "Click again to confirm" else tip, if (!enabled) .disabled else if (is_armed) .armed else .normal);
    if (!pressed) return false;
    if (is_armed) {
        armed.* = .{};
        return true;
    }
    armed.* = .{ .id = id, .since_ms = context.time_ms };
    return false;
}

/// Which danger button is armed, and since when.
pub const Armed = struct {
    id: u32 = 0,
    since_ms: u64 = 0,

    const window_ms = 3000;
};

/// `icon`, `size` points square, as a mark in a row: not a button.
pub fn mark(context: *ui.Context, icon: Icon, size: f32, tone: Tone) void {
    const glyph = context.builder().allocator.create(Glyph) catch return;
    glyph.* = .{ .icon = icon, .tone = tone };
    const element = context.builder().node(0, .{ .width = size, .height = size }, .{ .custom = .{ .context = glyph, .draw = drawGlyph } }, &.{}) catch return;
    element.accessibility.role = .ignored;
    context.element(element);
}

pub const Tone = enum { foreground, muted, primary, added, removed };

const Look = enum { normal, disabled, armed };

const Glyph = struct { icon: Icon, tone: Tone = .foreground, id: u32 = 0, look: Look = .normal };

fn iconButton(context: *ui.Context, key: []const u8, icon: Icon, tip: []const u8, look: Look) bool {
    const id = context.idFor(key);
    const glyph = context.builder().allocator.create(Glyph) catch return false;
    glyph.* = .{ .icon = icon, .id = id, .look = look };
    const element = context.builder().node(id, .{ .width = 26, .height = 26 }, .{ .custom = .{ .context = glyph, .draw = drawButton } }, &.{}) catch return false;
    element.cursor = if (look == .disabled) .default else .pointer;
    element.accessibility = .{ .role = .button, .label = tip };
    context.element(element);
    context.tooltip(tip);
    return look != .disabled and context.activated(id);
}

fn drawButton(raw: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const glyph: *const Glyph = @ptrCast(@alignCast(raw));
    const hot = c.hot_id == glyph.id and glyph.look != .disabled;
    if (glyph.look == .armed) {
        try c.roundRectAlpha(r, c.theme.destructive, c.theme.radiusSm(), 0.22);
    } else if (hot) try c.roundRect(r, c.theme.muted, c.theme.radiusSm());
    const color: ui.Color = switch (glyph.look) {
        .normal => c.theme.foreground,
        .disabled => c.theme.muted_foreground,
        .armed => c.theme.destructive,
    };
    const alpha: f32 = if (glyph.look == .disabled) 0.45 else 1;
    try draw(c, glyph.icon, r.inset(5), color ++ [_]f32{alpha});
}

fn drawGlyph(raw: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const glyph: *const Glyph = @ptrCast(@alignCast(raw));
    try draw(c, glyph.icon, r, toneColor(c.theme, glyph.tone) ++ [_]f32{1});
}

/// The colour of `tone` in `theme`.
pub fn toneColor(theme: ui.Theme, tone: Tone) ui.Color {
    return switch (tone) {
        .foreground => theme.foreground,
        .muted => theme.muted_foreground,
        .primary => theme.primary,
        .added => .{ 0.42, 0.75, 0.47 },
        .removed => theme.destructive,
    };
}

/// Draw `icon` filling `r` (square), in `color`.
pub fn draw(c: *ui.Canvas, icon: Icon, r: ui.Rect, color: [4]f32) !void {
    var pen = Pen{ .c = c, .origin = .{ r.x, r.y }, .scale = @min(r.w, r.h) / 16, .color = color };
    switch (icon) {
        .plus => {
            try pen.line(.{ 8, 2.5 }, .{ 8, 13.5 });
            try pen.line(.{ 2.5, 8 }, .{ 13.5, 8 });
        },
        .minus => try pen.line(.{ 2.5, 8 }, .{ 13.5, 8 }),
        .check => try pen.polyline(&.{ .{ 2.5, 8.5 }, .{ 6.5, 12.5 }, .{ 13.5, 4 } }),
        .x => {
            try pen.line(.{ 3.5, 3.5 }, .{ 12.5, 12.5 });
            try pen.line(.{ 12.5, 3.5 }, .{ 3.5, 12.5 });
        },
        .push => try pen.arrow(.{ 8, 14 }, .{ 8, 2.5 }),
        .pull => try pen.arrow(.{ 8, 2 }, .{ 8, 13.5 }),
        .fetch => {
            try pen.arrow(.{ 8, 1.5 }, .{ 8, 10.5 });
            try pen.line(.{ 2.5, 14 }, .{ 13.5, 14 });
        },
        .refresh => {
            try pen.arc(.{ 8, 8 }, 5.5, -60, 210);
            try pen.head(.{ 8 + 5.5 * @cos(rad(210)), 8 + 5.5 * @sin(rad(210)) }, rad(210 + 90));
        },
        .discard => {
            // An arrow turning back on itself: undo.
            try pen.arc(.{ 9, 9 }, 4.5, -90, 90);
            try pen.line(.{ 9, 13.5 }, .{ 5, 13.5 });
            try pen.line(.{ 9, 4.5 }, .{ 3, 4.5 });
            try pen.head(.{ 3, 4.5 }, rad(180));
        },
        .branch => {
            try pen.line(.{ 4.5, 2.5 }, .{ 4.5, 13.5 });
            try pen.polyline(&.{ .{ 11.5, 6 }, .{ 11.5, 7.5 }, .{ 4.5, 11.5 } });
            try pen.ring(.{ 11.5, 4 }, 2);
        },
        .merge => {
            try pen.line(.{ 4.5, 2.5 }, .{ 4.5, 13.5 });
            try pen.polyline(&.{ .{ 4.5, 4.5 }, .{ 11.5, 8.5 }, .{ 11.5, 10 } });
            try pen.ring(.{ 11.5, 12 }, 2);
        },
        .rebase => {
            try pen.line(.{ 4.5, 2.5 }, .{ 4.5, 13.5 });
            try pen.polyline(&.{ .{ 11.5, 13.5 }, .{ 11.5, 8 } });
            try pen.arrow(.{ 11.5, 8 }, .{ 6, 3.5 });
        },
        .switch_to => try pen.arrow(.{ 2, 8 }, .{ 13.5, 8 }),
        .trash => {
            try pen.line(.{ 2.5, 4 }, .{ 13.5, 4 });
            try pen.polyline(&.{ .{ 6, 4 }, .{ 6, 2 }, .{ 10, 2 }, .{ 10, 4 } });
            try pen.polyline(&.{ .{ 4, 4 }, .{ 5, 14 }, .{ 11, 14 }, .{ 12, 4 } });
        },
        .stash => {
            try pen.polyline(&.{ .{ 2, 9 }, .{ 2, 14 }, .{ 14, 14 }, .{ 14, 9 } });
            try pen.arrow(.{ 8, 1.5 }, .{ 8, 10.5 });
        },
        .unstash => {
            try pen.polyline(&.{ .{ 2, 9 }, .{ 2, 14 }, .{ 14, 14 }, .{ 14, 9 } });
            try pen.arrow(.{ 8, 11 }, .{ 8, 1.5 });
        },
        .tag => {
            try pen.polyline(&.{ .{ 2.5, 2.5 }, .{ 8.5, 2.5 }, .{ 14, 8 }, .{ 8, 14 }, .{ 2.5, 8.5 }, .{ 2.5, 2.5 } });
            try pen.ring(.{ 5.75, 5.75 }, 1);
        },
        .commit => {
            try pen.ring(.{ 8, 8 }, 3);
            try pen.line(.{ 1, 8 }, .{ 5, 8 });
            try pen.line(.{ 11, 8 }, .{ 15, 8 });
        },
        .cherry_pick => {
            try pen.ring(.{ 4.5, 11.5 }, 2.5);
            try pen.ring(.{ 11.5, 11.5 }, 2.5);
            try pen.polyline(&.{ .{ 4.5, 9 }, .{ 9, 2.5 }, .{ 11.5, 9 } });
        },
        .reset => {
            try pen.line(.{ 3, 3 }, .{ 3, 13 });
            try pen.polyline(&.{ .{ 13, 3 }, .{ 6, 8 }, .{ 13, 13 } });
        },
    }
}

fn rad(degrees: f32) f32 {
    return degrees * std.math.pi / 180;
}

/// Strokes on the 16-point grid, scaled into place.
const Pen = struct {
    c: *ui.Canvas,
    origin: [2]f32,
    scale: f32,
    color: [4]f32,

    const width: f32 = 1.5;

    fn at(pen: *const Pen, p: [2]f32) [2]f32 {
        return .{ pen.origin[0] + p[0] * pen.scale, pen.origin[1] + p[1] * pen.scale };
    }

    /// A stroke from `a` to `b` (grid points), with a dot at its end to round the joins.
    fn line(pen: *const Pen, a: [2]f32, b: [2]f32) !void {
        const p = pen.at(a);
        const q = pen.at(b);
        const half = width / 2 * @max(1, pen.scale * 0.9);
        const dx = q[0] - p[0];
        const dy = q[1] - p[1];
        const span = @sqrt(dx * dx + dy * dy);
        if (span < 0.01) return;
        const nx = -dy / span * half;
        const ny = dx / span * half;
        const colors = .{ pen.color, pen.color, pen.color };
        try pen.c.triangle(.{ .{ p[0] + nx, p[1] + ny }, .{ q[0] + nx, q[1] + ny }, .{ q[0] - nx, q[1] - ny } }, colors);
        try pen.c.triangle(.{ .{ p[0] + nx, p[1] + ny }, .{ q[0] - nx, q[1] - ny }, .{ p[0] - nx, p[1] - ny } }, colors);
        try pen.joint(q, half);
    }

    fn joint(pen: *const Pen, p: [2]f32, half: f32) !void {
        const colors = .{ pen.color, pen.color, pen.color };
        const steps = 6;
        for (0..steps) |i| {
            const a0 = std.math.tau * @as(f32, @floatFromInt(i)) / steps;
            const a1 = std.math.tau * @as(f32, @floatFromInt(i + 1)) / steps;
            try pen.c.triangle(.{ p, .{ p[0] + half * @cos(a0), p[1] + half * @sin(a0) }, .{ p[0] + half * @cos(a1), p[1] + half * @sin(a1) } }, colors);
        }
    }

    fn polyline(pen: *const Pen, points: []const [2]f32) !void {
        for (points[0 .. points.len - 1], points[1..]) |a, b| try pen.line(a, b);
    }

    /// A stroke from `from` to `to` with an arrowhead at `to`.
    fn arrow(pen: *const Pen, from: [2]f32, to: [2]f32) !void {
        try pen.line(from, to);
        try pen.head(to, std.math.atan2(to[1] - from[1], to[0] - from[0]));
    }

    /// An open arrowhead at `tip`, pointing at `angle` (radians).
    fn head(pen: *const Pen, tip: [2]f32, angle: f32) !void {
        const size = 4;
        for ([_]f32{ angle + 2.4, angle - 2.4 }) |side| try pen.line(.{ tip[0] + size * @cos(side), tip[1] + size * @sin(side) }, tip);
    }

    /// An arc round `center`, `radius` grid points, from `from` to `to` degrees (clockwise).
    fn arc(pen: *const Pen, center: [2]f32, radius: f32, from: f32, to: f32) !void {
        const steps = 14;
        var previous = [2]f32{ center[0] + radius * @cos(rad(from)), center[1] + radius * @sin(rad(from)) };
        for (1..steps + 1) |i| {
            const angle = rad(from + (to - from) * @as(f32, @floatFromInt(i)) / steps);
            const next = [2]f32{ center[0] + radius * @cos(angle), center[1] + radius * @sin(angle) };
            try pen.line(previous, next);
            previous = next;
        }
    }

    fn ring(pen: *const Pen, center: [2]f32, radius: f32) !void {
        try pen.arc(center, radius, 0, 360);
    }
};
