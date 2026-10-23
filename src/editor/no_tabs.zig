//! What the main window shows with no tab open: the kinds of tab to open, each a row to press.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const L = ui.Layout;
const Kind = @import("workspace_tabs.zig").Kind;

// Ids, kept below `dock.first_id`: a row per kind of tab, by its `Kind`.
const first_id: u32 = 0x5700_0000;

/// The kinds offered, in order, with what each gives.
const choices = [_]struct { kind: Kind, title: []const u8, description: []const u8 }{
    .{ .kind = .scene_3d, .title = "3D Scene", .description = "The world in 3D, with its own camera" },
    .{ .kind = .scene_2d, .title = "2D Scene", .description = "The world seen flat from the front, for 2D games" },
    .{ .kind = .ui, .title = "UI Scene", .description = "Menus and HUDs, in the UI Designer" },
};

const column_width: f32 = 380;
const row_height: f32 = 52;
const glyph_size: f32 = 30;

/// The tab a press on element `id` opens, if it is one of the rows.
pub fn kindOf(id: u32) ?Kind {
    for (choices) |choice| if (id == first_id + @as(u32, @intFromEnum(choice.kind))) return choice.kind;
    return null;
}

/// The empty state over `area` (the dock's part of the main window); `hot` is the control
/// under the pointer, to light its row.
pub fn element(b: L.Builder, area: ui.Rect, hot: u32) !*L.Element {
    var rows: [choices.len]*L.Element = undefined;
    for (&rows, choices) |*row, choice| row.* = try rowElement(b, choice.kind, choice.title, choice.description, hot);

    const column = try b.node(0, .{ .width = column_width, .direction = .column, .gap = 2 }, .none, &.{
        try b.node(0, .{ .padding = .{ .left = 10, .bottom = 2 } }, .{ .text = .{ .value = "Open a tab", .size = 15 } }, &.{}),
        try b.node(0, .{ .padding = .{ .left = 10, .bottom = 12 } }, .{ .text = .{ .value = "Each tab is a layout of panels. Pick what this one is for.", .size = 12, .tone = .muted } }, &.{}),
        try b.node(0, .{ .direction = .column, .gap = 2 }, .none, &rows),
        try b.node(0, .{ .padding = .{ .left = 10, .top = 14 } }, .{ .text = .{ .value = "Ctrl+Z brings back a tab you closed. Window reopens a panel.", .size = 11, .tone = .muted } }, &.{}),
    });
    column.accessibility = .{ .role = .group, .label = "Open a tab" };
    // Centred in the area, a little above the middle where the eye lands, over the dock's empty
    // stack (its blank tab strip and drop hint), which would say the same thing less helpfully.
    const fill = try b.node(0, .{ .width = area.w, .height = area.h, .direction = .column, .align_items = .center, .justify = .center, .padding = .{ .bottom = area.h * 0.08 } }, .{ .custom = .{ .context = undefined, .draw = drawBackdrop } }, &.{column});
    fill.overlay = .{ .point = .init(area.x, area.y) };
    return fill;
}

/// A row: the kind's glyph, then its name over what it gives.
fn rowElement(b: L.Builder, kind: Kind, title: []const u8, description: []const u8, hot: u32) !*L.Element {
    const id = first_id + @as(u32, @intFromEnum(kind));
    const glyph_look = try b.allocator.create(Glyph);
    glyph_look.* = .{ .kind = kind };
    const row_look = try b.allocator.create(Row);
    row_look.* = .{ .hot = hot == id };
    const row = try b.node(id, .{ .width = column_width, .height = row_height, .direction = .row, .align_items = .center, .gap = 12, .padding = .{ .left = 10, .right = 10 } }, .{ .custom = .{ .context = row_look, .draw = Row.draw } }, &.{
        try b.node(0, .{ .width = glyph_size, .height = glyph_size }, .{ .custom = .{ .context = glyph_look, .draw = Glyph.draw } }, &.{}),
        try b.node(0, .{ .direction = .column, .gap = 3 }, .none, &.{
            try b.node(0, .{}, .{ .text = .{ .value = title, .size = 13 } }, &.{}),
            try b.node(0, .{}, .{ .text = .{ .value = description, .size = 12, .tone = .muted } }, &.{}),
        }),
    });
    row.cursor = .pointer;
    row.accessibility = .{ .role = .button, .label = title, .description = description };
    return row;
}

fn drawBackdrop(_: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    try c.rect(r, c.theme.background);
}

const Row = struct {
    hot: bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Row = @ptrCast(@alignCast(context));
        if (self.hot) try c.roundRect(r, c.theme.muted, 8);
    }
};

/// A small drawing of what a tab of `kind` shows: a cube, a grid with a square on it, a window.
const Glyph = struct {
    kind: Kind,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Glyph = @ptrCast(@alignCast(context));
        const ink = c.theme.muted_foreground;
        switch (self.kind) {
            // An isometric cube: its top lightest, its two sides shaded apart.
            .scene_3d => {
                const cx = r.x + r.w / 2;
                const top = r.y + 2;
                const half = r.w * 0.42;
                const rise = half * 0.58;
                const drop = r.h * 0.5;
                const centre = [2]f32{ cx, top + 2 * rise };
                const left = [2]f32{ cx - half, top + rise };
                const right = [2]f32{ cx + half, top + rise };
                const crown = [2]f32{ cx, top };
                try quad(c, crown, right, centre, left, tint(ink, 0.35));
                try quad(c, left, centre, .{ centre[0], centre[1] + drop }, .{ left[0], left[1] + drop }, tint(ink, 0.75));
                try quad(c, centre, right, .{ right[0], right[1] + drop }, .{ centre[0], centre[1] + drop }, tint(ink, 0.55));
            },
            // A ruled square with one cell filled, as an entity on the 2D Scene's grid.
            .scene_2d => {
                const cell = r.w / 3;
                for (0..4) |i| {
                    const at = @as(f32, @floatFromInt(i)) * cell;
                    try c.rectAlpha(.{ .x = r.x + at - 0.5, .y = r.y, .w = 1, .h = r.h }, ink, 0.45);
                    try c.rectAlpha(.{ .x = r.x, .y = r.y + at - 0.5, .w = r.w, .h = 1 }, ink, 0.45);
                }
                try c.rect(.{ .x = r.x + cell + 2, .y = r.y + cell + 2, .w = cell - 4, .h = cell - 4 }, ink);
            },
            // A window: its frame, a title strip, and two lines of content.
            .ui => {
                try c.roundRectStroke(r, ink, 4, 1.5);
                try c.rectAlpha(.{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = r.h * 0.22 }, ink, 0.45);
                try c.roundRect(.{ .x = r.x + 6, .y = r.y + r.h * 0.45, .w = r.w * 0.55, .h = 3 }, ink, 1.5);
                try c.roundRectAlpha(.{ .x = r.x + 6, .y = r.y + r.h * 0.66, .w = r.w * 0.35, .h = 3 }, ink, 1.5, 0.6);
            },
            .panels => {},
        }
    }

    fn quad(c: *ui.Canvas, a: [2]f32, b: [2]f32, d: [2]f32, e: [2]f32, color: [4]f32) !void {
        try c.triangle(.{ a, b, d }, .{ color, color, color });
        try c.triangle(.{ a, d, e }, .{ color, color, color });
    }

    fn tint(color: ui.Color, alpha: f32) [4]f32 {
        return .{ color[0], color[1], color[2], alpha };
    }
};

test "each row opens its kind of tab" {
    for (choices) |choice| try std.testing.expectEqual(choice.kind, kindOf(first_id + @as(u32, @intFromEnum(choice.kind))).?);
    try std.testing.expect(kindOf(first_id + @as(u32, @intFromEnum(Kind.panels))) == null);
}
