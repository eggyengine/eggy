const std = @import("std");
const ui = @import("weeoui");
const L = ui.Layout;

const button_id = 1;
const checkbox_id = 2;
const toggle_id = 3;
const vertical_bar_id = 4;
const horizontal_bar_id = 5;
const page_id = 6;
const slider_id = 7;
const gap: f32 = 24;
const bar_width: f32 = 12;

pub const Demo = struct {
    focus: u2 = 0,
    checked: bool = true,
    enabled: bool = false,
    count: u32 = 0,
    ui_scale: f32 = 1,
    dragging_slider: bool = false,
    drag_scale: f32 = 1,
    drag_rect: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    scale_label: [24]u8 = undefined,
    pointer_x: f32 = -1,
    pointer_y: f32 = -1,
    scroll: L.ScrollState = .{},
    controls: [4]ui.Rect = [_]ui.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 4,

    pub fn relayout(self: *Demo, allocator: std.mem.Allocator, viewport: ui.Rect, font: *const ui.Font) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var count_buf: [20]u8 = undefined;
        const root = try layoutTree(.{ .allocator = arena.allocator() }, self, viewport, &count_buf, font);
        self.saveControls(root);
    }
    pub fn draw(self: *Demo, allocator: std.mem.Allocator, canvas: *ui.Canvas, viewport: ui.Rect) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var count_buf: [20]u8 = undefined;
        const root = try layoutTree(.{ .allocator = arena.allocator() }, self, viewport, &count_buf, canvas.font);
        self.saveControls(root);
        try root.draw(canvas);
    }
    fn saveControls(self: *Demo, root: *const L.Element) void {
        inline for (.{ button_id, checkbox_id, toggle_id, slider_id }, 0..) |id, i| self.controls[i] = root.find(id).?.bounds;
    }
    pub fn pointerDown(self: *Demo, x: f32, y: f32) void {
        self.pointer_x = x;
        self.pointer_y = y;
        if (self.scroll.pointerDown(x, y)) return;
        if (self.controls[3].intersection(self.scroll.viewport).contains(x, y)) {
            self.focus = 3;
            self.dragging_slider = true;
            self.drag_scale = self.ui_scale;
            self.drag_rect = self.controls[3];
            self.setScaleFromPointer(x);
            return;
        }
        for (self.controls[0..3], 0..) |r, i| if (r.intersection(self.scroll.viewport).contains(x, y)) {
            self.focus = @intCast(i);
            self.activate();
            return;
        };
    }
    pub fn pointerMove(self: *Demo, x: f32, y: f32) void {
        self.pointer_x = x;
        self.pointer_y = y;
        self.scroll.pointerMove(x, y);
        if (self.dragging_slider) self.setScaleFromPointer(x);
    }
    pub fn pointerUp(self: *Demo) void {
        self.scroll.pointerUp();
        self.dragging_slider = false;
    }
    fn setScaleFromPointer(self: *Demo, x: f32) void {
        const r = self.drag_rect;
        const drag_x = x * self.ui_scale / self.drag_scale;
        self.ui_scale = 0.75 + 1.25 * @max(0, @min(1, (drag_x - r.x - 8) / @max(1, r.w - 16)));
    }
    pub fn nudgeScale(self: *Demo, direction: f32) void {
        if (self.focus == 3) self.ui_scale = @max(0.75, @min(2, @round((self.ui_scale + direction * 0.05) * 20) / 20));
    }
    pub fn next(self: *Demo) void {
        self.focus = @intCast((@as(u3, self.focus) + 1) % 4);
        self.scroll.ensureVisible(self.controls[self.focus]);
    }
    pub fn activate(self: *Demo) void {
        switch (self.focus) {
            0 => self.count += 1,
            1 => self.checked = !self.checked,
            2 => self.enabled = !self.enabled,
            3 => {},
        }
    }
};

fn label(b: L.Builder, value: []const u8, size: f32, muted: bool, wrap: bool) !*L.Element {
    return b.node(0, .{}, .{ .text = .{ .value = value, .size = size, .tone = if (muted) .muted else .foreground, .wrap = wrap } }, &.{});
}
fn line(b: L.Builder) !*L.Element {
    return b.node(0, .{ .height = 1 }, .separator, &.{});
}
fn layoutTree(b: L.Builder, demo: *Demo, viewport: ui.Rect, count_buf: *[20]u8, font: *const ui.Font) !*L.Element {
    var vertical = false;
    var horizontal = false;
    var root: *L.Element = undefined;
    for (0..4) |_| {
        demo.scroll.vertical_bar = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        demo.scroll.horizontal_bar = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        root = try build(b, demo, viewport, count_buf, vertical, horizontal);
        root.layout(viewport, font);
        const need_vertical = demo.scroll.content.y > demo.scroll.viewport.h and demo.scroll.viewport.h >= 16;
        const need_horizontal = demo.scroll.content.x > demo.scroll.viewport.w and demo.scroll.viewport.w >= 16;
        if (need_vertical == vertical and need_horizontal == horizontal) return root;
        vertical = need_vertical;
        horizontal = need_horizontal;
    }
    return root;
}
fn build(b: L.Builder, demo: *Demo, viewport: ui.Rect, count_buf: *[20]u8, vertical: bool, horizontal: bool) !*L.Element {
    const content_width = @max(0, viewport.w - (if (vertical) bar_width else 0));
    const content_height = @max(0, viewport.h - (if (horizontal) bar_width else 0));
    const narrow = content_width < 712;
    const margin: f32 = if (narrow) 16 else 24;
    const page_width = @min(960, @max(240, content_width - 2 * margin));
    const count = try std.fmt.bufPrint(count_buf, "{d}", .{demo.count});
    const scale_label = try std.fmt.bufPrint(&demo.scale_label, "UI scale  {d}%", .{@as(u32, @intFromFloat(@round(demo.ui_scale * 100)))});

    const title = try b.node(0, .{ .direction = .column, .gap = 4, .grow = 1, .min_width = 200 }, .none, &.{
        try label(b, "weeoui", 30, false, false),
        try label(b, "UI demo / components", 14, true, true),
    });
    const badge = try b.node(0, .{ .width = 72, .height = 28 }, .{ .badge = "Alpha" }, &.{});
    const header = try b.node(0, .{ .direction = if (page_width < 320) .column else .row, .gap = 16 }, .none, &.{ title, badge });
    const introduction = try b.node(0, .{ .direction = .column, .gap = 4 }, .none, &.{
        try label(b, "Clean building blocks", 22, false, true),
        try label(b, "A small UI kit for the Eggy engine.", 15, true, true),
    });
    const button = try b.node(button_id, .{ .width = 168, .height = 40 }, .{ .button = .{ .label = "Try button", .hot = demo.controls[0].contains(demo.pointer_x, demo.pointer_y), .focused = demo.focus == 0 } }, &.{});
    const left = try b.node(0, .{ .min_width = if (narrow) 240 else 320, .grow = 1, .padding = .{ .left = gap, .right = gap, .top = gap, .bottom = gap }, .gap = 12 }, .card, &.{
        try label(b, "Button", 22, false, false),
        try label(b, "A clear primary action.", 15, true, true),
        try line(b),
        try label(b, "Clicks", 15, true, false),
        try label(b, count, 25, false, false),
        button,
    });
    const right = try b.node(0, .{ .min_width = if (narrow) 240 else 320, .grow = 1, .padding = .{ .left = gap, .right = gap, .top = gap, .bottom = gap }, .gap = 12 }, .card, &.{
        try label(b, "Preferences", 22, false, false),
        try label(b, "Simple interactive controls.", 15, true, true),
        try line(b),
        try b.node(checkbox_id, .{ .height = 32 }, .{ .checkbox = .{ .label = "Show hints", .checked = demo.checked, .focused = demo.focus == 1 } }, &.{}),
        try line(b),
        try b.node(toggle_id, .{ .height = 32 }, .{ .toggle = .{ .label = "Live updates", .enabled = demo.enabled, .focused = demo.focus == 2 } }, &.{}),
        try line(b),
        try label(b, scale_label, 15, true, false),
        try b.node(slider_id, .{ .height = 32 }, .{ .slider = .{ .value = (demo.ui_scale - 0.75) / 1.25, .focused = demo.focus == 3 } }, &.{}),
    });
    const cards = try b.node(0, .{ .direction = if (narrow) .column else .row, .gap = gap }, .none, &.{ left, right });
    const footer = try b.node(0, .{ .direction = .column, .gap = 8 }, .none, &.{
        try label(b, "Tab to focus / arrows adjust scale / Space or Enter to activate", 14, true, true),
        if (demo.checked) try label(b, "Tip: click a control or use the keyboard.", 14, true, true) else try b.node(0, .{ .height = 0 }, .none, &.{}),
    });
    const page = try b.node(page_id, .{ .width = page_width, .direction = .column, .gap = 24 }, .none, &.{ header, try line(b), introduction, cards, footer });
    const content = try b.node(0, .{ .width = content_width, .height = content_height, .padding = .{ .left = margin, .right = margin, .top = 32, .bottom = 32 }, .align_items = .center, .overflow = .scroll }, .none, &.{page});
    content.scroll = &demo.scroll;
    const row = if (vertical) try b.node(0, .{ .width = viewport.w, .height = content_height, .direction = .row }, .none, &.{ content, try b.node(vertical_bar_id, .{ .width = bar_width, .height = content_height }, .{ .scrollbar = .{ .state = &demo.scroll, .axis = .vertical } }, &.{}) }) else content;
    return if (horizontal) try b.node(0, .{ .width = viewport.w, .height = viewport.h }, .none, &.{ row, try b.node(horizontal_bar_id, .{ .width = content_width, .height = bar_width }, .{ .scrollbar = .{ .state = &demo.scroll, .axis = .horizontal } }, &.{}) }) else row;
}

test "responsive cards and controls follow scrolling" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    const wide = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 600 };
    try demo.relayout(std.testing.allocator, wide, &font);
    try std.testing.expect(demo.controls[0].x < demo.controls[1].x);
    try demo.relayout(std.testing.allocator, .{ .x = 0, .y = 0, .w = 1600, .h = 900 }, &font);
    try std.testing.expect(demo.controls[0].x >= 320);
    try demo.relayout(std.testing.allocator, .{ .x = 0, .y = 0, .w = 724, .h = 600 }, &font);
    try std.testing.expect(demo.controls[0].x < demo.controls[1].x);
    try demo.relayout(std.testing.allocator, .{ .x = 0, .y = 0, .w = 723, .h = 600 }, &font);
    try std.testing.expect(demo.controls[0].y < demo.controls[1].y);
    const narrow = ui.Rect{ .x = 0, .y = 0, .w = 360, .h = 300 };
    try demo.relayout(std.testing.allocator, narrow, &font);
    try std.testing.expect(demo.controls[0].y < demo.controls[1].y);
    try std.testing.expect(demo.scroll.content.y > narrow.h);
    try std.testing.expectEqual(demo.scroll.viewport.x + demo.scroll.viewport.w, demo.scroll.vertical_bar.x);
    try std.testing.expectEqual(bar_width, demo.scroll.vertical_bar.w);
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var count_buf: [20]u8 = undefined;
        const root = try layoutTree(.{ .allocator = arena.allocator() }, &demo, narrow, &count_buf, &font);
        const page = root.find(page_id).?;
        try std.testing.expect(root.find(vertical_bar_id) != null);
        try std.testing.expectApproxEqAbs(page.bounds.x - demo.scroll.viewport.x, demo.scroll.viewport.x + demo.scroll.viewport.w - page.bounds.x - page.bounds.w, 0.01);
    }
    demo.scroll.wheel(0, -10);
    try demo.relayout(std.testing.allocator, narrow, &font);
    try std.testing.expect(demo.controls[0].y < 300);
    demo.pointerDown(demo.controls[0].x + 10, demo.controls[0].y + 10);
    try std.testing.expectEqual(@as(u32, 1), demo.count);
    const tiny = ui.Rect{ .x = 0, .y = 0, .w = 200, .h = 200 };
    try demo.relayout(std.testing.allocator, tiny, &font);
    try std.testing.expect(demo.scroll.content.x > tiny.w);
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var count_buf: [20]u8 = undefined;
        const root = try layoutTree(.{ .allocator = arena.allocator() }, &demo, tiny, &count_buf, &font);
        try std.testing.expect(root.find(horizontal_bar_id) != null);
        try std.testing.expectEqual(demo.scroll.viewport.y + demo.scroll.viewport.h, demo.scroll.horizontal_bar.y);
    }
    demo.scroll.offset = .zero;
    try demo.relayout(std.testing.allocator, wide, &font);
    demo.pointerDown(demo.controls[0].x + 10, demo.controls[0].y + 10);
    try std.testing.expectEqual(@as(u32, 2), demo.count);
    demo.pointerDown(demo.controls[3].x + demo.controls[3].w - 8, demo.controls[3].center().y);
    try std.testing.expectApproxEqAbs(@as(f32, 2), demo.ui_scale, 0.01);
    demo.pointerMove((demo.drag_rect.x + 8) / 2, demo.drag_rect.center().y / 2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), demo.ui_scale, 0.01);
    demo.pointerUp();
    demo.nudgeScale(1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), demo.ui_scale, 0.01);
}
