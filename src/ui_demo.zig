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
const overview_tab_id = 360;
const details_tab_id = 361;
const gap: f32 = 24;
const bar_width: f32 = 12;
pub const AccessibilityAction = enum(i32) { focus, click, increment, decrement };

const TextBuffer = struct {
    bytes: [128]u8 = undefined,
    len: usize = 0,

    fn init(comptime value: []const u8) TextBuffer {
        var result: TextBuffer = .{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = value.len;
        return result;
    }
    fn slice(self: *const TextBuffer) []const u8 {
        return self.bytes[0..self.len];
    }
    fn set(self: *TextBuffer, value: []const u8) bool {
        if (value.len > self.bytes.len) return false;
        @memcpy(self.bytes[0..value.len], value);
        self.len = value.len;
        return true;
    }
    fn append(self: *TextBuffer, value: []const u8) bool {
        if (value.len > self.bytes.len - self.len) return false;
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += value.len;
        return true;
    }
    fn backspace(self: *TextBuffer) void {
        if (self.len == 0) return;
        self.len -= 1;
        while (self.len > 0 and self.bytes[self.len] & 0xc0 == 0x80) self.len -= 1;
    }
};
const Editable = struct { id: u32, text: TextBuffer };

pub const Demo = struct {
    focus: usize = 0,
    control_count: usize = 0,
    control_ids: [128]u32 = [_]u32{0} ** 128,
    control_clips: [128]ui.Rect = [_]ui.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 128,
    selected_tab: u32 = details_tab_id,
    checked: bool = true,
    enabled: bool = false,
    count: u32 = 0,
    select_index: usize = 0,
    selected_radio: u32 = 330,
    selected_view: u32 = 340,
    open_appearance: bool = true,
    open_advanced: bool = false,
    page: u16 = 1,
    date: ui.widgets.Date = .{ .year = 2024, .month = 2, .day = 29 },
    calendar_open: bool = true,
    slide: usize = 0,
    menu_highlight: u32 = 420,
    combo_highlight: u32 = 431,
    command_highlight: u32 = 441,
    combo_open: bool = true,
    sorted_descending: bool = false,
    selected_item: bool = false,
    divider: f32 = 0.5,
    dialog_open: bool = true,
    retry_count: u32 = 0,
    status: []const u8 = "Change a control to see its state.",
    file_request: bool = false,
    file_picker_open: bool = false,
    filename: TextBuffer = TextBuffer.init("No file selected"),
    editable: [5]Editable = .{
        .{ .id = 300, .text = TextBuffer.init("Eggy") },
        .{ .id = 301, .text = TextBuffer.init("Describe the project") },
        .{ .id = 302, .text = TextBuffer.init("42") },
        .{ .id = 430, .text = TextBuffer.init("sea") },
        .{ .id = 440, .text = TextBuffer.init("new") },
    },
    otp: [4]u8 = .{ '1', '2', '3', 0 },
    ui_scale: f32 = 1,
    dragging_slider: bool = false,
    dragging_divider: bool = false,
    divider_track: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    drag_scale: f32 = 1,
    drag_rect: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    scale_label: [24]u8 = undefined,
    pointer_x: f32 = -1,
    pointer_y: f32 = -1,
    scroll: L.ScrollState = .{},
    preview_scroll: L.ScrollState = .{},
    message_scroll: L.ScrollState = .{},
    controls: [128]ui.Rect = [_]ui.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 128,
    scene_viewport: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    scene_clip: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn relayout(self: *Demo, allocator: std.mem.Allocator, viewport: ui.Rect, font: *const ui.Font) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var count_buf: [20]u8 = undefined;
        const root = try layoutTree(.{ .allocator = arena.allocator() }, self, viewport, &count_buf, font);
        try self.saveControls(root);
    }
    pub fn accessibilitySnapshot(self: *Demo, allocator: std.mem.Allocator, viewport: ui.Rect, font: *const ui.Font) !ui.accessibility.Snapshot {
        var count_buf: [20]u8 = undefined;
        const root = try layoutTree(.{ .allocator = allocator }, self, viewport, &count_buf, font);
        try self.saveControls(root);
        return ui.accessibility.collect(allocator, root, self.focusId());
    }
    pub fn accessibilityAction(self: *Demo, id: u32, action: AccessibilityAction) bool {
        const index = self.indexOf(id) orelse return false;
        if ((action == .click and (id == slider_id or id == 480)) or
            ((action == .increment or action == .decrement) and id != slider_id and id != 480)) return false;
        self.focus = index;
        self.scroll.ensureVisible(self.controls[index]);
        switch (action) {
            .focus => {},
            .click => self.activate(),
            .increment, .decrement => {
                if (id == 480) {
                    self.divider = std.math.clamp(self.divider + (if (action == .increment) @as(f32, 0.05) else -0.05), 0.1, 0.9);
                } else self.nudgeScale(if (action == .increment) 1 else -1);
            },
        }
        return true;
    }
    pub fn draw(self: *Demo, allocator: std.mem.Allocator, canvas: *ui.Canvas, viewport: ui.Rect) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var count_buf: [20]u8 = undefined;
        const root = try layoutTree(.{ .allocator = arena.allocator() }, self, viewport, &count_buf, canvas.font);
        try self.saveControls(root);
        try root.draw(canvas);
    }
    fn focusId(self: *const Demo) u32 {
        return if (self.control_count > 0) self.control_ids[self.focus] else button_id;
    }
    fn indexOf(self: *const Demo, id: u32) ?usize {
        return std.mem.indexOfScalar(u32, self.control_ids[0..self.control_count], id);
    }
    fn saveControls(self: *Demo, root: *L.Element) !void {
        const old_id = self.focusId();
        self.control_count = 0;
        try self.collectControls(root);
        self.focus = self.indexOf(old_id) orelse 0;
        self.markFocus(root);
        self.divider_track = if (root.find(481)) |track| track.bounds else .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        if (root.find(500)) |scene| {
            self.scene_viewport = scene.bounds;
            self.scene_clip = scene.clip.intersection(scene.bounds);
        } else {
            self.scene_viewport = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            self.scene_clip = self.scene_viewport;
        }
    }
    fn markFocus(self: *const Demo, element: *L.Element) void {
        const focused = element.id != 0 and element.id == self.focusId();
        switch (element.paint_kind) {
            .button => |*button| button.focused = focused,
            .checkbox => |*checkbox| checkbox.focused = focused,
            .toggle => |*toggle| toggle.focused = focused,
            .slider => |*slider| slider.focused = focused,
            .input => |*input| input.focused = focused,
            .radio => |*radio| radio.focused = focused,
            .toggle_button => |*toggle_button| toggle_button.focused = focused,
            .tab => |*tab| tab.focused = focused,
            else => {
                if (focused and element.accessibility.role == .radio) element.children[0].paint_kind.radio.focused = true;
            },
        }
        for (element.children) |child| self.markFocus(child);
    }
    fn collectControls(self: *Demo, element: *const L.Element) !void {
        if (element.actionable()) {
            if (self.control_count == self.controls.len) return error.TooManyControls;
            const i = self.control_count;
            self.controls[i] = element.bounds;
            self.control_clips[i] = element.bounds.intersection(element.clip);
            self.control_ids[i] = element.id;
            self.control_count += 1;
        }
        for (element.children) |child| try self.collectControls(child);
    }
    pub fn scrollWheel(self: *Demo, x: f32, y: f32, dx: f32, dy: f32) void {
        for ([_]*L.ScrollState{ &self.preview_scroll, &self.message_scroll }) |pane| {
            if (pane.viewport.intersection(self.scroll.viewport).contains(x, y)) {
                const old = pane.offset;
                pane.wheel(dx, dy);
                if (old.x != pane.offset.x or old.y != pane.offset.y) return;
                break;
            }
        }
        self.scroll.wheel(dx, dy);
    }
    pub fn isEditing(self: *const Demo) bool {
        const id = self.focusId();
        return self.editableFor(id) != null or (id >= 310 and id <= 313);
    }
    fn editableFor(self: *const Demo, id: u32) ?usize {
        for (self.editable, 0..) |field, i| if (field.id == id) return i;
        return null;
    }
    pub fn insertText(self: *Demo, text: []const u8) bool {
        const id = self.focusId();
        if (id >= 310 and id <= 313) {
            if (text.len != 1 or !std.ascii.isDigit(text[0])) return false;
            self.otp[id - 310] = text[0];
            if (self.indexOf(id + 1)) |next_index| self.focus = next_index;
            return true;
        }
        if (self.editableFor(id)) |i| {
            if (id != 301 and std.mem.indexOfAny(u8, text, "\r\n") != null) return false;
            if (!self.editable[i].text.append(text)) {
                self.status = "Input is full (128 bytes).";
                return true;
            }
            return true;
        }
        return false;
    }
    pub fn backspace(self: *Demo) bool {
        const id = self.focusId();
        if (id >= 310 and id <= 313) {
            if (self.otp[id - 310] == 0 and id > 310) {
                self.focus = self.indexOf(id - 1) orelse self.focus;
                self.otp[id - 311] = 0;
            } else self.otp[id - 310] = 0;
            return true;
        }
        if (self.editableFor(id)) |i| {
            self.editable[i].text.backspace();
            return true;
        }
        return false;
    }
    pub fn selectedFile(self: *Demo, name: []const u8) void {
        self.file_picker_open = false;
        if (!self.filename.set(name)) {
            self.status = "Selected filename is too long.";
            std.log.warn("Selected filename exceeds 128 bytes", .{});
            return;
        }
        self.status = "File selected.";
    }
    pub fn pointerDown(self: *Demo, x: f32, y: f32) void {
        self.pointer_x = x;
        self.pointer_y = y;
        if (self.scroll.pointerDown(x, y)) return;
        var i = self.control_count;
        while (i > 0) {
            i -= 1;
            if (!self.control_clips[i].contains(x, y)) continue;
            self.focus = i;
            switch (self.focusId()) {
                slider_id => {
                    self.dragging_slider = true;
                    self.drag_scale = self.ui_scale;
                    self.drag_rect = self.controls[i];
                    self.setScaleFromPointer(x);
                },
                480 => {
                    self.dragging_divider = true;
                    self.drag_rect = self.controls[i];
                    self.setDividerFromPointer(x);
                },
                else => self.activate(),
            }
            return;
        }
    }
    pub fn pointerMove(self: *Demo, x: f32, y: f32) void {
        self.pointer_x = x;
        self.pointer_y = y;
        self.scroll.pointerMove(x, y);
        if (self.dragging_slider) self.setScaleFromPointer(x);
        if (self.dragging_divider) self.setDividerFromPointer(x);
    }
    pub fn pointerUp(self: *Demo) void {
        self.scroll.pointerUp();
        self.dragging_slider = false;
        self.dragging_divider = false;
    }
    fn setScaleFromPointer(self: *Demo, x: f32) void {
        const r = self.drag_rect;
        const drag_x = x * self.ui_scale / self.drag_scale;
        self.ui_scale = 0.75 + 1.25 * @max(0, @min(1, (drag_x - r.x - 8) / @max(1, r.w - 16)));
    }
    fn setDividerFromPointer(self: *Demo, x: f32) void {
        self.divider = std.math.clamp((x - self.divider_track.x - 3) / @max(1, self.divider_track.w - 6), 0.1, 0.9);
    }
    pub fn nudgeScale(self: *Demo, direction: f32) void {
        if (self.focusId() == slider_id) self.ui_scale = @max(0.75, @min(2, @round((self.ui_scale + direction * 0.05) * 20) / 20));
    }
    pub fn adjustFocused(self: *Demo, direction: f32) void {
        if (self.focusId() == 480) {
            self.divider = std.math.clamp(@round((self.divider + direction * 0.05) * 20) / 20, 0.1, 0.9);
        } else self.nudgeScale(direction);
    }
    pub fn next(self: *Demo, reverse: bool) void {
        if (self.control_count == 0) return;
        self.focus = if (reverse) (self.focus + self.control_count - 1) % self.control_count else (self.focus + 1) % self.control_count;
        self.scroll.ensureVisible(self.controls[self.focus]);
    }
    pub fn activate(self: *Demo) void {
        const id = self.focusId();
        switch (id) {
            button_id => self.count += 1,
            checkbox_id => self.checked = !self.checked,
            toggle_id => self.enabled = !self.enabled,
            slider_id, 300, 301, 302, 310...313, 430, 440, 480 => {},
            320 => self.select_index = (self.select_index + 1) % 3,
            330, 331 => self.selected_radio = id,
            340, 341 => self.selected_view = id,
            350 => self.status = "Settings applied.",
            351 => {
                self.select_index = 0;
                self.selected_radio = 330;
                self.selected_view = 340;
                self.status = "Settings reset.";
            },
            overview_tab_id, details_tab_id => self.selected_tab = id,
            370 => self.open_appearance = !self.open_appearance,
            371 => self.open_advanced = !self.open_advanced,
            380 => self.status = "Home breadcrumb selected.",
            390 => {
                self.page = @max(1, self.page -| 1);
                self.focus = self.indexOf(390 + self.page) orelse self.focus;
            },
            391, 392 => self.page = @intCast(id - 390),
            393 => {
                self.page = @min(2, self.page + 1);
                self.focus = self.indexOf(390 + self.page) orelse self.focus;
            },
            400 => self.calendar_open = !self.calendar_open,
            1001...1031 => {
                self.date.day = @intCast(id - 1000);
                self.calendar_open = false;
                self.focus = self.indexOf(400) orelse self.focus;
            },
            410 => self.slide = (self.slide + 1) % 2,
            411 => self.slide = (self.slide + 1) % 2,
            420, 421 => {
                self.menu_highlight = id;
                self.status = if (id == 420) "Open selected." else "Rename selected.";
            },
            431, 432 => {
                self.combo_highlight = id;
                _ = self.editable[3].text.set(if (id == 431) "Search" else "Settings");
                self.status = "Command selected.";
            },
            441, 442 => {
                self.command_highlight = id;
                self.status = if (id == 441) "New file selected." else "New folder selected.";
            },
            450, 451 => self.sorted_descending = !self.sorted_descending,
            460 => self.selected_item = !self.selected_item,
            470 => {
                if (!self.file_picker_open) {
                    self.file_request = true;
                    self.file_picker_open = true;
                    self.status = "Opening file picker...";
                }
            },
            489 => self.dialog_open = true,
            490 => {
                self.dialog_open = false;
                self.status = "Dialog confirmed.";
                self.focus = self.indexOf(489) orelse self.focus;
            },
            491 => {
                self.retry_count += 1;
                self.status = "Search retried.";
            },
            else => std.log.warn("Unimplemented demo control: {d}", .{id}),
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
    const slider = try b.node(slider_id, .{ .height = 32 }, .{ .slider = .{ .value = (demo.ui_scale - 0.75) / 1.25, .focused = demo.focus == 3 } }, &.{});
    slider.accessibility.label = "UI scale";
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
        slider,
    });
    const cards = try b.node(0, .{ .direction = if (narrow) .column else .row, .gap = gap }, .none, &.{ left, right });
    const input_preview = try b.input(0, .{ .value = "Search projects", .placeholder = "Search..." });
    input_preview.accessibility = .{ .role = .label, .label = "Search projects (preview)" };
    const progress_preview = try b.progress((demo.ui_scale - 0.75) / 1.25);
    progress_preview.accessibility.label = "UI scale";
    const examples = try b.node(0, .{ .padding = .{ .left = gap, .right = gap, .top = gap, .bottom = gap }, .gap = 12 }, .card, &.{
        try label(b, "More building blocks", 22, false, false),
        try label(b, "Compose widgets; applications own interaction state.", 15, true, true),
        input_preview,
        progress_preview,
        try b.alert(.{ .title = "Ready to customize", .description = "Compose Weeoui widgets or paint your own." }),
    });
    const gallery = try componentGallery(b, demo, page_width);
    const footer = try b.node(0, .{ .direction = .column, .gap = 8 }, .none, &.{
        try label(b, "Tab / Shift+Tab to focus, arrows adjust sliders and dividers, Enter to activate", 14, true, true),
        if (demo.checked) try label(b, "Tip: click a control or use the keyboard.", 14, true, true) else try b.node(0, .{ .height = 0 }, .none, &.{}),
    });
    const page = try b.node(page_id, .{ .width = page_width, .direction = .column, .gap = 24 }, .none, &.{ header, try line(b), introduction, cards, examples, gallery, footer });
    const content = try b.node(0, .{ .width = content_width, .height = content_height, .padding = .{ .left = margin, .right = margin, .top = 32, .bottom = 32 }, .align_items = .center, .overflow = .scroll }, .none, &.{page});
    content.scroll = &demo.scroll;
    const row = if (vertical) try b.node(0, .{ .width = viewport.w, .height = content_height, .direction = .row }, .none, &.{ content, try b.node(vertical_bar_id, .{ .width = bar_width, .height = content_height }, .{ .scrollbar = .{ .state = &demo.scroll, .axis = .vertical } }, &.{}) }) else content;
    return if (horizontal) try b.node(0, .{ .width = viewport.w, .height = viewport.h }, .none, &.{ row, try b.node(horizontal_bar_id, .{ .width = content_width, .height = bar_width }, .{ .scrollbar = .{ .state = &demo.scroll, .axis = .horizontal } }, &.{}) }) else row;
}

fn componentGallery(b: L.Builder, demo: *Demo, page_width: f32) !*L.Element {
    const W = ui.widgets;
    const inner_width = @max(192, page_width - 48);
    const sizes = [_][]const u8{ "Compact", "Comfortable", "Spacious" };
    var otp_len: usize = 0;
    while (otp_len < demo.otp.len and demo.otp[otp_len] != 0) : (otp_len += 1) {}

    const fields = try W.form(b, &.{
        try W.field(b, 300, "Project", .{ .value = demo.editable[0].text.slice(), .placeholder = "Project name" }),
        try b.textarea(301, .{ .value = demo.editable[1].text.slice(), .placeholder = "Description" }),
        try W.inputGroup(b, 302, "$", .{ .value = demo.editable[2].text.slice(), .placeholder = "Amount" }, "USD"),
        try W.inputOtp(b, 310, demo.otp[0..otp_len], 4),
        try W.select(b, 320, sizes[demo.select_index], "Choose size"),
    });
    const choices = try b.card(&.{
        try label(b, "Fields and choices", 22, false, false),
        fields,
        try W.radioGroup(b, &.{ .{ .id = 330, .label = "Email" }, .{ .id = 331, .label = "Desktop" } }, demo.selected_radio),
        try W.toggleGroup(b, &.{ .{ .id = 340, .label = "Grid" }, .{ .id = 341, .label = "List" } }, if (demo.selected_view == 340) &.{340} else &.{341}),
        try W.buttonGroup(b, &.{ .{ .id = 350, .label = "Apply" }, .{ .id = 351, .label = "Reset" } }),
        try label(b, demo.status, 14, true, true),
    });

    const navigation = try b.card(&.{
        try label(b, "Navigation and dates", 22, false, false),
        try W.tabs(b, &.{ .{ .id = overview_tab_id, .label = "Overview" }, .{ .id = details_tab_id, .label = "Details" } }, demo.selected_tab, &.{ try b.text("Overview panel"), try b.text("Details panel") }),
        try W.accordion(b, &.{
            .{ .id = 370, .title = "Appearance", .open = demo.open_appearance, .content = &.{try b.text("Neutral palette, rounded corners.")} },
            .{ .id = 371, .title = "Advanced", .open = demo.open_advanced, .content = &.{try b.text("Editable layout and color tokens.")} },
        }),
        try W.breadcrumb(b, &.{ .{ .id = 380, .label = "Home" }, .{ .id = 381, .label = "Components" } }),
        try W.pagination(b, 390, demo.page, 2),
        try W.datePicker(b, 400, 1000, demo.date, demo.calendar_open),
        try W.carousel(b, 410, 411, &.{ try b.text("Slide one"), try b.text("Slide two") }, demo.slide),
    });

    const feedback = try b.card(&.{
        try label(b, "Menus and feedback", 22, false, false),
        try W.menu(b, &.{ .{ .id = 420, .label = "Open" }, .{ .id = 421, .label = "Rename" } }, demo.menu_highlight),
        try W.combobox(b, 430, demo.editable[3].text.slice(), &.{ .{ .id = 431, .label = "Search" }, .{ .id = 432, .label = "Settings" } }, demo.combo_highlight, demo.combo_open),
        try W.command(b, 440, demo.editable[4].text.slice(), &.{ .{ .id = 441, .label = "New file" }, .{ .id = 442, .label = "New folder" } }, demo.command_highlight),
        try W.popover(b, &.{try b.text("Popover content")}),
        try W.hoverCard(b, &.{try b.text("Hover card content")}),
        try W.tooltip(b, "Helpful tip"),
        try W.toast(b, "Saved", "Your changes are ready."),
        try W.kbd(b, "Ctrl+K"),
    });

    const chart = try b.chart(&.{ 5, 8, 4, 9, 6 });
    chart.accessibility.label = "Activity over five periods";
    const sidebar = try W.sidebar(b, 132, &.{ try b.text("Workspace"), try b.text("Dashboard"), try b.text("Settings") });
    sidebar.style.width = @min(240, inner_width);
    const dialog_preview = if (demo.dialog_open) try W.modal(b, .{ .x = 0, .y = 0, .w = @min(inner_width, 320), .h = 180 }, .alert_dialog, &.{ try b.text("Dialog preview"), try b.button(490, "Continue") }) else null;
    if (dialog_preview) |dialog| dialog.children[0].accessibility.modal = false;
    const item = try W.item(b, 460, if (demo.selected_item) "Project card (selected)" else "Project card", "Composable content and metadata.", try b.avatar("EC"));
    item.accessibility = .{ .role = .button, .label = "Project card", .description = "Toggle selection" };
    const resizable = try W.resizable(b, .{ .x = 0, .y = 0, .w = @min(inner_width, 300), .h = 80 }, demo.divider, 480, try b.surface(.card, &.{try b.text("Left")}), try b.surface(.card, &.{try b.text("Right")}));
    resizable.id = 481;
    resizable.children[1].accessibility = .{ .role = .slider, .label = "Panel divider", .numeric_value = demo.divider };
    const scene = try b.node(500, .{ .width = @min(inner_width, 520), .height = 224 }, .none, &.{});
    scene.accessibility = .{ .role = .image, .label = "Rotating 3D viewport" };
    const data = try b.card(&.{
        try label(b, "Data and layout", 22, false, false),
        try W.dataTable(b, &.{ .{ .id = 450, .label = "Name" }, .{ .id = 451, .label = "Status" } }, if (demo.sorted_descending) &.{ &.{ "Weeoui", "Alpha" }, &.{ "Eggy", "Ready" } } else &.{ &.{ "Eggy", "Ready" }, &.{ "Weeoui", "Alpha" } }),
        chart,
        try label(b, "3D scene (Vitellus)", 14, true, false),
        scene,
        try b.row(&.{ try b.avatar("AB"), try b.spinner(0.25), try b.skeleton(72, 24) }),
        item,
        try W.attachment(b, 470, demo.filename.slice()),
        sidebar,
        try W.empty(b, "No results", "Try a different search.", try b.button(491, try std.fmt.allocPrint(b.allocator, "Retry ({d})", .{demo.retry_count}))),
        try W.message(b, "Eggy", "Compose messages without a data model."),
        try label(b, "Scrollable panes (wheel to explore)", 14, true, false),
        try W.scrollArea(b, .{ .x = 0, .y = 0, .w = @min(inner_width, 300), .h = 80 }, &demo.preview_scroll, &.{
            try b.text("Scrollable first line"),
            try b.text("Scrollable second line"),
            try b.text("Scrollable third line"),
            try b.text("Scrollable fourth line"),
            try b.text("Scrollable fifth line"),
        }),
        try W.messageScroller(b, .{ .x = 0, .y = 0, .w = @min(inner_width, 300), .h = 100 }, &demo.message_scroll, &.{
            try W.message(b, "Alice", "One"),
            try W.message(b, "Bob", "Two"),
            try W.message(b, "Alice", "Three"),
        }),
        resizable,
        try W.aspectRatio(b, 160, 1.6, &.{try b.skeleton(160, 100)}),
        try b.button(489, if (demo.dialog_open) "Hide dialog" else "Open dialog"),
        if (dialog_preview) |dialog| dialog else try b.node(0, .{ .height = 0 }, .none, &.{}),
    });

    const gallery = try b.node(0, .{ .gap = gap }, .none, &.{
        try label(b, "Component gallery", 22, false, false),
        try label(b, "Every control responds to pointer, keyboard, and accessible actions.", 14, true, true),
        try b.node(0, .{ .width = @min(inner_width, 400), .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 }, .gap = 0 }, .card, &.{
            try b.node(0, .{ .height = 32 }, .{ .text = .{ .value = "Start aligned", .alignment = .start } }, &.{}),
            try b.node(0, .{ .height = 32 }, .{ .text = .{ .value = "Center aligned", .alignment = .center } }, &.{}),
            try b.node(0, .{ .height = 32 }, .{ .text = .{ .value = "End aligned", .alignment = .end } }, &.{}),
        }),
        try b.node(0, .{ .direction = .row, .gap = 8, .align_items = .center }, .none, &.{ try b.icon(.search), try b.icon(.check), try label(b, "Lucide SVG icons", 14, true, false) }),
        choices,
        navigation,
        feedback,
        data,
    });
    return gallery;
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

test "screen reader actions use the same app-owned control state" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var demo: Demo = .{};
    const snapshot = try demo.accessibilitySnapshot(arena.allocator(), .{ .x = 0, .y = 0, .w = 900, .h = 675 }, &font);
    try std.testing.expectEqual(@as(u64, button_id), snapshot.focus);
    try std.testing.expect(demo.accessibilityAction(button_id, .click));
    try std.testing.expectEqual(@as(u32, 1), demo.count);
    try std.testing.expect(demo.accessibilityAction(checkbox_id, .click));
    try std.testing.expect(!demo.checked);
    try std.testing.expect(demo.accessibilityAction(slider_id, .increment));
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), demo.ui_scale, 0.01);
    try std.testing.expect(!demo.accessibilityAction(button_id, .increment));
    try std.testing.expectEqual(@as(usize, 3), demo.focus);
    try std.testing.expect(!demo.accessibilityAction(200, .click));
}

test "gallery accessibility tree covers rendered component roles and visible bounds" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expectEqual(@as(u64, button_id), snapshot.focus);
    const tab = snapshotNode(snapshot, details_tab_id).?;
    try std.testing.expectEqual(L.Accessibility.Role.tab, tab.role);
    try std.testing.expect(tab.selected.? and !tab.disabled);
    const menu = snapshotNode(snapshot, 421).?;
    try std.testing.expectEqual(L.Accessibility.Role.menu_item, menu.role);
    try std.testing.expect(!menu.disabled and menu.actionable);
    const field = snapshotNode(snapshot, 300).?;
    try std.testing.expectEqualStrings("Project", field.label);
    try std.testing.expectEqualStrings("Eggy", field.value);
    const day = snapshotNode(snapshot, 1029).?;
    try std.testing.expectEqualStrings("29", day.label);
    try std.testing.expect(!day.disabled and day.actionable);
    try std.testing.expectEqual(L.Accessibility.Role.column_header, snapshotNode(snapshot, 450).?.role);
    try std.testing.expect(snapshotNode(snapshot, 400).?.expanded.?);
    var found_dialog = false;
    var found_chart = false;
    for (snapshot.nodes) |node| {
        if (node.role == .alert_dialog) {
            found_dialog = true;
            try std.testing.expect(!node.modal);
        }
        if (node.role == .image and std.mem.eql(u8, node.label, "Activity over five periods")) found_chart = true;
    }
    try std.testing.expect(found_dialog and found_chart);

    var count_buf: [20]u8 = undefined;
    const root = try layoutTree(.{ .allocator = arena.allocator() }, &demo, viewport, &count_buf, &font);
    demo.scroll.ensureVisible(root.find(details_tab_id).?.bounds);
    const scrolled = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(snapshotNode(scrolled, details_tab_id).?.bounds.w > 0);
    try std.testing.expect(snapshotNode(scrolled, details_tab_id).?.bounds.h > 0);
    try std.testing.expectEqual(@as(u64, button_id), scrolled.focus);
    try std.testing.expect(demo.accessibilityAction(overview_tab_id, .click));
    const selected = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expectEqual(@as(u64, overview_tab_id), selected.focus);
    try std.testing.expect(snapshotNode(selected, overview_tab_id).?.selected.?);
    try std.testing.expect(!snapshotNode(selected, details_tab_id).?.selected.?);
    var found_panel = false;
    for (selected.nodes) |node| if (std.mem.eql(u8, node.label, "Overview panel")) {
        found_panel = true;
    };
    try std.testing.expect(found_panel);
}

test "gallery actions, editing, reverse focus and nested wheels update state" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    for (demo.control_ids[0..demo.control_count]) |id| switch (id) {
        button_id,
        checkbox_id,
        toggle_id,
        slider_id,
        300...302,
        310...313,
        320,
        330...331,
        340...341,
        350...351,
        360...361,
        370...371,
        380,
        390...393,
        400,
        410...411,
        420...421,
        430...432,
        440...442,
        450...451,
        460,
        470,
        480,
        489...491,
        1001...1031,
        => {},
        else => return error.UnhandledControl,
    };
    demo.next(true);
    const last = demo.focusId();
    try std.testing.expect(last != button_id);
    demo.next(false);
    try std.testing.expectEqual(@as(u32, button_id), demo.focusId());
    try std.testing.expect(demo.accessibilityAction(300, .focus));
    try std.testing.expect(demo.isEditing());
    try std.testing.expect(demo.insertText("X"));
    try std.testing.expectEqualStrings("EggyX", demo.editable[0].text.slice());
    try std.testing.expect(demo.backspace());
    try std.testing.expectEqualStrings("Eggy", demo.editable[0].text.slice());
    try std.testing.expect(demo.accessibilityAction(313, .focus));
    try std.testing.expect(demo.insertText("8"));
    try std.testing.expectEqual(@as(u8, '8'), demo.otp[3]);
    try std.testing.expect(demo.accessibilityAction(320, .click));
    try std.testing.expectEqual(@as(usize, 1), demo.select_index);
    try std.testing.expect(demo.accessibilityAction(331, .click));
    try std.testing.expectEqual(@as(u32, 331), demo.selected_radio);
    try std.testing.expect(demo.accessibilityAction(371, .click));
    try std.testing.expect(demo.open_advanced);
    try std.testing.expect(demo.accessibilityAction(393, .click));
    try std.testing.expectEqual(@as(u16, 2), demo.page);
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expectEqual(@as(u32, 392), demo.focusId());
    try std.testing.expect(demo.accessibilityAction(390, .click));
    try std.testing.expectEqual(@as(u16, 1), demo.page);
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expectEqual(@as(u32, 391), demo.focusId());
    try std.testing.expect(demo.accessibilityAction(1028, .click));
    try std.testing.expectEqual(@as(u8, 28), demo.date.day);
    try std.testing.expect(!demo.calendar_open);
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expect(!demo.accessibilityAction(1028, .click));
    try std.testing.expect(demo.accessibilityAction(411, .click));
    try std.testing.expectEqual(@as(usize, 1), demo.slide);
    try std.testing.expect(demo.accessibilityAction(450, .click));
    try std.testing.expect(demo.sorted_descending);
    try std.testing.expect(demo.accessibilityAction(470, .click));
    try std.testing.expect(demo.file_request and demo.file_picker_open);
    demo.file_request = false;
    demo.selectedFile("project.svg");
    try std.testing.expect(!demo.file_picker_open);
    try std.testing.expectEqualStrings("project.svg", demo.filename.slice());
    try std.testing.expect(demo.accessibilityAction(480, .increment));
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), demo.divider, 0.001);
    try std.testing.expect(demo.accessibilityAction(490, .click));
    try std.testing.expect(!demo.dialog_open);
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expect(!demo.accessibilityAction(490, .click));
    try std.testing.expect(demo.accessibilityAction(491, .click));
    try std.testing.expectEqual(@as(u32, 1), demo.retry_count);
    demo.scroll.ensureVisible(demo.preview_scroll.viewport);
    demo.scroll.offset.y = @max(0, demo.scroll.offset.y - 40);
    try demo.relayout(std.testing.allocator, viewport, &font);
    const pane = demo.preview_scroll.viewport;
    const outer_before = demo.scroll.offset.y;
    demo.scrollWheel(pane.center().x, pane.center().y, 0, -1);
    try std.testing.expect(demo.preview_scroll.offset.y > 0);
    try std.testing.expectEqual(outer_before, demo.scroll.offset.y);
    demo.scrollWheel(pane.center().x, pane.center().y, 0, -10);
    try std.testing.expect(demo.scroll.offset.y > outer_before);
}

test "3D viewport bounds follow gallery scroll and width" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    const wide = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    try demo.relayout(std.testing.allocator, wide, &font);
    try std.testing.expectEqual(@as(f32, 224), demo.scene_viewport.h);
    try std.testing.expectEqual(@as(f32, 0), demo.scene_clip.h);
    demo.scroll.ensureVisible(demo.scene_viewport);
    try demo.relayout(std.testing.allocator, wide, &font);
    try std.testing.expect(demo.scene_clip.h > 0);
    try std.testing.expect(demo.scene_clip.y >= demo.scroll.viewport.y);
    try std.testing.expect(demo.scene_clip.y + demo.scene_clip.h <= demo.scroll.viewport.y + demo.scroll.viewport.h);
    const narrow = ui.Rect{ .x = 0, .y = 0, .w = 360, .h = 675 };
    try demo.relayout(std.testing.allocator, narrow, &font);
    try std.testing.expect(demo.scene_viewport.w <= demo.scroll.viewport.w);
    demo.scroll.ensureVisible(demo.scene_viewport);
    try demo.relayout(std.testing.allocator, narrow, &font);
    try std.testing.expect(demo.scene_clip.w > 0 and demo.scene_clip.h > 0);
}

fn snapshotNode(snapshot: ui.accessibility.Snapshot, id: u64) ?ui.accessibility.Node {
    for (snapshot.nodes) |node| if (node.id == id) return node;
    return null;
}
