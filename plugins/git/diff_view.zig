//! A diff in the Git panel: a line per row, added lines on green, removed on red, hunk headers
//! and file headers picked out. Only the rows on screen are drawn, so a long diff costs no more
//! than a short one.
const std = @import("std");
const ui = @import("eggy").ui;
const Diff = @import("repo.zig").Diff;
const icons = @import("icons.zig");

const row_height: f32 = 17;
const padding: f32 = 8;
/// The most lines shown; the rest are left out with a note.
const max_lines = 20_000;

/// Add `diff` to the open container, as wide as it and as tall as its lines. `diff` must stay
/// alive until the frame is drawn (the repository keeps it until its next update).
pub fn add(context: *ui.Context, diff: *const Diff) void {
    const shown = @min(diff.lines.len, max_lines);
    const state = context.builder().allocator.create(State) catch return;
    state.* = .{ .diff = diff, .shown = shown, .size = context.theme.small_text_size - 1 };
    const rows: f32 = @floatFromInt(shown + @intFromBool(shown < diff.lines.len));
    const element = context.builder().node(0, .{ .height = rows * row_height + 2 * padding, .grow = 1 }, .{ .custom = .{ .context = state, .draw = draw } }, &.{}) catch return;
    element.accessibility = .{ .role = .log, .label = "Diff" };
    context.element(element);
    // Rows have no other size: stretch across the container.
    element.style.width = context.contentWidth();
}

const State = struct { diff: *const Diff, shown: usize, size: f32 };

fn draw(raw: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const state: *const State = @ptrCast(@alignCast(raw));
    try c.roundRect(r, c.theme.card, c.theme.radiusSm());
    const previous = c.clip;
    const inner = r.inset(padding);
    c.clip = if (previous) |clip| clip.intersection(inner) else inner;
    defer c.clip = previous;
    const visible = c.clip.?;

    // Only the rows the clip shows.
    const first: usize = @intFromFloat(@max(0, @floor((visible.y - inner.y) / row_height)));
    const last: usize = @min(state.shown, @as(usize, @intFromFloat(@max(0, @ceil((visible.y + visible.h - inner.y) / row_height)))));
    for (first..last) |index| {
        const line = state.diff.line(index);
        const y = inner.y + @as(f32, @floatFromInt(index)) * row_height;
        const look = lookOf(line);
        const band = ui.Rect{ .x = r.x, .y = y, .w = r.w, .h = row_height };
        switch (look) {
            .added => try c.rectAlpha(band, icons.toneColor(c.theme, .added), 0.14),
            .removed => try c.rectAlpha(band, icons.toneColor(c.theme, .removed), 0.14),
            else => {},
        }
        const color: ui.Color = switch (look) {
            .added => icons.toneColor(c.theme, .added),
            .removed => icons.toneColor(c.theme, .removed),
            .hunk => c.theme.primary,
            .header => c.theme.muted_foreground,
            .plain => c.theme.foreground,
        };
        try c.textIn(.{ .x = inner.x, .y = y, .w = inner.w, .h = row_height }, line, state.size, color, .start);
    }
    if (state.shown < state.diff.lines.len and last == state.shown) {
        const y = inner.y + @as(f32, @floatFromInt(state.shown)) * row_height;
        var buffer: [64]u8 = undefined;
        const note = std.fmt.bufPrint(&buffer, "{d} more lines left out", .{state.diff.lines.len - state.shown}) catch "";
        try c.textIn(.{ .x = inner.x, .y = y, .w = inner.w, .h = row_height }, note, state.size, c.theme.muted_foreground, .start);
    }
}

const Look = enum { plain, added, removed, hunk, header };

/// How a diff line is shown, from how it starts.
fn lookOf(line: []const u8) Look {
    if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---")) return .header;
    if (std.mem.startsWith(u8, line, "diff ") or std.mem.startsWith(u8, line, "index ") or std.mem.startsWith(u8, line, "commit ")) return .header;
    if (std.mem.startsWith(u8, line, "@@")) return .hunk;
    if (std.mem.startsWith(u8, line, "+")) return .added;
    if (std.mem.startsWith(u8, line, "-")) return .removed;
    return .plain;
}

test "diff lines are told apart by how they start" {
    try std.testing.expectEqual(Look.header, lookOf("+++ b/src/main.zig"));
    try std.testing.expectEqual(Look.added, lookOf("+    const x = 1;"));
    try std.testing.expectEqual(Look.removed, lookOf("-old"));
    try std.testing.expectEqual(Look.hunk, lookOf("@@ -1,4 +1,5 @@"));
    try std.testing.expectEqual(Look.plain, lookOf(" context"));
}
