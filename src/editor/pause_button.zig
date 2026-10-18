//! The pause button on the editor's title bar, just left of the play button while the game
//! plays: two bars in the play button's box, lit while the game is paused.
const ui = @import("eggy").ui;
const L = ui.Layout;
const play_button = @import("play_button.zig");

/// Its element id, below `dock.first_id`.
pub const id: u32 = 0x5000_0003;
const gap: f32 = 6;

/// The button for a bar `bar_height` tall spanning `bar_width` from `bar_x`, beside the play
/// button. `paused` lights it.
/// All geometry is logical points; show only during play. Returns a frame-arena element,
/// propagating allocation errors; this does not pause the game until the host handles its ID.
///
/// ```zig
/// if (mode.playing())
///     context.element(try pause_button.element(b, mode.paused, 0, viewport.w, 34));
/// ```
pub fn element(b: L.Builder, paused: bool, bar_x: f32, bar_width: f32, bar_height: f32) !*L.Element {
    const glyph = try b.allocator.create(Glyph);
    glyph.* = .{ .paused = paused };
    const button = try b.node(id, .{ .width = play_button.width, .height = play_button.height, .z_index = 50 }, .{ .custom = .{ .context = glyph, .draw = draw } }, &.{});
    button.overlay = .{ .point = .init(bar_x + (bar_width - play_button.width) / 2 - gap - play_button.width, (bar_height - play_button.height) / 2) };
    button.cursor = .pointer;
    button.accessibility = .{ .role = .button, .label = if (paused) "Resume" else "Pause" };
    return button;
}

const Glyph = struct { paused: bool };

fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const glyph: *const Glyph = @ptrCast(@alignCast(context));
    try play_button.drawBox(c, r, glyph.paused, c.hot_id == id);
    const color = if (glyph.paused) c.theme.primary_foreground else c.theme.foreground;
    const center = r.center();
    const bar = ui.Rect{ .x = 0, .y = center.y - 5.5, .w = 3, .h = 11 };
    try c.roundRect(.{ .x = center.x - 4.5, .y = bar.y, .w = bar.w, .h = bar.h }, color, 1);
    try c.roundRect(.{ .x = center.x + 1.5, .y = bar.y, .w = bar.w, .h = bar.h }, color, 1);
}
