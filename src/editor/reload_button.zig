//! The Reload button on the editor's title bar, just right of the play button: a circular arrow
//! in the play button's box, lit once a rebuild made a new editor.
const std = @import("std");
const ui = @import("eggy").ui;
const L = ui.Layout;
const play_button = @import("play_button.zig");

/// Its element id, below `dock.first_id`.
pub const id: u32 = 0x5000_0002;
const gap: f32 = 6;

/// The button for a bar `bar_height` tall spanning `bar_width` from `bar_x`, beside the play
/// button. `ready` lights it: a rebuilt editor is waiting.
/// All geometry is logical points. Returns a frame-arena element; allocation errors
/// propagate. The editor host handles its ID and owns rebuild/reload side effects.
///
/// ```zig
/// context.element(try reload_button.element(b, rebuilt, 0, viewport.w, 34));
/// ```
pub fn element(b: L.Builder, ready: bool, bar_x: f32, bar_width: f32, bar_height: f32) !*L.Element {
    const glyph = try b.allocator.create(Glyph);
    glyph.* = .{ .ready = ready };
    const button = try b.node(id, .{ .width = play_button.width, .height = play_button.height, .z_index = 50 }, .{ .custom = .{ .context = glyph, .draw = draw } }, &.{});
    button.overlay = .{ .point = .init(bar_x + (bar_width + play_button.width) / 2 + gap, (bar_height - play_button.height) / 2) };
    button.cursor = .pointer;
    button.accessibility = .{ .role = .button, .label = "Reload", .description = "Rebuild the project's editor and open it" };
    return button;
}

const Glyph = struct { ready: bool };

fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const glyph: *const Glyph = @ptrCast(@alignCast(context));
    try play_button.drawBox(c, r, glyph.ready, c.hot_id == id);

    // Three quarters of a ring, clockwise from the top, then an arrowhead at its end.
    const color = (if (glyph.ready) c.theme.primary_foreground else c.theme.foreground) ++ [_]f32{1};
    const center = r.center();
    const radius: f32 = 5.5;
    const thickness: f32 = 1.6;
    const start = -std.math.pi / 2.0 + 0.5;
    const sweep = 1.5 * std.math.pi;
    const segments = 18;
    for (0..segments) |i| {
        const a0 = start + sweep * @as(f32, @floatFromInt(i)) / segments;
        const a1 = start + sweep * @as(f32, @floatFromInt(i + 1)) / segments;
        const inner0 = point(center, radius - thickness / 2, a0);
        const outer0 = point(center, radius + thickness / 2, a0);
        const inner1 = point(center, radius - thickness / 2, a1);
        const outer1 = point(center, radius + thickness / 2, a1);
        try c.triangle(.{ inner0, outer0, outer1 }, .{ color, color, color });
        try c.triangle(.{ inner0, outer1, inner1 }, .{ color, color, color });
    }
    // The arrowhead points on along the ring.
    const end = start + sweep;
    const tip = point(center, radius, end + 0.55);
    try c.triangle(.{ point(center, radius - 3, end), point(center, radius + 3, end), tip }, .{ color, color, color });
}

fn point(center: ui.Vec2, radius: f32, angle: f32) [2]f32 {
    return .{ center.x + radius * @cos(angle), center.y + radius * @sin(angle) };
}
