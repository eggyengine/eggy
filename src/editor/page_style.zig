//! Small layout touches for pages built with `ui.Context` (Preferences, the Inspector, the
//! Hierarchy): restyling the element just added, since `Context`'s widgets and containers take
//! no style of their own.
const ui = @import("eggy").ui;

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
