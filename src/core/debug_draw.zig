//! Frame-owned world-space debug primitives drawn as a non-interactive overlay.
const std = @import("std");
const ui = @import("weeoui");
const camera = @import("camera.zig");
const game_ui = @import("game_ui/game_ui.zig");
const vit = @import("vitellus");
const math = @import("eggenvector");
const transform = @import("transform.zig");
pub const support: @import("support.zig").Support = .available;
pub const max_lines = 1024;
pub const max_labels = 128;

pub const Line = struct { from_m: math.Vec3, to_m: math.Vec3, color: [4]f32 };
pub const Label = struct {
    position_m: math.Vec3,
    bytes: [256]u8 = undefined,
    len: u16,
};

/// Main-thread transient drawing. Requests are copied and cleared at the next host frame.
/// Explicit capacity errors leave already-recorded primitives intact.
pub const DebugDraw = struct {
    lines: [max_lines]Line = undefined,
    line_count: usize = 0,
    labels: [max_labels]Label = undefined,
    label_count: usize = 0,
    overlay: ?*game_ui.Overlay = null,

    pub fn clear(self: *DebugDraw) void {
        self.line_count = 0;
        self.label_count = 0;
    }

    /// Release a lazily created renderer before graphics shutdown or game-library unload.
    pub fn deinit(self: *DebugDraw, gpa: std.mem.Allocator) void {
        if (self.overlay) |overlay| {
            overlay.deinit();
            gpa.destroy(overlay);
        }
        self.* = .{};
    }

    pub fn line(self: *DebugDraw, from_m: math.Vec3, to_m: math.Vec3, color: [4]f32) !void {
        try validatePoint(from_m);
        try validatePoint(to_m);
        try validateColor(color);
        if (self.line_count == max_lines) return error.DebugDrawCapacity;
        self.lines[self.line_count] = .{ .from_m = from_m, .to_m = to_m, .color = color };
        self.line_count += 1;
    }

    /// Record all twelve box edges atomically.
    pub fn box(self: *DebugDraw, min_m: math.Vec3, max_m: math.Vec3, color: [4]f32) !void {
        try validatePoint(min_m);
        try validatePoint(max_m);
        const low = min_m.toArray();
        const high_m = max_m.toArray();
        try validateColor(color);
        for (low, high_m) |min, max| if (min > max) return error.InvalidDebugBounds;
        if (max_lines - self.line_count < 12) return error.DebugDrawCapacity;
        for (0..8) |corner| {
            for (0..3) |axis| {
                const bit = @as(usize, 1) << @intCast(axis);
                if (corner & bit != 0) continue;
                var from: [3]f32 = undefined;
                var to: [3]f32 = undefined;
                for (0..3) |dimension| {
                    const high = corner & (@as(usize, 1) << @intCast(dimension)) != 0;
                    from[dimension] = if (high) high_m[dimension] else low[dimension];
                    to[dimension] = from[dimension];
                }
                to[axis] = high_m[axis];
                try self.line(.fromArray(from), .fromArray(to), color);
            }
        }
    }

    /// Copy a UTF-8 label of at most 256 bytes; displayed at a fixed screen-space size.
    pub fn text(self: *DebugDraw, position_m: math.Vec3, message: []const u8) !void {
        try validatePoint(position_m);
        if (message.len > 256) return error.DebugLabelTooLong;
        if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
        if (self.label_count == max_labels) return error.DebugDrawCapacity;
        const label = &self.labels[self.label_count];
        label.* = .{ .position_m = position_m, .len = @intCast(message.len) };
        @memcpy(label.bytes[0..message.len], message);
        self.label_count += 1;
    }

    /// Draw through the supplied camera without depth testing or input capture.
    /// The host owns `draw`; this only records an overlay and never submits it.
    pub fn render(self: *DebugDraw, gpa: std.mem.Allocator, device: vit.Device, queue: vit.Queue, draw: game_ui.DrawContext, view: camera.View) !void {
        if (self.line_count == 0 and self.label_count == 0) return;
        if (self.overlay == null) {
            const overlay = try gpa.create(game_ui.Overlay);
            errdefer gpa.destroy(overlay);
            overlay.* = try game_ui.Overlay.init(gpa, device, queue, draw.color_format);
            self.overlay = overlay;
        }
        const overlay = self.overlay.?;
        overlay.begin(draw, 0);
        const builder = overlay.context.builder();
        const paint = Paint{ .debug = self, .matrix = transform.columns(view.viewProjection(draw.viewport.w / draw.viewport.h)) };
        const node = try builder.node(0, .{ .width = draw.viewport.w, .height = draw.viewport.h }, .{ .custom = .{ .context = &paint, .draw = Paint.draw } }, &.{});
        node.overlay = .{ .point = .init(draw.viewport.x, draw.viewport.y) };
        node.accessibility.role = .ignored;
        overlay.context.element(node);
        _ = try overlay.render(draw);
    }
};

const Paint = struct {
    debug: *const DebugDraw,
    matrix: [4][4]f32,

    fn draw(raw: *const anyopaque, canvas: *ui.Canvas, rect: ui.Rect) anyerror!void {
        const self: *const Paint = @ptrCast(@alignCast(raw));
        for (self.debug.lines[0..self.debug.line_count]) |segment| {
            const clipped = clippedLine(self.matrix, segment.from_m, segment.to_m) orelse continue;
            const from = screen(clipped[0], rect);
            const to = screen(clipped[1], rect);
            const dx = to[0] - from[0];
            const dy = to[1] - from[1];
            const length = @sqrt(dx * dx + dy * dy);
            if (length < 0.01) continue;
            const nx = -dy / length;
            const ny = dx / length;
            const color = segment.color;
            try canvas.triangle(.{ .{ from[0] + nx, from[1] + ny }, .{ to[0] + nx, to[1] + ny }, .{ to[0] - nx, to[1] - ny } }, .{ color, color, color });
            try canvas.triangle(.{ .{ from[0] + nx, from[1] + ny }, .{ to[0] - nx, to[1] - ny }, .{ from[0] - nx, from[1] - ny } }, .{ color, color, color });
        }
        for (self.debug.labels[0..self.debug.label_count]) |label| {
            const clip = toClip(self.matrix, label.position_m);
            if (clip[3] <= 0 or clip[2] < 0 or clip[2] > clip[3]) continue;
            const point = screen(clip, rect);
            try canvas.text(point[0], point[1], label.bytes[0..label.len], 14, .{ 1, 1, 1 });
        }
    }
};

fn validatePoint(point: math.Vec3) !void {
    for (point.toArray()) |value| if (!std.math.isFinite(value)) return error.InvalidDebugPoint;
}

fn validateColor(color: [4]f32) !void {
    for (color) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidDebugColor;
}

fn toClip(matrix: [4][4]f32, point: math.Vec3) @Vector(4, f32) {
    var clip: @Vector(4, f32) = matrix[3];
    for (0..3, point.toArray()) |axis, value| clip += @as(@Vector(4, f32), matrix[axis]) * @as(@Vector(4, f32), @splat(value));
    return clip;
}

fn screen(clip: @Vector(4, f32), rect: ui.Rect) [2]f32 {
    return .{ rect.x + (clip[0] / clip[3] + 1) * rect.w / 2, rect.y + (1 - clip[1] / clip[3]) * rect.h / 2 };
}

/// Clip in homogeneous coordinates, including lines crossing the camera's near plane.
fn clippedLine(matrix: [4][4]f32, from: math.Vec3, to: math.Vec3) ?[2]@Vector(4, f32) {
    var a = toClip(matrix, from);
    var b = toClip(matrix, to);
    const planes = [_]@Vector(4, f32){
        .{ 1, 0, 0, 1 },  .{ -1, 0, 0, 1 }, .{ 0, 1, 0, 1 },
        .{ 0, -1, 0, 1 }, .{ 0, 0, 1, 0 },  .{ 0, 0, -1, 1 },
    };
    for (planes) |plane| {
        const da = @reduce(.Add, a * plane);
        const db = @reduce(.Add, b * plane);
        if (da < 0 and db < 0) return null;
        if (da < 0 or db < 0) {
            const hit = a + (b - a) * @as(@Vector(4, f32), @splat(da / (da - db)));
            if (da < 0) a = hit else b = hit;
        }
    }
    if (a[3] <= 0.000001 or b[3] <= 0.000001) return null;
    return .{ a, b };
}

test "debug boxes reserve twelve edges and requests validate before recording" {
    var debug = DebugDraw{};
    try debug.box(.splat(-1), .one, @splat(1));
    try std.testing.expectEqual(@as(usize, 12), debug.line_count);
    try std.testing.expectError(error.InvalidDebugBounds, debug.box(.init(2, 0, 0), .one, @splat(1)));
    try std.testing.expectError(error.InvalidDebugPoint, debug.line(.init(std.math.nan(f32), 0, 0), .zero, @splat(1)));
    debug.line_count = max_lines - 11;
    try std.testing.expectError(error.DebugDrawCapacity, debug.box(.zero, .one, @splat(1)));
    try std.testing.expectEqual(max_lines - 11, debug.line_count);
    debug.clear();
    var message = [_]u8{ 'h', 'i' };
    try debug.text(.zero, &message);
    message[0] = 'x';
    try std.testing.expectEqualStrings("hi", debug.labels[0].bytes[0..2]);
    try std.testing.expectError(error.DebugLabelTooLong, debug.text(.zero, &@as([257]u8, @splat('x'))));
}

test "debug lines clip across the near plane and reject segments behind the camera" {
    const matrix = transform.columns(camera.View.lookingAt(.zero, .forward, .{}).viewProjection(1));
    const clipped = clippedLine(matrix, .init(0, 0, 1), .init(0, 0, -2)).?;
    try std.testing.expect(clipped[0][3] > 0);
    try std.testing.expect(clipped[0][2] >= -0.00001);
    try std.testing.expect(clippedLine(matrix, .init(0, 0, 1), .init(0, 0, 2)) == null);
}
