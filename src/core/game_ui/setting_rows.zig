//! A list of settings drawn as rows (name and note on the left, control on the right) with a
//! hairline between each, which the editor's Preferences and the game's graphics menu share.
const std = @import("std");
const ui = @import("weeoui");

/// The rows of one list: counts them so a hairline goes between rows, not before the first.
///
/// ```zig
/// var rows = SettingRows{};
/// rows.begin(context, "Vertical sync", "Waits for the screen to refresh.");
/// _ = context.toggle("##vsync", &vsync);
/// rows.end(context);
/// ```
pub const SettingRows = struct {
    /// The width of the control column, in logical points.
    pub const control_width: f32 = 240;

    count: usize = 0,

    /// Open a row: `title`, and `note` under it when not empty. Add the row's control, then
    /// call `end`. Both texts are borrowed for the frame.
    pub fn begin(self: *SettingRows, context: *ui.Context, title: []const u8, note: []const u8) void {
        self.divide(context);
        context.begin(.row);
        context.begin(.column);
        context.text(title);
        if (note.len > 0) {
            context.muted(note);
            setTextSize(context, 12);
        }
        context.end();
        if (context.last_added) |element| {
            element.style.grow = 1;
            element.style.gap = 2;
        }
        context.begin(.column);
    }

    /// Close the row `begin` opened, its control right-aligned in a fixed column.
    pub fn end(_: *SettingRows, context: *ui.Context) void {
        context.end();
        if (context.last_added) |element| {
            element.style.width = control_width;
            element.style.align_items = .end;
            element.style.gap = 4;
        }
        context.end();
        if (context.last_added) |element| {
            element.style.direction = .row;
            element.style.gap = 24;
            element.style.align_items = .center;
            element.style.wrap = false;
            element.style.padding = .{ .top = 10, .bottom = 10 };
        }
    }

    /// Count a row about to be added, with a hairline above it unless it is the first: for a
    /// row laid out by hand between `begin`/`end` rows.
    pub fn divide(self: *SettingRows, context: *ui.Context) void {
        if (self.count > 0) context.separator();
        self.count += 1;
    }
};

/// Open the card a list of rows sits in; close it with `endGroup`.
pub fn beginGroup(context: *ui.Context) void {
    context.begin(.card);
}

/// Close the card `beginGroup` opened: rows touch, hairlines between them, and it spans the page.
pub fn endGroup(context: *ui.Context) void {
    context.end();
    const element = context.last_added orelse return;
    element.style.gap = 0;
    element.style.padding = .{ .left = 16, .right = 16, .top = 4, .bottom = 4 };
    element.style.max_width = null;
}

fn setTextSize(context: *ui.Context, size: f32) void {
    const element = context.last_added orelse return;
    if (element.paint_kind == .text) element.paint_kind.text.size = size;
}

test "a hairline goes between rows, not before the first" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    context.newFrame(.{ .x = 0, .y = 0, .w = 600, .h = 400 });
    var rows = SettingRows{};
    beginGroup(&context);
    for (0..3) |_| {
        rows.begin(&context, "Name", "");
        context.text("Control");
        rows.end(&context);
    }
    endGroup(&context);
    const group = context.last_added.?;
    // Three rows and two hairlines between them.
    try std.testing.expectEqual(@as(usize, 5), group.children.len);
    try std.testing.expect(group.children[1].paint_kind == .separator);
    try std.testing.expect(group.children[3].paint_kind == .separator);
}
