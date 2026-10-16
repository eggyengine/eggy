//! The Simulate button on the editor's title bar, just left of the play button while the game
//! doesn't run: it runs the game, as Play does, but the Scene panel keeps its own camera, so the
//! game is watched from wherever the panel looks (Unreal's Simulate).
const ui = @import("eggy").ui;
const L = ui.Layout;
const play_button = @import("play_button.zig");

/// Its element id, below `dock.first_id`.
pub const id: u32 = 0x5000_0004;
const gap: f32 = 6;

/// The button for a bar `bar_height` tall spanning `bar_width` from `bar_x`, beside the play
/// button.
pub fn element(b: L.Builder, bar_x: f32, bar_width: f32, bar_height: f32) !*L.Element {
    const button = try b.node(id, .{ .width = play_button.width, .height = play_button.height, .z_index = 50 }, .{ .custom = .{ .context = undefined, .draw = draw } }, &.{});
    button.overlay = .{ .point = .init(bar_x + (bar_width - play_button.width) / 2 - gap - play_button.width, (bar_height - play_button.height) / 2) };
    button.cursor = .pointer;
    button.accessibility = .{ .role = .button, .label = "Simulate" };
    return button;
}

/// A play triangle inside a ring: the game running, seen from round about.
fn draw(_: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    try play_button.drawBox(c, r, false, c.hot_id == id);
    const center = r.center();
    const color = c.theme.foreground ++ [_]f32{1};
    try c.roundRectStroke(.{ .x = center.x - 7, .y = center.y - 7, .w = 14, .h = 14 }, c.theme.foreground, 7, 1.5);
    const half: f32 = 3.5;
    try c.triangle(.{ .{ center.x - half + 1, center.y - half }, .{ center.x + half + 1, center.y }, .{ center.x - half + 1, center.y + half } }, .{ color, color, color });
}
