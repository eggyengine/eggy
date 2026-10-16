//! Small layout touches for pages built with `ui.Context` (Preferences, the Inspector, the
//! Hierarchy): restyling the element just added, since `Context`'s widgets and containers take
//! no style of their own.
const std = @import("std");
const ui = @import("eggy").ui;

/// Make the element just added (a container `begin` made) take no presses itself, leaving them
/// to what it holds. weeoui gives containers ids, and a container exactly the size of the one
/// thing in it (a list of one row) can win the press over it.
// ponytail: weeoui's hoveredWidget breaks a tie in area by hash map order; prefer the element painted later there, then drop this.
pub fn passThrough(context: *ui.Context) void {
    if (context.last_added) |element| element.id = 0;
}

/// Restyle the element `context` added last: a widget, or a container just ended. `layout`
/// sets the fields given; a container keeps its children.
pub fn restyle(context: *ui.Context, layout: struct {
    width: ?f32 = null,
    height: ?f32 = null,
    grow: ?f32 = null,
    gap: ?f32 = null,
    direction: ?@FieldType(ui.Layout.Style, "direction") = null,
    align_items: ?@FieldType(ui.Layout.Style, "align_items") = null,
    padding: ?@FieldType(ui.Layout.Style, "padding") = null,
}) void {
    const element = context.last_added orelse return;
    if (layout.width) |width| element.style.width = width;
    if (layout.height) |height| element.style.height = height;
    if (layout.grow) |grow| element.style.grow = grow;
    if (layout.gap) |gap| element.style.gap = gap;
    if (layout.direction) |direction| element.style.direction = direction;
    if (layout.align_items) |align_items| element.style.align_items = align_items;
    if (layout.padding) |padding| element.style.padding = padding;
    // Rows keep to one line, and cards fill the width rather than stopping at 640.
    element.style.wrap = false;
    element.style.max_width = null;
}

/// Make the text `context` added last a small note under a control, right-aligned with it.
pub fn noteText(context: *ui.Context) void {
    smallText(context, 12);
    const element = context.last_added orelse return;
    if (element.paint_kind == .text) element.paint_kind.text.alignment = .end;
}

/// Make the text `context` added last `size` tall.
pub fn smallText(context: *ui.Context, size: f32) void {
    const element = context.last_added orelse return;
    if (element.paint_kind == .text) element.paint_kind.text.size = size;
}

/// Size the text field `context` added last to `text` (plus its padding and room for the caret),
/// no wider than `max_width`, instead of a field's usual minimum width.
pub fn fitFieldToText(context: *ui.Context, text: []const u8, max_width: f32) void {
    const element = context.last_added orelse return;
    const padding = 20 + 8;
    element.style.min_width = 0;
    element.style.width = @min(@max(max_width, 0), @max(40, context.font.measure(text, context.theme.text_size) + padding));
}

/// `text`, cut with "..." to fit `width` at `size`. In `arena`.
pub fn fitText(arena: std.mem.Allocator, font: *const ui.Font, text: []const u8, size: f32, width: f32) []const u8 {
    if (font.measure(text, size) <= width) return text;
    var end = text.len;
    while (end > 0) {
        end -= 1;
        while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
        const cut = std.fmt.allocPrint(arena, "{s}...", .{text[0..end]}) catch return "";
        if (font.measure(cut, size) <= width) return cut;
    }
    return "";
}

/// A small chip naming what is being dragged, just below and right of the pointer (kept inside
/// the page), so it doesn't cover what is under the pointer.
pub fn dragChip(context: *ui.Context, text: []const u8) void {
    const b = context.builder();
    const size: f32 = 11;
    const label = fitText(b.allocator, context.font, text, size, @max(40, context.viewport.w * 0.5));
    const width = context.font.measure(label, size) + 12;
    const chip = b.node(0, .{ .width = width, .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 }, .z_index = 250 }, .{ .surface = .tooltip }, &.{
        b.node(0, .{}, .{ .text = .{ .value = label, .size = size } }, &.{}) catch return,
    }) catch return;
    const viewport = context.viewport;
    chip.overlay = .{ .point = .init(@max(viewport.x, @min(context.pointer.x + 16, viewport.x + viewport.w - width)), @min(context.pointer.y + 18, viewport.y + viewport.h - 20)) };
    context.element(chip);
}
