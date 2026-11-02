//! A list of settings drawn as rows (name and note on the left, control on the right) with a
//! hairline between each, which the editor's Settings and the game's graphics menu share. Rows can
//! be filtered by a search, and marked when they differ from a default, with a button to reset.
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
    /// The width of the reset button's column that `endResettable` adds.
    pub const reset_width: f32 = 32;

    count: usize = 0,
    /// Rows whose title and note don't have this in them (ignoring case) are left out by callers
    /// that ask `shows`; empty shows every row.
    query: []const u8 = "",

    /// Whether the row titled `title`, noted `note`, passes `query`. Ask before `begin`, and
    /// leave the row out when it doesn't.
    ///
    /// ```zig
    /// if (rows.shows("Vertical sync", note)) {
    ///     rows.begin(context, "Vertical sync", note);
    ///     _ = context.toggle("##vsync", &vsync);
    ///     rows.end(context);
    /// }
    /// ```
    pub fn shows(self: *const SettingRows, title: []const u8, note: []const u8) bool {
        return matches(self.query, title, note);
    }

    /// Open a row like `begin`, with a dot before its title when `mark.changed` (it differs from
    /// its default) and a Restart tag after it when `mark.restart` (a change waits for a restart).
    /// Close it with `end` or `endResettable`.
    pub fn beginMarked(self: *SettingRows, context: *ui.Context, title: []const u8, note: []const u8, mark: Mark) void {
        self.divide(context);
        context.begin(.row);
        context.begin(.column);
        context.begin(.row);
        if (mark.changed) {
            const dot = context.builder().node(0, .{ .width = 7, .height = 7 }, .{ .custom = .{ .context = &changed_dot, .draw = drawDot } }, &.{}) catch null;
            if (dot) |element| {
                element.accessibility = .{ .role = .label, .label = "Changed" };
                context.element(element);
            }
        }
        context.text(title);
        if (mark.restart) context.badge("Restart", .secondary);
        context.end();
        if (context.last_added) |line| {
            line.style.direction = .row;
            line.style.gap = 8;
            line.style.align_items = .center;
        }
        if (note.len > 0) {
            context.muted(note);
            setTextSize(context, 12);
            if (context.last_added) |element| if (element.paint_kind == .text) {
                element.paint_kind.text.wrap = true;
            };
        }
        context.end();
        if (context.last_added) |element| {
            element.style.grow = 1;
            element.style.gap = 3;
        }
        context.begin(.column);
    }

    /// Close a row like `end`, with `note` under the control when it isn't empty (what the
    /// default is, say) and, beside the control, a reset button when `resettable`, else room for
    /// one, so rows line up. `id` names the button uniquely on the page. Returns whether it was
    /// pressed.
    pub fn endResettable(_: *SettingRows, context: *ui.Context, note: []const u8, resettable: bool, id: []const u8) bool {
        if (note.len > 0) {
            context.muted(note);
            setTextSize(context, 12);
        }
        context.end();
        if (context.last_added) |element| {
            element.style.width = control_width;
            element.style.align_items = .end;
            element.style.gap = 4;
        }
        var pressed = false;
        if (resettable) {
            const arena = context.builder().allocator;
            pressed = context.buttonVariant(std.fmt.allocPrint(arena, reset_glyph ++ "##reset {s}", .{id}) catch reset_glyph, .ghost);
            if (context.last_added) |button| {
                button.style.width = reset_width;
                button.style.min_width = reset_width;
                button.accessibility.label = "Reset to the default";
            }
        } else {
            const room = context.builder().node(0, .{ .width = reset_width, .height = 1 }, .none, &.{}) catch null;
            if (room) |element| {
                element.accessibility = .{ .role = .ignored };
                context.element(element);
            }
        }
        context.end();
        if (context.last_added) |element| {
            element.style.direction = .row;
            element.style.gap = 16;
            element.style.align_items = .center;
            element.style.wrap = false;
            element.style.padding = .{ .top = 12, .bottom = 12 };
        }
        return pressed;
    }

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

/// How `SettingRows.beginMarked` marks a row.
pub const Mark = struct {
    /// It differs from its default: a dot before its title.
    changed: bool = false,
    /// A change takes effect after a restart: a tag after its title.
    restart: bool = false,
};

/// The reset button's glyph, from the UI font's Nerd Font face: an arrow turning back.
const reset_glyph = "\u{f0e2}";

/// Whether `title` or `note` has `query` in it, ignoring case; an empty query matches anything.
///
/// ```zig
/// std.debug.assert(matches("sync", "Vertical sync", ""));
/// ```
pub fn matches(query: []const u8, title: []const u8, note: []const u8) bool {
    const trimmed = std.mem.trim(u8, query, " ");
    if (trimmed.len == 0) return true;
    return std.ascii.findIgnoreCase(title, trimmed) != null or std.ascii.findIgnoreCase(note, trimmed) != null;
}

const changed_dot: u8 = 0;

fn drawDot(_: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    try c.roundRect(r, c.theme.primary, r.w / 2);
}

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

test "a search matches a row's title or note, ignoring case" {
    try std.testing.expect(matches("", "Vertical sync", ""));
    try std.testing.expect(matches("SYNC", "Vertical sync", ""));
    try std.testing.expect(matches("tearing", "Vertical sync", "Stops tearing."));
    try std.testing.expect(!matches("shadow", "Vertical sync", "Stops tearing."));
}

test "a marked row lines up with the rest, its reset button in its own column" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    context.newFrame(.{ .x = 0, .y = 0, .w = 600, .h = 400 });
    var rows = SettingRows{};
    beginGroup(&context);
    rows.beginMarked(&context, "Backend", "What draws the game.", .{ .changed = true, .restart = true });
    context.text("Vulkan");
    _ = rows.endResettable(&context, "Default is Automatic", true, "backend");
    rows.beginMarked(&context, "Frame limit", "", .{});
    context.text("0");
    _ = rows.endResettable(&context, "", false, "frame limit");
    endGroup(&context);
    const group = context.last_added.?;
    try std.testing.expectEqual(@as(usize, 3), group.children.len);
    // Name, control and the reset column, in both rows.
    try std.testing.expectEqual(@as(usize, 3), group.children[0].children.len);
    try std.testing.expectEqual(@as(usize, 3), group.children[2].children.len);
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
