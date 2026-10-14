//! A terminal-looking box of text output: light text on near-black, showing the last lines that
//! fit, with command lines (`$ ...`) in the theme's primary colour.
const std = @import("std");
const ui = @import("eggy").ui;

const background = ui.Color{ 0.07, 0.07, 0.08 };
const foreground = ui.Color{ 0.82, 0.82, 0.8 };
const text_size: f32 = 12;
const line_height = text_size * 1.45;
const padding: f32 = 10;

/// Add a `height` tall terminal showing `output` to `context`'s page. `output` must stay valid
/// until the page renders.
// ponytail: draws in the UI's proportional font; load a monospace one once Weeoui can draw two fonts from one atlas.
pub fn add(context: *ui.Context, output: []const u8, height: f32) void {
    const b = context.builder();
    const text = b.allocator.create([]const u8) catch return;
    text.* = output;
    // The page's own padding is 16 on each side.
    const width = @max(0, context.viewport.w - 32);
    const element = b.node(0, .{ .width = width, .height = height }, .{ .custom = .{ .context = @ptrCast(text), .draw = draw } }, &.{}) catch return;
    element.accessibility.label = "Output";
    context.element(element);
}

fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const output: *const []const u8 = @ptrCast(@alignCast(context));
    try c.roundRect(r, background, c.theme.radiusMd());

    // Clip to the inside, so long lines end at the edge as in a terminal.
    const inner = r.inset(padding);
    const previous = c.clip;
    c.clip = if (previous) |clip| clip.intersection(inner) else inner;
    defer c.clip = previous;

    var lines: [64][]const u8 = undefined;
    const shown = lastLines(output.*, lines[0..@min(lines.len, @as(usize, @intFromFloat(@max(1, inner.h / line_height))))]);
    for (shown, 0..) |line, i| {
        const row = ui.Rect{ .x = inner.x, .y = inner.y + @as(f32, @floatFromInt(i)) * line_height, .w = inner.w, .h = line_height };
        try c.textIn(row, line, text_size, if (std.mem.startsWith(u8, line, "$ ")) c.theme.primary else foreground, .start);
    }
}

/// The last `buffer.len` lines of `text` (fewer if it has fewer), oldest first.
fn lastLines(text: []const u8, buffer: [][]const u8) [][]const u8 {
    var count: usize = 0;
    var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (count < buffer.len) : (count += 1) buffer[buffer.len - 1 - count] = lines.next() orelse break;
    return buffer[buffer.len - count ..];
}

test "the terminal shows the last lines that fit, oldest first" {
    var buffer: [2][]const u8 = undefined;
    const shown = lastLines("one\ntwo\nthree\n", &buffer);
    try std.testing.expectEqual(@as(usize, 2), shown.len);
    try std.testing.expectEqualStrings("two", shown[0]);
    try std.testing.expectEqualStrings("three", shown[1]);
    try std.testing.expectEqual(@as(usize, 1), lastLines("only", &buffer).len);
}
