//! A blend state's clips drawn where they sit: along a line for a one-axis blend, on a square
//! for two axes. Dragging a point moves it (one-axis points stay in order); pressing one picks
//! it. The scale is kept while a point is dragged, so it doesn't run from the pointer.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const format = eggy.assets.animation_graph;
const gizmo = @import("../scene_view/gizmo.zig");

const point_radius: f32 = 6;
const reach: f32 = 10;
/// Room above and below the plotted square for the axes' names and ranges.
const inset: f32 = 22;

/// What a pointer event did.
pub const Result = struct { used: bool = false, changed: bool = false };

pub const BlendPlot = struct {
    /// Where it was drawn last frame, in page units.
    area: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Each axis's low and high end, fixed while a point is dragged.
    range: [2][2]f32 = .{ .{ -1, 1 }, .{ -1, 1 } },
    axes: usize = 1,
    dragging: ?usize = null,
    /// The point last pressed, lit.
    picked: ?usize = null,

    pub fn holding(self: *const BlendPlot) bool {
        return self.dragging != null;
    }

    /// Lay the plot out `width` wide for `points` on `axes` (1 or 2) axes named `axis_names`,
    /// each labelled by `labels`.
    pub fn build(self: *BlendPlot, context: *ui.Context, points: []const format.Point, axes: usize, axis_names: [2][]const u8, labels: []const []const u8, width: f32) !void {
        self.axes = axes;
        if (self.dragging == null) self.range = rangeOf(points, axes);
        if (self.picked) |index| if (index >= points.len) {
            self.picked = null;
        };
        const arena = context.builder().allocator;
        const drawing = try arena.create(Drawing);
        const placed = try arena.alloc(Drawing.Dot, points.len);
        for (placed, points, 0..) |*dot, point, index| dot.* = .{ .at = point.at, .label = if (index < labels.len) labels[index] else "", .lit = self.picked == index or self.dragging == index };
        drawing.* = .{ .plot = self, .dots = placed, .axis_names = axis_names };
        const height: f32 = if (axes == 1) 88 else width;
        const element = try context.builder().node(0, .{ .width = width, .height = height }, .{ .custom = .{ .context = drawing, .draw = Drawing.draw } }, &.{});
        element.accessibility = .{ .role = .image, .label = "Blend points" };
        context.element(element);
    }

    /// A pointer event over the page, for `points`, edited in place. One-axis points are kept
    /// in order.
    pub fn pointer(self: *BlendPlot, points: []format.Point, event: ui.input.Event) Result {
        switch (event) {
            .pointer_down => |down| {
                if (down.button != .left or !self.area.contains(down.position.x, down.position.y)) return .{};
                const index = self.pointAt(points, down.position) orelse return .{ .used = true };
                self.picked = index;
                self.dragging = index;
                return .{ .used = true };
            },
            .pointer_move => |at| {
                const index = self.dragging orelse return .{};
                const value = self.valueAt(at);
                var point = &points[index];
                const moved = if (self.axes == 1) [2]f32{ value[0], 0 } else value;
                if (std.meta.eql(moved, point.at)) return .{ .used = true };
                point.at = moved;
                if (self.axes == 1) self.dragging = keepInOrder(points, index);
                self.picked = self.dragging;
                return .{ .used = true, .changed = true };
            },
            .pointer_up => {
                if (self.dragging == null) return .{};
                self.dragging = null;
                return .{ .used = true };
            },
            else => return .{},
        }
    }

    fn pointAt(self: *const BlendPlot, points: []const format.Point, at: ui.Vec2) ?usize {
        var best: ?usize = null;
        var best_distance = reach * reach;
        for (points, 0..) |point, index| {
            const spot = self.spotOf(point.at);
            const dx = spot.x - at.x;
            const dy = spot.y - at.y;
            if (dx * dx + dy * dy <= best_distance) {
                best = index;
                best_distance = dx * dx + dy * dy;
            }
        }
        return best;
    }

    /// The square the points are plotted in, inside the area.
    fn field(self: *const BlendPlot) ui.Rect {
        const r = self.area;
        if (self.axes == 1) return .{ .x = r.x + inset, .y = r.y + r.h / 2, .w = @max(1, r.w - 2 * inset), .h = 0 };
        return .{ .x = r.x + 10, .y = r.y + inset, .w = @max(1, r.w - 20), .h = @max(1, r.h - 2 * inset) };
    }

    fn spotOf(self: *const BlendPlot, at: [2]f32) ui.Vec2 {
        const f = self.field();
        const x = f.x + fraction(self.range[0], at[0]) * f.w;
        if (self.axes == 1) return .{ .x = x, .y = f.y };
        return .{ .x = x, .y = f.y + f.h - fraction(self.range[1], at[1]) * f.h };
    }

    /// The value under `at`, within the range, to two decimals.
    fn valueAt(self: *const BlendPlot, at: ui.Vec2) [2]f32 {
        const f = self.field();
        const across = std.math.clamp((at.x - f.x) / f.w, 0, 1);
        const up = if (self.axes == 1) 0 else std.math.clamp((f.y + f.h - at.y) / f.h, 0, 1);
        return .{ round(lerp(self.range[0], across)), if (self.axes == 1) 0 else round(lerp(self.range[1], up)) };
    }
};

/// Each axis's ends: round the points with a margin, at least -1 to 1.
fn rangeOf(points: []const format.Point, axes: usize) [2][2]f32 {
    var range: [2][2]f32 = .{ .{ -1, 1 }, .{ -1, 1 } };
    for (points) |point| for (0..axes) |axis| {
        range[axis][0] = @min(range[axis][0], point.at[axis]);
        range[axis][1] = @max(range[axis][1], point.at[axis]);
    };
    for (&range) |*ends| {
        const margin = (ends[1] - ends[0]) * 0.1;
        ends.* = .{ @floor(ends[0] - margin), @ceil(ends[1] + margin) };
    }
    return range;
}

/// Move point `index` past its neighbours until the list is in order; returns where it is now.
fn keepInOrder(points: []format.Point, index: usize) usize {
    var at = index;
    while (at > 0 and points[at - 1].at[0] > points[at].at[0]) : (at -= 1) std.mem.swap(format.Point, &points[at - 1], &points[at]);
    while (at + 1 < points.len and points[at + 1].at[0] < points[at].at[0]) : (at += 1) std.mem.swap(format.Point, &points[at + 1], &points[at]);
    return at;
}

fn fraction(ends: [2]f32, value: f32) f32 {
    return (value - ends[0]) / @max(0.0001, ends[1] - ends[0]);
}

fn lerp(ends: [2]f32, t: f32) f32 {
    return ends[0] + (ends[1] - ends[0]) * t;
}

fn round(value: f32) f32 {
    return @round(value * 100) / 100;
}

/// One frame's drawing.
const Drawing = struct {
    plot: *BlendPlot,
    dots: []const Dot,
    axis_names: [2][]const u8,

    const Dot = struct { at: [2]f32, label: []const u8, lit: bool };

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Drawing = @ptrCast(@alignCast(context));
        const plot = self.plot;
        plot.area = r;
        const t = c.theme;
        try c.roundRect(r, t.muted, 8);
        const f = plot.field();
        const faint = [4]f32{ t.border[0], t.border[1], t.border[2], 1 };
        var buffer: [2][32]u8 = undefined;

        if (plot.axes == 1) {
            try gizmo.line(c, .{ .x = f.x, .y = f.y }, .{ .x = f.x + f.w, .y = f.y }, 1.5, faint);
            const low = std.fmt.bufPrint(&buffer[0], "{d}", .{plot.range[0][0]}) catch "";
            const high = std.fmt.bufPrint(&buffer[1], "{d}", .{plot.range[0][1]}) catch "";
            try c.textIn(.{ .x = r.x + 4, .y = r.y + r.h - 16, .w = 60, .h = 14 }, low, 11, t.muted_foreground, .start);
            try c.textIn(.{ .x = r.x + r.w - 64, .y = r.y + r.h - 16, .w = 60, .h = 14 }, high, 11, t.muted_foreground, .end);
            try c.textIn(.{ .x = r.x, .y = r.y + r.h - 16, .w = r.w, .h = 14 }, self.axis_names[0], 11, t.muted_foreground, .center);
        } else {
            try c.roundRectStroke(f, t.border, 2, 1);
            // The zero lines, when the range holds them.
            if (plot.range[0][0] < 0 and plot.range[0][1] > 0) {
                const x = plot.spotOf(.{ 0, 0 }).x;
                try gizmo.line(c, .{ .x = x, .y = f.y }, .{ .x = x, .y = f.y + f.h }, 1, faint);
            }
            if (plot.range[1][0] < 0 and plot.range[1][1] > 0) {
                const y = plot.spotOf(.{ 0, 0 }).y;
                try gizmo.line(c, .{ .x = f.x, .y = y }, .{ .x = f.x + f.w, .y = y }, 1, faint);
            }
            const across = std.fmt.bufPrint(&buffer[0], "{s}  {d} to {d}", .{ if (self.axis_names[0].len > 0) self.axis_names[0] else "across", plot.range[0][0], plot.range[0][1] }) catch "";
            try c.textIn(.{ .x = f.x, .y = f.y + f.h + 2, .w = f.w, .h = 16 }, across, 11, t.muted_foreground, .center);
            const up = std.fmt.bufPrint(&buffer[1], "{s}  {d} to {d}", .{ if (self.axis_names[1].len > 0) self.axis_names[1] else "up", plot.range[1][0], plot.range[1][1] }) catch "";
            try c.textIn(.{ .x = f.x, .y = r.y + 4, .w = f.w, .h = 16 }, up, 11, t.muted_foreground, .center);
        }

        for (self.dots, 0..) |dot, index| {
            const spot = plot.spotOf(dot.at);
            const radius = if (dot.lit) point_radius + 1.5 else point_radius;
            try c.roundRect(.{ .x = spot.x - radius, .y = spot.y - radius, .w = radius * 2, .h = radius * 2 }, if (dot.lit) t.primary else t.foreground, radius);
            // One-axis labels take turns above and below the line, so neighbours don't overlap.
            const above = plot.axes == 2 or index % 2 == 0;
            const label_y = if (above) spot.y - radius - 16 else spot.y + radius + 2;
            try c.textIn(.{ .x = spot.x - 60, .y = label_y, .w = 120, .h = 14 }, dot.label, 11, if (dot.lit) t.foreground else t.muted_foreground, .center);
        }
    }
};
