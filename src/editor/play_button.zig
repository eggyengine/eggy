//! The play button in the middle of the editor's title bar: a triangle that starts the game, which
//! becomes a stop square while it plays.
const std = @import("std");
const ui = @import("eggy").ui;
const L = ui.Layout;

/// Its element id, below `dock.first_id`.
pub const id: u32 = 0x5000_0001;
pub const width: f32 = 34;
const height: f32 = 26;

/// The button for a bar `bar_height` tall spanning `bar_width` from `bar_x`, centred on it. It
/// floats over the bar, so it stays centred whatever the menus and window buttons take.
pub fn element(b: L.Builder, playing: bool, bar_x: f32, bar_width: f32, bar_height: f32) !*L.Element {
    const glyph = try b.allocator.create(Glyph);
    glyph.* = .{ .playing = playing };
    const button = try b.node(id, .{ .width = width, .height = height, .z_index = 50 }, .{ .custom = .{ .context = glyph, .draw = draw } }, &.{});
    button.overlay = .{ .point = .init(bar_x + (bar_width - width) / 2, (bar_height - height) / 2) };
    button.cursor = .pointer;
    button.accessibility = .{ .role = .button, .label = if (playing) "Stop" else "Play" };
    return button;
}

const Glyph = struct { playing: bool };

fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const glyph: *const Glyph = @ptrCast(@alignCast(context));
    const hot = c.hot_id == id;

    // A bordered box; playing, it stays lit, otherwise it lights up under the pointer.
    const radius = c.theme.radiusMd();
    try c.roundRect(r, c.theme.input, radius);
    const fill = if (glyph.playing) c.theme.primary else if (hot) c.theme.accent else c.theme.secondary;
    try c.roundRect(r.inset(1), fill, @max(0, radius - 1));

    const center = r.center();
    if (glyph.playing) {
        const side: f32 = 9;
        try c.roundRect(.{ .x = center.x - side / 2, .y = center.y - side / 2, .w = side, .h = side }, c.theme.primary_foreground, 1.5);
    } else {
        // A right-pointing triangle, nudged right so it looks centred.
        const half: f32 = 6;
        const color = c.theme.foreground ++ [_]f32{1};
        try c.triangle(.{ .{ center.x - half + 1.5, center.y - half }, .{ center.x + half + 1.5, center.y }, .{ center.x - half + 1.5, center.y + half } }, .{ color, color, color });
    }
}
