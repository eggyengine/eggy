//! A row of the Git panel's lists (a file, commit, branch, stash or remote): a status letter or
//! mark, its name, a dimmer detail, and a note on the right, highlighted when hovered or
//! selected. Pressing it selects it.
const std = @import("std");
const ui = @import("eggy").ui;
const icons = @import("icons.zig");

pub const height: f32 = 24;

pub const Row = struct {
    /// A status letter before the name (M, A, D, U...), in `letter_tone`.
    letter: ?u8 = null,
    letter_tone: icons.Tone = .muted,
    /// A mark before the name instead (the current branch's check).
    mark: ?icons.Icon = null,
    /// Text before the name, in the theme's primary colour (a commit's hash).
    lead: []const u8 = "",
    name: []const u8,
    /// Dimmer text after the name.
    detail: []const u8 = "",
    /// Text in the theme's primary colour after the detail (a commit's branches and tags).
    accent: []const u8 = "",
    /// Dim text kept to the right.
    note: []const u8 = "",
    selected: bool = false,
};

/// Add `row` to the open container, growing to fill the rest of it; `key` makes it unique on the
/// page. Returns true when it was pressed.
pub fn add(context: *ui.Context, key: []const u8, row: Row) bool {
    const id = context.idFor(key);
    const state = context.builder().allocator.create(State) catch return false;
    state.* = .{ .row = row, .id = id, .size = context.theme.small_text_size };
    const element = context.builder().node(id, .{ .height = height, .grow = 1, .min_width = 40 }, .{ .custom = .{ .context = state, .draw = draw } }, &.{}) catch return false;
    element.cursor = .pointer;
    element.accessibility = .{ .role = .button, .label = row.name };
    context.element(element);
    return context.activated(id);
}

const State = struct { row: Row, id: u32, size: f32 };

fn draw(raw: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const state: *const State = @ptrCast(@alignCast(raw));
    const row = state.row;
    if (row.selected) {
        try c.roundRectAlpha(r, c.theme.primary, c.theme.radiusSm(), 0.18);
    } else if (c.hot_id == state.id) try c.roundRect(r, c.theme.muted, c.theme.radiusSm());

    const previous = c.clip;
    c.clip = if (previous) |clip| clip.intersection(r) else r;
    defer c.clip = previous;

    // The note keeps to the right; the rest runs left to right before it, cut off at it.
    var right = r.x + r.w - 6;
    if (row.note.len > 0) {
        const width = c.font.measure(row.note, state.size);
        right -= width;
        try c.textIn(.{ .x = right, .y = r.y, .w = width, .h = r.h }, row.note, state.size, c.theme.muted_foreground, .start);
        right -= 10;
    }
    const room = ui.Rect{ .x = r.x, .y = r.y, .w = @max(0, right - r.x), .h = r.h };
    c.clip = c.clip.?.intersection(room);
    var x = r.x + 6;
    if (row.letter) |letter| {
        try c.textIn(.{ .x = x, .y = r.y, .w = 12, .h = r.h }, &.{letter}, state.size, icons.toneColor(c.theme, row.letter_tone), .center);
        x += 18;
    } else if (row.mark) |mark| {
        try icons.draw(c, mark, .{ .x = x, .y = r.y + (r.h - 12) / 2, .w = 12, .h = 12 }, c.theme.primary ++ [_]f32{1});
        x += 18;
    }
    for ([_]struct { text: []const u8, color: ui.Color }{
        .{ .text = row.lead, .color = c.theme.primary },
        .{ .text = row.name, .color = c.theme.foreground },
        .{ .text = row.detail, .color = c.theme.muted_foreground },
        .{ .text = row.accent, .color = c.theme.primary },
    }) |part| {
        if (part.text.len == 0 or x >= right) continue;
        const width = c.font.measure(part.text, state.size);
        try c.textIn(.{ .x = x, .y = r.y, .w = width + 2, .h = r.h }, part.text, state.size, part.color, .start);
        x += width + 8;
    }
}

/// Text that takes the rest of its row and is cut off where it doesn't fit, rather than
/// pushing the row wider (a long branch name).
pub fn clippedText(context: *ui.Context, value: []const u8, tone: icons.Tone) void {
    const state = context.builder().allocator.create(Clipped) catch return;
    state.* = .{ .value = value, .tone = tone, .size = context.theme.text_size };
    const element = context.builder().node(0, .{ .height = height, .grow = 1, .min_width = 20 }, .{ .custom = .{ .context = state, .draw = drawClipped } }, &.{}) catch return;
    element.accessibility = .{ .role = .label, .label = value };
    context.element(element);
}

const Clipped = struct { value: []const u8, tone: icons.Tone, size: f32 };

fn drawClipped(raw: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const state: *const Clipped = @ptrCast(@alignCast(raw));
    const previous = c.clip;
    c.clip = if (previous) |clip| clip.intersection(r) else r;
    defer c.clip = previous;
    try c.textIn(r, state.value, state.size, icons.toneColor(c.theme, state.tone), .start);
}
