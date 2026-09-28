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
pub const AccessibilityAction = enum(i32) { focus, click, increment, decrement, set_value, set_selection };
pub const EditKey = enum { left, right, up, down, home, end, delete, backspace, select_all, undo, redo };

const TextBuffer = ui.TextEdit(128);
fn textBuffer(comptime initial: []const u8) TextBuffer {
    return TextBuffer.init(initial) catch unreachable;
}
const Editable = struct { id: u32, text: TextBuffer };

pub const Demo = struct {
    focus: usize = 0,
    restore_focus: ?u32 = null,
    control_count: usize = 0,
    control_ids: [128]u32 = [_]u32{0} ** 128,
    control_clips: [128]ui.Rect = [_]ui.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 128,
    selected_tab: u32 = details_tab_id,
    checked: bool = true,
    enabled: bool = false,
    count: u32 = 0,
    select_index: usize = 0,
    select_open: bool = false,
    selected_radio: u32 = 330,
    selected_view: u32 = 340,
    open_appearance: bool = true,
    open_advanced: bool = false,
    page: u16 = 1,
    date: ui.widgets.Date = .{ .year = 2024, .month = 2, .day = 29 },
    calendar_open: bool = true,
    slide: usize = 0,
    menu_highlight: u32 = 420,
    menu_open: bool = false,
    context_point: ?ui.Vec2 = null,
    combo_highlight: u32 = 431,
    command_highlight: u32 = 441,
    combo_open: bool = false,
    command_open: bool = false,
    popover_open: bool = false,
    hover_card_open: bool = false,
    tooltip_open: bool = false,
    toast_visible: bool = false,
    sidebar_selection: u32 = 520,
    sorted_descending: bool = false,
    table_lines: bool = false,
    selected_item: bool = false,
    files_created: u32 = 0,
    folders_created: u32 = 0,
    divider: f32 = 0.5,
    dialog_open: bool = false,
    retry_count: u32 = 0,
    status: []const u8 = "Change a control to see its state.",
    file_request: bool = false,
    file_picker_open: bool = false,
    filename: TextBuffer = textBuffer("No file selected"),
    editable: [5]Editable = .{
        .{ .id = 300, .text = textBuffer("Eggy") },
        .{ .id = 301, .text = textBuffer("Describe the project") },
        .{ .id = 302, .text = textBuffer("42") },
        .{ .id = 430, .text = textBuffer("sea") },
        .{ .id = 440, .text = textBuffer("new") },
    },
    editing_scroll_x: [5]f32 = @splat(0),
    editing_scroll_y: [5]f32 = @splat(0),
    composition: [128]u8 = undefined,
    composition_len: usize = 0,
    composition_cursor: ?usize = null,
    dragging_text: bool = false,
    otp: [4]u8 = .{ '1', '2', '3', 0 },
    ui_scale: f32 = 1,
    animation_phase: f32 = 0,
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
    message_scroll: L.ScrollState = .{ .auto_scroll = true },
    message_count: usize = 3,
    controls: [128]ui.Rect = [_]ui.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 128,
    scene_viewport: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    scene_clip: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    overlay_rects: [7]ui.Rect = [_]ui.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 7,

    pub fn relayout(self: *Demo, allocator: std.mem.Allocator, viewport: ui.Rect, font: *const ui.Font) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var count_buf: [20]u8 = undefined;
        const root = try layoutTree(.{ .allocator = arena.allocator() }, self, viewport, &count_buf, font);
        try self.saveControls(root, font);
    }
    pub fn accessibilitySnapshot(self: *Demo, allocator: std.mem.Allocator, viewport: ui.Rect, font: *const ui.Font) !ui.accessibility.Snapshot {
        var count_buf: [20]u8 = undefined;
        const root = try layoutTree(.{ .allocator = allocator }, self, viewport, &count_buf, font);
        try self.saveControls(root, font);
        return ui.accessibility.collect(allocator, if (self.dialog_open) root.find(488).? else root, self.focusId());
    }
    pub fn accessibilityAction(self: *Demo, id: u32, action: AccessibilityAction) bool {
        if (action == .set_value or action == .set_selection) return false;
        const index = self.indexOf(id) orelse return false;
        if ((action == .click and (id == slider_id or id == 480)) or
            ((action == .increment or action == .decrement) and id != slider_id and id != 480)) return false;
        self.restore_focus = null;
        if (self.focusId() != id) self.composition_len = 0;
        if (!self.dialog_open and action == .click and !popupRelated(id)) _ = self.dismiss();
        self.focus = index;
        if (!self.dialog_open) self.scroll.ensureVisible(self.controls[self.indexOf(self.popupAnchor(id)) orelse index]);
        switch (action) {
            .focus => {},
            .click => self.activate(),
            .increment, .decrement => {
                if (id == 480) {
                    self.divider = std.math.clamp(self.divider + (if (action == .increment) @as(f32, 0.05) else -0.05), 0.1, 0.9);
                } else self.nudgeScale(if (action == .increment) 1 else -1);
            },
            .set_value, .set_selection => unreachable,
        }
        return true;
    }
    pub fn accessibilitySetValue(self: *Demo, id: u32, value: []const u8) bool {
        const index = self.indexOf(id) orelse return false;
        const field = self.editableFor(id) orelse return false;
        if (id != 301 and std.mem.indexOfAny(u8, value, "\r\n") != null) {
            self.status = "This field is single-line.";
            std.log.warn("AccessKit input contains a newline", .{});
            return false;
        }
        const editor = &self.editable[field].text;
        editor.replace(.{ .start = 0, .end = editor.len }, value) catch |err| {
            self.status = "Accessibility text update rejected.";
            std.log.warn("AccessKit input rejected: {s}", .{@errorName(err)});
            return false;
        };
        self.focus = index;
        return true;
    }
    pub fn accessibilitySetSelection(self: *Demo, id: u32, anchor: usize, focus_position: usize) bool {
        const index = self.indexOf(id) orelse return false;
        const field = self.editableFor(id) orelse return false;
        const text = &self.editable[field].text;
        const first = byteOffsetForCharacter(text.text(), anchor) orelse return false;
        const last = byteOffsetForCharacter(text.text(), focus_position) orelse return false;
        text.setCursor(first, false) catch unreachable;
        text.setCursor(last, true) catch unreachable;
        self.focus = index;
        return true;
    }
    pub fn draw(self: *Demo, allocator: std.mem.Allocator, canvas: *ui.Canvas, viewport: ui.Rect) !usize {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var count_buf: [20]u8 = undefined;
        const root = try layoutTree(.{ .allocator = arena.allocator() }, self, viewport, &count_buf, canvas.font);
        try self.saveControls(root, canvas.font);
        try root.drawWithoutOverlays(canvas);
        const base_vertices = canvas.len;
        try root.drawOverlays(canvas);
        return base_vertices;
    }
    pub fn focusId(self: *const Demo) u32 {
        return if (self.control_count > 0) self.control_ids[self.focus] else button_id;
    }
    fn indexOf(self: *const Demo, id: u32) ?usize {
        return std.mem.indexOfScalar(u32, self.control_ids[0..self.control_count], id);
    }
    fn saveControls(self: *Demo, root: *L.Element, font: *const ui.Font) !void {
        const old_id = self.restore_focus orelse self.focusId();
        self.restore_focus = null;
        self.control_count = 0;
        if (self.dialog_open) {
            try self.collectLayer(root.find(488).?);
        } else {
            try self.collectControls(root, false, 0);
            var after: ?i16 = null;
            while (root.overlayLayerAfter(after)) |z| {
                try self.collectControls(root, true, z);
                after = z;
            }
        }
        self.focus = self.indexOf(old_id) orelse 0;
        self.markFocus(root, font);
        for ([_]u32{ 325, 423, 427, 433, 436, 438, 445 }, 0..) |id, i| {
            self.overlay_rects[i] = if (root.find(id)) |overlay| overlay.bounds.intersection(overlay.clip) else .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        }
        self.divider_track = if (root.find(481)) |track| track.bounds else .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        if (root.find(500)) |scene| {
            self.scene_viewport = scene.bounds;
            self.scene_clip = scene.clip.intersection(scene.bounds);
        } else {
            self.scene_viewport = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            self.scene_clip = self.scene_viewport;
        }
    }
    fn markFocus(self: *Demo, element: *L.Element, font: *const ui.Font) void {
        const focused = element.id != 0 and element.id == self.focusId();
        switch (element.paint_kind) {
            .button => |*button| button.focused = focused,
            .checkbox => |*checkbox| checkbox.focused = focused,
            .toggle => |*toggle| toggle.focused = focused,
            .slider => |*slider| slider.focused = focused,
            .input => |*input| {
                input.focused = focused;
                if (focused) if (self.editableFor(element.id)) |i| {
                    const editor = &self.editable[i].text;
                    const area = ui.text_edit.inputContentRect(element.bounds);
                    var layout = ui.text_edit.TextLayout{
                        .font = font,
                        .size = 16,
                        .area = area,
                        .multiline = input.multiline,
                        .scroll_x = self.editing_scroll_x[i],
                        .scroll_y = self.editing_scroll_y[i],
                    };
                    const caret = layout.caretRect(.{ .before = editor.text() }, editor.cursor);
                    if (caret.x < area.x) self.editing_scroll_x[i] = @max(0, layout.scroll_x - (area.x - caret.x) - 4);
                    if (caret.x >= area.x + area.w) self.editing_scroll_x[i] += caret.x - area.x - area.w + 4;
                    if (input.multiline) {
                        if (caret.y < area.y) self.editing_scroll_y[i] = @max(0, layout.scroll_y - (area.y - caret.y));
                        if (caret.y + caret.h > area.y + area.h) self.editing_scroll_y[i] += caret.y + caret.h - area.y - area.h;
                    }
                    layout.scroll_x = self.editing_scroll_x[i];
                    input.cursor = editor.cursor;
                    input.selection = editor.selection();
                    input.caret_visible = self.animation_phase < 0.5 or self.dragging_text or self.composition_len > 0;
                    input.scroll_x = layout.scroll_x;
                    input.scroll_y = self.editing_scroll_y[i];
                    if (self.composition_len > 0) input.composition = .{ .text = self.composition[0..self.composition_len], .cursor = self.composition_cursor };
                };
            },
            .radio => |*radio| radio.focused = focused,
            .toggle_button => |*toggle_button| toggle_button.focused = focused,
            .tab => |*tab| tab.focused = focused,
            else => {
                if (focused and element.accessibility.role == .radio) element.children[0].paint_kind.radio.focused = true;
            },
        }
        for (element.children) |child| self.markFocus(child, font);
    }
    fn collectLayer(self: *Demo, element: *const L.Element) !void {
        if (element.actionable()) try self.recordControl(element);
        for (0..element.children.len) |i| try self.collectLayer(element.paintChild(i));
    }
    fn collectControls(self: *Demo, element: *const L.Element, overlays: bool, z: i16) !void {
        if (element.overlay != null) {
            if (overlays and element.style.z_index == z) try self.collectLayer(element);
            return;
        }
        if (!overlays and element.actionable()) try self.recordControl(element);
        for (0..element.children.len) |i| try self.collectControls(element.paintChild(i), overlays, z);
    }
    fn recordControl(self: *Demo, element: *const L.Element) !void {
        if (self.control_count == self.controls.len) return error.TooManyControls;
        const i = self.control_count;
        self.controls[i] = element.bounds;
        self.control_clips[i] = element.bounds.intersection(element.clip);
        self.control_ids[i] = element.id;
        self.control_count += 1;
    }
    fn panes(self: *Demo) [2]*L.ScrollState {
        return .{ &self.preview_scroll, &self.message_scroll };
    }
    pub fn tickScroll(self: *Demo, dt: f32) void {
        for (self.panes()) |pane| pane.tick(dt);
    }
    pub fn scrollDragging(self: *Demo) bool {
        for (self.panes()) |pane| if (pane.dragging != .none) return true;
        return self.scroll.dragging != .none;
    }
    pub fn scrollWheel(self: *Demo, x: f32, y: f32, dx: f32, dy: f32) void {
        if (self.dialog_open) return;
        for (self.panes()) |pane| {
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
        self.composition_len = 0;
        const id = self.focusId();
        if (id >= 310 and id <= 313) {
            if (text.len != 1 or !std.ascii.isDigit(text[0])) {
                self.status = "OTP accepts one digit per slot.";
                std.log.warn("Invalid OTP input", .{});
                return true;
            }
            self.otp[id - 310] = text[0];
            if (self.indexOf(id + 1)) |next_index| self.focus = next_index;
            return true;
        }
        if (self.editableFor(id)) |i| {
            if (id != 301 and std.mem.indexOfAny(u8, text, "\r\n") != null) {
                self.status = "This field is single-line.";
                return true;
            }
            self.editable[i].text.insert(text) catch |err| {
                self.status = switch (err) {
                    error.Full => "Input is full (128 bytes).",
                    else => "Invalid text input.",
                };
                std.log.warn("Text input rejected: {s}", .{@errorName(err)});
                return true;
            };
            if (id == 430) self.combo_open = true;
            if (id == 440) self.command_open = true;
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
            if (id == 430) self.combo_open = true;
            if (id == 440) self.command_open = true;
            return true;
        }
        return false;
    }
    pub fn editKey(self: *Demo, key: EditKey, extend: bool, word: bool, font: *const ui.Font) bool {
        const id = self.focusId();
        const i = self.editableFor(id) orelse return false;
        const editor = &self.editable[i].text;
        switch (key) {
            .left => editor.moveLeft(extend, word),
            .right => editor.moveRight(extend, word),
            .up, .down => {
                if (id != 301) return false;
                const area = ui.text_edit.inputContentRect(self.controls[self.focus]);
                const layout = ui.text_edit.TextLayout{
                    .font = font,
                    .size = 16,
                    .area = area,
                    .multiline = true,
                    .scroll_x = self.editing_scroll_x[i],
                    .scroll_y = self.editing_scroll_y[i],
                };
                const caret = layout.caretRect(.{ .before = editor.text() }, editor.cursor);
                const x = editor.preferred_x orelse caret.x;
                editor.placeCaretIn(layout, x, caret.center().y + (if (key == .up) @as(f32, -1) else 1) * 16 * 1.35, extend);
                editor.preferred_x = x;
            },
            .home => if (word) editor.moveDocumentStart(extend) else editor.moveHome(extend),
            .end => if (word) editor.moveDocumentEnd(extend) else editor.moveEnd(extend),
            .delete => editor.delete(),
            .backspace => editor.backspace(),
            .select_all => editor.selectAll(),
            .undo => _ = editor.undo(),
            .redo => _ = editor.redo(),
        }
        return true;
    }
    pub fn selectedText(self: *const Demo) ?[]const u8 {
        const i = self.editableFor(self.focusId()) orelse return null;
        const editor = &self.editable[i].text;
        const selection = editor.selection() orelse return null;
        return editor.text()[selection.start..selection.end];
    }
    pub fn cutSelection(self: *Demo) void {
        const i = self.editableFor(self.focusId()) orelse return;
        self.editable[i].text.insert("") catch unreachable;
    }
    pub fn setComposition(self: *Demo, text: []const u8, cursor: ?usize) void {
        if (!self.isEditing() or text.len == 0) {
            self.composition_len = 0;
            self.composition_cursor = null;
            return;
        }
        if (text.len > self.composition.len or !std.unicode.utf8ValidateSlice(text)) {
            self.composition_len = 0;
            self.status = "IME preedit cannot be displayed.";
            std.log.warn("Invalid or oversized IME preedit", .{});
            return;
        }
        @memcpy(self.composition[0..text.len], text);
        self.composition_len = text.len;
        self.composition_cursor = if (cursor) |at| byteOffsetForCharacter(text, at) else null;
        if (cursor != null and self.composition_cursor == null) {
            self.status = "IME cursor position is invalid.";
            std.log.warn("Invalid IME cursor position: {d}", .{cursor.?});
        }
    }
    pub fn menuMove(self: *Demo, direction: i8) bool {
        const id = self.focusId();
        if (id == 320 and !self.select_open) {
            _ = self.dismiss();
            self.select_open = true;
            self.restore_focus = 322 + @as(u32, @intCast(self.select_index));
            return true;
        }
        if (id == 419 and !self.menu_open) {
            _ = self.dismiss();
            self.menu_open = true;
            self.restore_focus = self.menu_highlight;
            return true;
        }
        if (id == 430 and !self.combo_open) {
            _ = self.dismiss();
            self.combo_open = true;
            self.restore_focus = self.combo_highlight;
            return true;
        }
        if (id == 440 and !self.command_open) {
            _ = self.dismiss();
            self.command_open = true;
            self.restore_focus = self.command_highlight;
            return true;
        }
        const all: []const u32 = if (self.select_open and (id == 320 or id >= 322 and id <= 324)) &.{ 322, 323, 324 } else if (self.menu_open and (id == 419 or id == 420 or id == 421)) &.{ 420, 421 } else if (self.context_point != null and (id == 426 or id == 420 or id == 421)) &.{ 420, 421 } else if (self.combo_open and (id == 430 or id == 431 or id == 432)) &.{ 431, 432 } else if (self.command_open and (id == 440 or id == 441 or id == 442)) &.{ 441, 442 } else return false;
        var visible: [3]u32 = undefined;
        var count: usize = 0;
        for (all) |choice| if (self.indexOf(choice) != null) {
            visible[count] = choice;
            count += 1;
        };
        if (count == 0) return false;
        const selected = std.mem.indexOfScalar(u32, visible[0..count], id) orelse (if (direction > 0) count - 1 else @as(usize, 0));
        const next_index = if (direction > 0) (selected + 1) % count else (selected + count - 1) % count;
        self.focus = self.indexOf(visible[next_index]).?;
        if (self.menu_open or self.context_point != null) self.menu_highlight = visible[next_index];
        if (self.combo_open) self.combo_highlight = visible[next_index];
        if (self.command_open) self.command_highlight = visible[next_index];
        return true;
    }
    pub fn menuTypeAhead(self: *Demo, text: []const u8) bool {
        if (text.len != 1 or !std.ascii.isAlphabetic(text[0])) return false;
        const id = self.focusId();
        const choices: []const ui.widgets.Choice = if (self.select_open and (id == 320 or id >= 322 and id <= 324)) &.{ .{ .id = 322, .label = "Compact" }, .{ .id = 323, .label = "Comfortable" }, .{ .id = 324, .label = "Spacious" } } else if ((self.menu_open or self.context_point != null) and (id == 419 or id == 426 or id == 420 or id == 421)) &.{ .{ .id = 420, .label = "Open" }, .{ .id = 421, .label = "Rename" } } else if (self.command_open and (id == 441 or id == 442)) &.{ .{ .id = 441, .label = "New file" }, .{ .id = 442, .label = "New folder" } } else return false;
        for (choices) |choice| {
            if (std.ascii.toLower(choice.label[0]) != std.ascii.toLower(text[0])) continue;
            self.focus = self.indexOf(choice.id) orelse continue;
            if (choice.id == 420 or choice.id == 421) self.menu_highlight = choice.id;
            return true;
        }
        return false;
    }
    pub fn moveComposite(self: *Demo, direction: i8) bool {
        const id = self.focusId();
        const peers: []const u32 = switch (id) {
            330, 331 => &.{ 330, 331 },
            340, 341 => &.{ 340, 341 },
            overview_tab_id, details_tab_id => &.{ overview_tab_id, details_tab_id },
            370, 371 => &.{ 370, 371 },
            else => return false,
        };
        const current = std.mem.indexOfScalar(u32, peers, id).?;
        const next_index = if (direction > 0) (current + 1) % peers.len else (current + peers.len - 1) % peers.len;
        const index = self.indexOf(peers[next_index]) orelse return false;
        self.focus = index;
        if (id != 370 and id != 371) self.activate();
        return true;
    }
    pub fn confirmMenu(self: *Demo) bool {
        if (self.composition_len > 0) return false;
        const id = self.focusId();
        const chosen = if (id == 320 and self.select_open) @as(u32, 322 + @as(u32, @intCast(self.select_index))) else if (id == 419 and self.menu_open) self.menu_highlight else if (id == 430 and self.combo_open) self.combo_highlight else if (id == 440 and self.command_open) self.command_highlight else return false;
        self.focus = self.indexOf(chosen) orelse return false;
        self.activate();
        return true;
    }
    pub fn submitForm(self: *Demo) void {
        self.status = if (self.editable[0].text.text().len == 0) "Project name is required." else "Settings applied.";
    }
    pub fn selectedFile(self: *Demo, name: []const u8) void {
        self.file_picker_open = false;
        self.filename.set(name) catch |err| {
            self.status = "Selected filename cannot be displayed.";
            std.log.warn("Selected filename rejected: {s}", .{@errorName(err)});
            return;
        };
        self.status = "File selected.";
    }
    pub fn pointerDown(self: *Demo, x: f32, y: f32) void {
        self.pointerDownAt(x, y, null);
    }
    pub fn pointerDownAt(self: *Demo, x: f32, y: f32, font: ?*const ui.Font) void {
        self.pointerDownWithClicks(x, y, font, 1);
    }
    pub fn pointerDownWithClicks(self: *Demo, x: f32, y: f32, font: ?*const ui.Font, clicks: u8) void {
        self.pointer_x = x;
        self.pointer_y = y;
        if (!self.dialog_open and self.scroll.pointerDown(x, y)) return;
        if (!self.dialog_open and self.scroll.viewport.contains(x, y)) for (self.panes()) |pane| if (pane.pointerDown(x, y)) return;
        if (!self.dialog_open) {
            var in_popup = false;
            for (self.overlay_rects) |rect| if (rect.contains(x, y)) {
                in_popup = true;
            };
            if (in_popup) {
                var matched = false;
                for (self.control_clips[0..self.control_count]) |rect| if (rect.contains(x, y)) {
                    matched = true;
                };
                if (!matched) return;
            }
        }
        var i = self.control_count;
        while (i > 0) {
            i -= 1;
            if (!self.control_clips[i].contains(x, y)) continue;
            self.restore_focus = null;
            self.focus = i;
            if (!self.dialog_open and !popupRelated(self.focusId())) _ = self.dismiss();
            self.composition_len = 0;
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
                else => {
                    if (font) |face| if (self.editableFor(self.focusId())) |field| {
                        const element = &self.editable[field].text;
                        element.placeCaretIn(.{
                            .font = face,
                            .size = 16,
                            .area = ui.text_edit.inputContentRect(self.controls[i]),
                            .multiline = self.focusId() == 301,
                            .scroll_x = self.editing_scroll_x[field],
                            .scroll_y = self.editing_scroll_y[field],
                        }, x, y, false);
                        if (clicks >= 3) {
                            if (self.focusId() == 301) element.selectLine() else element.selectAll();
                        } else if (clicks == 2) element.selectWord();
                        self.dragging_text = clicks <= 1;
                    };
                    self.activate();
                },
            }
            return;
        }
        if (self.dialog_open) return;
        _ = self.dismiss();
    }
    pub fn pointerContextDown(self: *Demo, x: f32, y: f32) void {
        if (self.dialog_open) return;
        const index = self.indexOf(426) orelse return;
        if (!self.control_clips[index].contains(x, y)) {
            self.context_point = null;
            return;
        }
        _ = self.dismiss();
        self.context_point = .init(x, y);
    }
    pub fn pointerMove(self: *Demo, x: f32, y: f32) void {
        self.pointerMoveAt(x, y, null);
    }
    pub fn pointerMoveAt(self: *Demo, x: f32, y: f32, font: ?*const ui.Font) void {
        self.pointer_x = x;
        self.pointer_y = y;
        self.scroll.pointerMove(x, y);
        for (self.panes()) |pane| pane.pointerMove(x, y);
        if (self.dragging_slider) self.setScaleFromPointer(x);
        if (self.dragging_divider) self.setDividerFromPointer(x);
        if (self.dragging_text) if (font) |face| if (self.editableFor(self.focusId())) |field| {
            self.editable[field].text.placeCaretIn(.{
                .font = face,
                .size = 16,
                .area = ui.text_edit.inputContentRect(self.controls[self.focus]),
                .multiline = self.focusId() == 301,
                .scroll_x = self.editing_scroll_x[field],
                .scroll_y = self.editing_scroll_y[field],
            }, x, y, true);
        };
        if (!self.dialog_open) {
            const hover_index = self.indexOf(437);
            self.hover_card_open = (if (hover_index) |index| self.control_clips[index].contains(x, y) else false) or self.overlay_rects[5].contains(x, y);
            const tip_index = self.indexOf(439);
            self.tooltip_open = if (tip_index) |index| self.control_clips[index].contains(x, y) else false;
        }
    }
    pub fn pointerUp(self: *Demo) void {
        self.scroll.pointerUp();
        for (self.panes()) |pane| pane.pointerUp();
        self.dragging_slider = false;
        self.dragging_divider = false;
        self.dragging_text = false;
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
        self.composition_len = 0;
        self.focus = if (reverse) (self.focus + self.control_count - 1) % self.control_count else (self.focus + 1) % self.control_count;
        if (!self.dialog_open) self.scroll.ensureVisible(self.controls[self.indexOf(self.popupAnchor(self.focusId())) orelse self.focus]);
    }
    pub fn dismiss(self: *Demo) bool {
        if (self.dialog_open) {
            self.closeDialog();
            return true;
        }
        const had_popup = self.select_open or self.menu_open or self.context_point != null or self.combo_open or self.command_open or self.popover_open;
        self.select_open = false;
        self.menu_open = false;
        self.context_point = null;
        self.combo_open = false;
        self.command_open = false;
        self.popover_open = false;
        return had_popup;
    }
    fn closeDialog(self: *Demo) void {
        self.dialog_open = false;
        self.restore_focus = 489;
    }
    fn popupAnchor(self: *const Demo, id: u32) u32 {
        return switch (id) {
            322...324 => 320,
            420, 421 => if (self.context_point != null) 426 else 419,
            431, 432 => 430,
            441, 442 => 440,
            1001...1037 => 400,
            else => id,
        };
    }
    pub fn activate(self: *Demo) void {
        const id = self.focusId();
        switch (id) {
            button_id => self.count += 1,
            checkbox_id => self.checked = !self.checked,
            toggle_id => self.enabled = !self.enabled,
            slider_id, 300, 301, 302, 310...313, 480 => {},
            320 => {
                const open = !self.select_open;
                _ = self.dismiss();
                self.select_open = open;
            },
            322...324 => {
                self.select_index = id - 322;
                self.select_open = false;
                self.restore_focus = 320;
                self.status = "Size selected.";
            },
            330, 331 => self.selected_radio = id,
            340, 341 => self.selected_view = id,
            350 => self.submitForm(),
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
                self.restore_focus = 400;
            },
            1032, 1033 => {
                self.date = ui.widgets.shiftMonth(self.date, if (id == 1032) .previous else .next) catch |err| {
                    self.status = "Cannot navigate beyond supported calendar years.";
                    std.log.warn("Calendar navigation rejected: {s}", .{@errorName(err)});
                    return;
                };
            },
            1034 => self.date.hour = (self.date.hour + 23) % 24,
            1035 => self.date.hour = (self.date.hour + 1) % 24,
            1036 => self.date.minute = (self.date.minute + 45) % 60,
            1037 => self.date.minute = (self.date.minute + 15) % 60,
            410 => self.slide = (self.slide + 1) % 2,
            411 => self.slide = (self.slide + 1) % 2,
            419 => {
                const open = !self.menu_open;
                _ = self.dismiss();
                self.menu_open = open;
            },
            420, 421 => {
                self.menu_highlight = id;
                if (id == 420) {
                    self.selected_item = true;
                    self.sidebar_selection = 520;
                    self.status = "Project opened in Workspace.";
                    self.restore_focus = 460;
                } else {
                    self.editable[0].text.selectAll();
                    self.status = "Rename the project in the Project field.";
                    self.restore_focus = 300;
                }
                self.menu_open = false;
                self.context_point = null;
            },
            426 => self.status = "Right-click to open the context menu.",
            430 => {
                const open = !self.combo_open;
                _ = self.dismiss();
                self.combo_open = open;
            },
            431, 432 => {
                self.combo_highlight = id;
                self.editable[3].text.set(if (id == 431) "Search" else "Settings") catch unreachable;
                if (id == 431) {
                    self.status = "Search by editing the Project field.";
                    self.restore_focus = 300;
                } else {
                    self.sidebar_selection = 522;
                    self.status = "Settings opened.";
                    self.restore_focus = 522;
                }
                self.combo_open = false;
            },
            435 => {
                const open = !self.popover_open;
                _ = self.dismiss();
                self.popover_open = open;
            },
            437, 439 => {},
            440 => {
                const open = !self.command_open;
                _ = self.dismiss();
                self.command_open = open;
            },
            441, 442, 530, 531 => {
                if (id == 441 or id == 442) self.command_highlight = id;
                if (id == 441 or id == 530) {
                    self.files_created += 1;
                    self.status = "New file created.";
                } else {
                    self.folders_created += 1;
                    self.status = "New folder created.";
                }
                if (id == 441 or id == 442) {
                    self.command_open = false;
                    self.restore_focus = 440;
                }
            },
            443 => self.toast_visible = true,
            444 => self.toast_visible = false,
            450, 451 => self.sorted_descending = !self.sorted_descending,
            452 => self.table_lines = !self.table_lines,
            460 => self.selected_item = !self.selected_item,
            470 => {
                if (!self.file_picker_open) {
                    self.file_request = true;
                    self.file_picker_open = true;
                    self.status = "Opening file picker...";
                }
            },
            498 => {
                if (self.message_count < 8) {
                    self.message_count += 1;
                    self.status = "Message appended.";
                } else self.status = "Demo transcript is full.";
            },
            499 => {
                self.message_scroll.jumpToMessageEnd();
                self.status = "Showing latest messages.";
            },
            489 => {
                _ = self.dismiss();
                self.dialog_open = true;
            },
            490 => {
                self.closeDialog();
                self.status = "Dialog confirmed.";
            },
            492 => self.closeDialog(),
            491 => {
                self.retry_count += 1;
                self.status = "Search retried.";
            },
            520...522 => {
                self.sidebar_selection = id;
                self.status = switch (id) {
                    520 => "Workspace selected.",
                    521 => "Dashboard selected.",
                    else => "Settings selected.",
                };
            },
            533 => self.checked = !self.checked,
            534 => self.enabled = !self.enabled,
            535 => self.submitForm(),
            536 => {
                self.restore_focus = 300;
                if (self.indexOf(300)) |index| self.scroll.ensureVisible(self.controls[index]);
            },
            else => std.log.warn("Unimplemented demo control: {d}", .{id}),
        }
    }
};

fn popupRelated(id: u32) bool {
    return switch (id) {
        320, 322...324, 419...421, 426, 430...432, 435, 437, 439...442 => true,
        else => false,
    };
}
fn byteOffsetForCharacter(text: []const u8, index: usize) ?usize {
    var at: usize = 0;
    var count: usize = 0;
    while (count < index and at < text.len) : (count += 1) {
        const size = std.unicode.utf8ByteSequenceLength(text[at]) catch return null;
        at += size;
    }
    return if (count == index) at else null;
}

fn label(b: L.Builder, value: []const u8, size: f32, muted: bool, wrap: bool) !*L.Element {
    return b.node(0, .{}, .{ .text = .{ .value = value, .size = size, .tone = if (muted) .muted else .foreground, .wrap = wrap } }, &.{});
}
fn line(b: L.Builder) !*L.Element {
    return b.node(0, .{ .height = 1 }, .separator, &.{});
}
fn layoutTree(b: L.Builder, demo: *Demo, viewport: ui.Rect, count_buf: *[20]u8, font: *const ui.Font) !*L.Element {
    var vertical = false;
    var horizontal = false;
    const requested_offset = demo.scroll.offset;
    var root: *L.Element = undefined;
    for (0..4) |_| {
        demo.scroll.vertical_bar = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        demo.scroll.horizontal_bar = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        root = try build(b, demo, viewport, count_buf, vertical, horizontal);
        root.layout(viewport, font);
        const need_vertical = demo.scroll.content.y > demo.scroll.viewport.h and demo.scroll.viewport.h >= 16;
        const need_horizontal = demo.scroll.content.x > demo.scroll.viewport.w and demo.scroll.viewport.w >= 16;
        if (need_vertical == vertical and need_horizontal == horizontal) return root;
        demo.scroll.offset = requested_offset;
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
    const base = if (horizontal) try b.node(0, .{ .width = viewport.w, .height = viewport.h }, .none, &.{ row, try b.node(horizontal_bar_id, .{ .width = content_width, .height = bar_width }, .{ .scrollbar = .{ .state = &demo.scroll, .axis = .horizontal } }, &.{}) }) else row;
    var layers: [3]*L.Element = undefined;
    var count_layers: usize = 0;
    layers[count_layers] = base;
    count_layers += 1;
    if (demo.dialog_open) {
        const modal = try ui.widgets.modal(b, viewport, .alert_dialog, &.{
            try label(b, "Confirm action", 22, false, false),
            try label(b, "The rest of the page is unavailable until this closes.", 15, true, true),
            try b.row(&.{ try b.button(490, "Continue"), try b.button(492, "Cancel") }),
        });
        modal.id = 488;
        modal.style.z_index = 300;
        modal.overlay = .viewport;
        modal.children[0].accessibility.label = "Confirm action";
        layers[count_layers] = modal;
        count_layers += 1;
    }
    if (demo.toast_visible and !demo.dialog_open) {
        layers[count_layers] = try ui.widgets.dismissibleToastAt(b, viewport, "Saved", "Your changes are ready.", 444);
        count_layers += 1;
    }
    return b.node(0, .{ .width = viewport.w, .height = viewport.h }, .none, layers[0..count_layers]);
}

fn componentGallery(b: L.Builder, demo: *Demo, page_width: f32) !*L.Element {
    const W = ui.widgets;
    const message_texts = [_][]const u8{ "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight" };
    var messages: [message_texts.len]*L.Element = undefined;
    for (messages[0..demo.message_count], 0..) |*entry, i| {
        entry.* = try W.message(b, if (i % 2 == 0) "Alice" else "Bob", message_texts[i]);
        entry.*.id = 600 + @as(u32, @intCast(i));
    }
    const inner_width = @max(192, page_width - 48);
    const sizes = [_][]const u8{ "Compact", "Comfortable", "Spacious" };
    var otp_len: usize = 0;
    while (otp_len < demo.otp.len and demo.otp[otp_len] != 0) : (otp_len += 1) {}

    const select = try W.select(b, 320, sizes[demo.select_index], "Choose size");
    select.accessibility.expanded = demo.select_open;
    if (demo.select_open) select.accessibility.controls = 325;
    const size_menu = try W.dropdownMenu(b, select, &.{ .{ .id = 322, .label = "Compact" }, .{ .id = 323, .label = "Comfortable" }, .{ .id = 324, .label = "Spacious" } }, 322 + @as(u32, @intCast(demo.select_index)), demo.select_open);
    const fields = try W.form(b, &.{
        try W.field(b, 300, "Project", .{ .value = demo.editable[0].text.text(), .placeholder = "Project name" }),
        try b.textarea(301, .{ .value = demo.editable[1].text.text(), .placeholder = "Description" }),
        try W.inputGroup(b, 302, "$", .{ .value = demo.editable[2].text.text(), .placeholder = "Amount" }, "USD"),
        try W.inputOtp(b, 310, demo.otp[0..otp_len], 4),
        if (size_menu) |popup| try b.node(0, .{ .width = 220 }, .none, &.{ select, blk: {
            popup.id = 325;
            break :blk popup;
        } }) else select,
    });
    const status = try label(b, demo.status, 14, true, true);
    status.accessibility = .{ .role = .status, .live = .polite };
    const choices = try b.card(&.{
        try label(b, "Fields and choices", 22, false, false),
        fields,
        try W.radioGroup(b, &.{ .{ .id = 330, .label = "Email" }, .{ .id = 331, .label = "Desktop" } }, demo.selected_radio),
        try W.toggleGroup(b, &.{ .{ .id = 340, .label = "Grid" }, .{ .id = 341, .label = "List" } }, if (demo.selected_view == 340) &.{340} else &.{341}),
        try W.buttonGroup(b, &.{ .{ .id = 350, .label = "Apply" }, .{ .id = 351, .label = "Reset" } }),
        status,
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
        try W.datePickerWithWidth(b, 400, 1000, demo.date, demo.calendar_open, @min(300, inner_width)),
        try W.carousel(b, 410, 411, &.{ try b.text("Slide one"), try b.text("Slide two") }, demo.slide),
    });

    const actions = try b.button(419, "Actions");
    actions.accessibility.expanded = demo.menu_open;
    if (demo.menu_open) actions.accessibility.controls = 423;
    const action_menu = try W.dropdownMenu(b, actions, &.{ .{ .id = 420, .label = "Open" }, .{ .id = 421, .label = "Rename" } }, demo.menu_highlight, demo.menu_open);
    const context_menu = try W.contextMenu(b, demo.context_point, &.{ .{ .id = 420, .label = "Open" }, .{ .id = 421, .label = "Rename" } }, demo.menu_highlight);
    const popover_trigger = try b.button(435, "Show popover");
    popover_trigger.accessibility.expanded = demo.popover_open;
    if (demo.popover_open) popover_trigger.accessibility.controls = 436;
    const hover_trigger = try b.button(437, "Hover card");
    const tip_trigger = try b.button(439, "Help");
    if (demo.tooltip_open or demo.focusId() == 439) tip_trigger.accessibility.described_by = 446;
    const combo = try W.combobox(b, 430, demo.editable[3].text.text(), &.{ .{ .id = 431, .label = "Search" }, .{ .id = 432, .label = "Settings" } }, demo.combo_highlight, demo.combo_open);
    if (demo.combo_open) combo.children[1].id = 433;
    const command = try W.combobox(b, 440, demo.editable[4].text.text(), &.{ .{ .id = 441, .label = "New file" }, .{ .id = 442, .label = "New folder" } }, demo.command_highlight, demo.command_open);
    if (demo.command_open) command.children[1].id = 445;
    const feedback = try b.card(&.{
        try label(b, "Menus and feedback", 22, false, false),
        try b.node(0, .{}, .none, if (action_menu) |popup| blk: {
            popup.id = 423;
            break :blk &.{ actions, popup };
        } else &.{actions}),
        try b.button(426, "Right-click here"),
        if (context_menu) |popup| blk: {
            popup.id = 427;
            break :blk popup;
        } else try b.node(0, .{ .height = 0 }, .none, &.{}),
        combo,
        command,
        try b.node(0, .{}, .none, if (demo.popover_open) blk: {
            const panel = try W.popoverAt(b, popover_trigger, &.{try b.text("Click outside or press Escape to dismiss.")});
            panel.id = 436;
            break :blk &.{ popover_trigger, panel };
        } else &.{popover_trigger}),
        try b.node(0, .{}, .none, if (demo.hover_card_open) blk: {
            const panel = try W.hoverCardAt(b, hover_trigger, &.{try b.text("A preview shown while hovering.")});
            panel.id = 438;
            break :blk &.{ hover_trigger, panel };
        } else &.{hover_trigger}),
        try b.node(0, .{}, .none, if (demo.tooltip_open or demo.focusId() == 439) blk: {
            const panel = try W.tooltipAt(b, tip_trigger, "Helpful tip");
            panel.id = 446;
            break :blk &.{ tip_trigger, panel };
        } else &.{tip_trigger}),
        try b.button(443, "Show toast"),
        try W.kbd(b, "Ctrl+K"),
    });

    const chart = try b.chart(&.{ 5, 8, 4, 9, 6 });
    chart.accessibility.label = "Activity over five periods";
    const workspace_button = try b.button(520, "Workspace");
    const dashboard_button = try b.button(521, "Dashboard");
    const settings_button = try b.button(522, "Settings");
    workspace_button.paint_kind.button.primary = demo.sidebar_selection == 520;
    dashboard_button.paint_kind.button.primary = demo.sidebar_selection == 521;
    settings_button.paint_kind.button.primary = demo.sidebar_selection == 522;
    const sidebar = try W.sidebar(b, 172, &.{ workspace_button, dashboard_button, settings_button });
    sidebar.style.width = @min(240, inner_width);
    const sidebar_content = switch (demo.sidebar_selection) {
        520 => try b.card(&.{
            try label(b, "Workspace", 20, false, false),
            try label(b, try std.fmt.allocPrint(b.allocator, "Project: {s}", .{demo.editable[0].text.text()}), 15, false, true),
            try b.row(&.{ try b.button(530, "New file"), try b.button(531, "New folder") }),
            try b.button(536, "Edit project"),
        }),
        521 => try b.card(&.{
            try label(b, "Dashboard: project activity", 20, false, true),
            try label(b, try std.fmt.allocPrint(b.allocator, "{d} files, {d} folders created", .{ demo.files_created, demo.folders_created }), 15, false, true),
            try b.chart(&.{ 5, 8, 4, 9, 6 }),
        }),
        else => try b.card(&.{
            try label(b, "Settings", 20, false, false),
            try b.node(533, .{ .height = 32 }, .{ .checkbox = .{ .label = "Show hints", .checked = demo.checked } }, &.{}),
            try b.node(534, .{ .height = 32 }, .{ .toggle = .{ .label = "Live updates", .enabled = demo.enabled } }, &.{}),
            try b.button(535, "Apply settings"),
        }),
    };
    sidebar_content.accessibility = .{ .role = .region, .label = switch (demo.sidebar_selection) {
        520 => "Workspace view",
        521 => "Dashboard view",
        else => "Settings view",
    } };
    if (demo.sidebar_selection == 521) sidebar_content.children[2].accessibility.label = "Project activity over five periods";
    sidebar_content.children[0].accessibility.role = .heading;
    const image = try b.node(0, .{ .width = 64, .height = 64 }, .{ .icon = .image }, &.{});
    image.accessibility = .{ .role = .image, .label = "Lucide Image SVG" };
    const item = try W.item(b, 460, try std.fmt.allocPrint(b.allocator, "{s}{s}", .{ demo.editable[0].text.text(), if (demo.selected_item) " (opened)" else "" }), "Composable content and metadata.", try b.avatar("EC"));
    item.accessibility = .{ .role = .button, .label = demo.editable[0].text.text(), .description = "Toggle selection" };
    const resizable = try W.resizable(b, .{ .x = 0, .y = 0, .w = @min(inner_width, 300), .h = 80 }, demo.divider, 480, try b.surface(.card, &.{try b.text("Left")}), try b.surface(.card, &.{try b.text("Right")}));
    resizable.id = 481;
    resizable.children[1].accessibility = .{ .role = .slider, .label = "Panel divider", .numeric_value = demo.divider };
    const scene = try b.node(500, .{ .width = @min(inner_width, 520), .height = 224 }, .none, &.{});
    scene.accessibility = .{ .role = .image, .label = "Rotating 3D viewport" };
    const data = try b.card(&.{
        try label(b, "Data and layout", 22, false, false),
        try W.dataTableWithOptions(b, &.{ .{ .id = 450, .label = "Name" }, .{ .id = 451, .label = "Status" } }, if (demo.sorted_descending) &.{ &.{ "Weeoui", "Alpha" }, &.{ demo.editable[0].text.text(), "Ready" } } else &.{ &.{ demo.editable[0].text.text(), "Ready" }, &.{ "Weeoui", "Alpha" } }, .{ .lines = demo.table_lines }),
        try b.button(452, if (demo.table_lines) "Hide table lines" else "Show table lines"),
        chart,
        try label(b, "3D scene (Vitellus)", 14, true, false),
        scene,
        try b.row(&.{ try b.avatar("AB"), try b.spinner(demo.animation_phase), try b.animatedSkeleton(72, 24, demo.animation_phase) }),
        try b.node(0, .{ .width = 160, .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 }, .gap = 8 }, .card, &.{
            image,
            try label(b, "Lucide SVG image", 14, true, false),
        }),
        item,
        try W.attachment(b, 470, demo.filename.text()),
        sidebar,
        sidebar_content,
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
        try W.messageScroller(b, .{ .x = 0, .y = 0, .w = @min(inner_width, 300), .h = 100 }, &demo.message_scroll, messages[0..demo.message_count]),
        try b.row(&.{ try b.button(498, "Add message"), try b.button(499, "Jump to latest") }),
        resizable,
        try W.aspectRatio(b, 160, 1.6, &.{try b.skeleton(160, 100)}),
        try b.button(489, "Open dialog"),
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
    try std.testing.expect(snapshotNode(snapshot, 421) == null);
    try std.testing.expect(demo.accessibilityAction(419, .click));
    const opened = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    const menu = snapshotNode(opened, 421).?;
    try std.testing.expectEqual(L.Accessibility.Role.menu_item, menu.role);
    try std.testing.expect(!menu.disabled and menu.actionable);
    try std.testing.expect(demo.accessibilityAction(421, .click));
    const closed = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(snapshotNode(closed, 421) == null);
    const field = snapshotNode(snapshot, 300).?;
    try std.testing.expectEqualStrings("Project", field.label);
    try std.testing.expectEqualStrings("Eggy", field.value);
    const day = snapshotNode(snapshot, 1029).?;
    try std.testing.expectEqualStrings("29", day.label);
    try std.testing.expect(!day.disabled and day.actionable);
    try std.testing.expectEqual(L.Accessibility.Role.column_header, snapshotNode(snapshot, 450).?.role);
    try std.testing.expect(snapshotNode(snapshot, 400).?.expanded.?);
    var found_chart = false;
    for (snapshot.nodes) |node| {
        try std.testing.expect(node.role != .alert_dialog);
        if (node.role == .image and std.mem.eql(u8, node.label, "Activity over five periods")) found_chart = true;
    }
    try std.testing.expect(found_chart);
    try std.testing.expect(demo.accessibilityAction(489, .click));
    const modal = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(snapshotNode(modal, button_id) == null);
    try std.testing.expect(snapshotNode(modal, 490) != null);
    var found_dialog = false;
    for (modal.nodes) |node| if (node.role == .alert_dialog) {
        found_dialog = node.modal;
    };
    try std.testing.expect(found_dialog);
    try std.testing.expect(demo.accessibilityAction(492, .click));
    _ = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(demo.accessibilityAction(button_id, .focus));

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
        419,
        426,
        430...432,
        435,
        437,
        439,
        440...442,
        443,
        450...452,
        460,
        470,
        480,
        489,
        491,
        498...499,
        520...522,
        530...531,
        533...536,
        1001...1037,
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
    try std.testing.expectEqualStrings("EggyX", demo.editable[0].text.text());
    try std.testing.expect(demo.backspace());
    try std.testing.expectEqualStrings("Eggy", demo.editable[0].text.text());
    try std.testing.expect(demo.accessibilityAction(313, .focus));
    try std.testing.expect(demo.insertText("8"));
    try std.testing.expectEqual(@as(u8, '8'), demo.otp[3]);
    try std.testing.expect(demo.accessibilityAction(320, .click));
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expect(demo.accessibilityAction(323, .click));
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
    try std.testing.expectEqualStrings("project.svg", demo.filename.text());
    try std.testing.expect(demo.accessibilityAction(480, .increment));
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), demo.divider, 0.001);
    try std.testing.expect(demo.accessibilityAction(489, .click));
    try demo.relayout(std.testing.allocator, viewport, &font);
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

test "AccessKit message log follows additions until a user scrolls away" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expect(demo.message_scroll.atMessageEnd());
    try std.testing.expect(demo.message_scroll.offset.y > 0);
    const initial = demo.message_scroll.offset.y;
    try std.testing.expect(demo.accessibilityAction(498, .click));
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expect(demo.message_scroll.offset.y > initial);
    try std.testing.expect(demo.message_scroll.atMessageEnd());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    var log_found = false;
    var message_found = false;
    var jump_found = false;
    for (snapshot.nodes) |node| {
        if (node.role == .log) {
            log_found = true;
            try std.testing.expect(node.live == .polite);
        }
        if (node.id == 603) message_found = true;
        if (node.id == 499) {
            jump_found = true;
            try std.testing.expect(node.role == .button and node.actionable);
        }
    }
    try std.testing.expect(log_found and message_found and jump_found);

    demo.scroll.ensureVisible(demo.message_scroll.viewport);
    try demo.relayout(std.testing.allocator, viewport, &font);
    const pane = demo.message_scroll.viewport;
    const outer_position = demo.scroll.offset.y;
    demo.scrollWheel(pane.center().x, pane.center().y, 0, 1);
    try std.testing.expectEqual(outer_position, demo.scroll.offset.y);
    const reading_position = demo.message_scroll.offset.y;
    try std.testing.expect(demo.accessibilityAction(498, .click));
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expectEqual(reading_position, demo.message_scroll.offset.y);
    try std.testing.expect(demo.accessibilityAction(499, .click));
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expect(demo.message_scroll.atMessageEnd());
    try std.testing.expect(demo.message_scroll.offset.y > reading_position);
}

test "end scrolling exposes the complete footer and bottom padding" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    for ([_]u32{ 520, 521, 522 }) |selection| {
        demo.sidebar_selection = selection;
        for ([_]ui.Rect{
            .{ .x = 0, .y = 0, .w = 900, .h = 675 },
            .{ .x = 0, .y = 0, .w = 360, .h = 280 },
            .{ .x = 0, .y = 0, .w = 200, .h = 200 },
        }) |viewport| {
            demo.scroll.offset.y = 1_000_000;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var count_buf: [20]u8 = undefined;
            const root = try layoutTree(.{ .allocator = arena.allocator() }, &demo, viewport, &count_buf, &font);
            const page = root.find(page_id).?;
            const footer = page.children[page.children.len - 1];
            try std.testing.expect(footer.bounds.y + footer.bounds.h + 32 <= demo.scroll.viewport.y + demo.scroll.viewport.h + 1);
            try std.testing.expect(footer.bounds.y + footer.bounds.h > demo.scroll.viewport.y);
        }
    }
}

test "wheel bursts paint within a bounded frame budget" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    var vertices: [30000]ui.Vertex = undefined;
    var canvas = ui.Canvas.init(&vertices, &font);
    const start = @import("vitellus_sdl3").sdl.timer.getNanosecondsSinceInit();
    for (0..30) |_| {
        for (0..8) |_| demo.scrollWheel(100, 100, 0, -1);
        canvas.len = 0;
        _ = try demo.draw(std.testing.allocator, &canvas, viewport);
        try std.testing.expect(canvas.len > 0);
    }
    try std.testing.expect(@import("vitellus_sdl3").sdl.timer.getNanosecondsSinceInit() - start < 2_000_000_000);
}

test "AccessKit gallery menus, context actions, toast and modal trap" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(snapshotNode(snapshot, 420) == null);
    try std.testing.expect(demo.accessibilityAction(419, .click));
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expectEqual(L.Accessibility.Role.menu, snapshotNode(snapshot, 423).?.role);
    const option = snapshotNode(snapshot, 421).?;
    try std.testing.expect(option.bounds.w > 0 and option.bounds.h > 0);
    try std.testing.expect(demo.menuTypeAhead("R"));
    try std.testing.expectEqual(@as(u32, 421), demo.focusId());
    demo.pointerDown(option.bounds.center().x, option.bounds.center().y);
    try std.testing.expect(!demo.menu_open);
    try std.testing.expectEqualStrings("Rename the project in the Project field.", demo.status);
    try std.testing.expect(demo.editable[0].text.selection() != null);

    try std.testing.expect(demo.accessibilityAction(426, .focus));
    try demo.relayout(std.testing.allocator, viewport, &font);
    const trigger = demo.controls[demo.indexOf(426).?];
    demo.pointerContextDown(trigger.center().x, trigger.center().y);
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expectEqual(L.Accessibility.Role.menu, snapshotNode(snapshot, 427).?.role);
    try std.testing.expect(demo.accessibilityAction(420, .click));
    try std.testing.expect(demo.context_point == null);
    try std.testing.expect(demo.selected_item);

    try std.testing.expect(demo.accessibilityAction(443, .click));
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(snapshotNode(snapshot, 444).?.actionable);
    var found_status = false;
    for (snapshot.nodes) |node| if (node.role == .status and std.mem.eql(u8, node.label, "Saved")) {
        found_status = true;
    };
    try std.testing.expect(found_status);

    try std.testing.expect(demo.accessibilityAction(489, .click));
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(snapshotNode(snapshot, 444) == null);
    try std.testing.expect(snapshotNode(snapshot, button_id) == null);
    try std.testing.expectEqual(@as(usize, 2), demo.control_count);
    try std.testing.expectEqual(@as(u32, 490), demo.focusId());
    demo.next(true);
    try std.testing.expectEqual(@as(u32, 492), demo.focusId());
    demo.pointerDown(0, 0);
    try std.testing.expect(demo.dialog_open);
    try std.testing.expect(demo.dismiss());
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expectEqual(@as(u32, 489), demo.focusId());
    try std.testing.expect(snapshotNode(snapshot, button_id) != null);
    try std.testing.expect(snapshotNode(snapshot, 444) != null);
    try std.testing.expect(demo.accessibilityAction(444, .click));
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(snapshotNode(snapshot, 444) == null);
}

test "AccessKit text updates preserve Unicode selection and editing contracts" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(demo.accessibilityAction(300, .focus));
    try std.testing.expect(demo.editKey(.left, false, false, &font));
    try std.testing.expect(demo.insertText("π"));
    try std.testing.expectEqualStrings("Eggπy", demo.editable[0].text.text());
    try std.testing.expect(demo.accessibilitySetSelection(300, 3, 4));
    try std.testing.expectEqualStrings("π", demo.selectedText().?);
    const snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    const field = snapshotNode(snapshot, 300).?;
    try std.testing.expectEqual(@as(usize, 3), field.text_selection.?.anchor);
    try std.testing.expectEqual(@as(usize, 5), field.text_selection.?.focus);
    demo.cutSelection();
    try std.testing.expectEqualStrings("Eggy", demo.editable[0].text.text());
    try std.testing.expect(demo.editKey(.undo, false, false, &font));
    try std.testing.expectEqualStrings("Eggπy", demo.editable[0].text.text());
    try std.testing.expect(demo.editKey(.redo, false, false, &font));
    try std.testing.expectEqualStrings("Eggy", demo.editable[0].text.text());
    demo.setComposition("日本", 1);
    try std.testing.expectEqual(@as(usize, 6), demo.composition_len);
    try std.testing.expectEqual(@as(?usize, 3), demo.composition_cursor);
    try std.testing.expect(!demo.accessibilitySetSelection(300, 20, 21));
    try std.testing.expect(!demo.accessibilitySetValue(300, "one\ntwo"));
    try std.testing.expect(demo.accessibilitySetValue(300, "Ready"));
    try std.testing.expectEqualStrings("Ready", demo.editable[0].text.text());
}

test "multi-click text selection is reflected in AccessKit" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    demo.scroll.ensureVisible(demo.controls[demo.indexOf(300).?]);
    try demo.relayout(std.testing.allocator, viewport, &font);
    const project = demo.controls[demo.indexOf(300).?];
    demo.pointerDownWithClicks(project.x + 24, project.center().y, &font, 2);
    try std.testing.expectEqualStrings("Eggy", demo.selectedText().?);
    try std.testing.expect(!demo.dragging_text);

    try std.testing.expect(demo.accessibilitySetValue(301, "first\nsecond"));
    try demo.relayout(std.testing.allocator, viewport, &font);
    demo.scroll.ensureVisible(demo.controls[demo.indexOf(301).?]);
    try demo.relayout(std.testing.allocator, viewport, &font);
    const area = ui.text_edit.inputContentRect(demo.controls[demo.indexOf(301).?]);
    demo.pointerDownWithClicks(area.x + 16, area.y + 12, &font, 3);
    try std.testing.expectEqualStrings("first\n", demo.selectedText().?);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    const selection = snapshotNode(snapshot, 301).?.text_selection.?;
    try std.testing.expectEqual(@as(usize, 0), selection.anchor);
    try std.testing.expectEqual(@as(usize, 6), selection.focus);
}

test "gallery filters commands, navigates dates, shows tooltip and swaps sidebar views" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(demo.accessibilityAction(430, .focus));
    try std.testing.expect(demo.editKey(.select_all, false, false, &font));
    try std.testing.expect(demo.insertText("not-found"));
    var snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(snapshotNode(snapshot, 431) == null);
    try std.testing.expect(snapshotNode(snapshot, 432) == null);
    try std.testing.expect(demo.editKey(.select_all, false, false, &font));
    try std.testing.expect(demo.insertText("set"));
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(snapshotNode(snapshot, 431) == null);
    try std.testing.expectEqual(L.Accessibility.Role.menu_item, snapshotNode(snapshot, 432).?.role);
    try std.testing.expect(demo.menuMove(1));
    try std.testing.expectEqual(@as(u32, 432), demo.focusId());
    demo.activate();
    try std.testing.expect(!demo.combo_open);
    _ = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);

    try std.testing.expect(demo.accessibilityAction(1033, .click));
    try std.testing.expectEqual(@as(u8, 3), demo.date.month);
    try std.testing.expect(demo.accessibilityAction(1035, .click));
    try std.testing.expect(demo.accessibilityAction(1037, .click));
    try std.testing.expectEqual(@as(u8, 1), demo.date.hour);
    try std.testing.expectEqual(@as(u8, 15), demo.date.minute);
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(std.mem.indexOf(u8, snapshotNode(snapshot, 400).?.value, "01:15") != null);

    try std.testing.expect(demo.accessibilityAction(439, .focus));
    try demo.relayout(std.testing.allocator, viewport, &font);
    const tip = demo.controls[demo.indexOf(439).?];
    demo.pointerMove(tip.center().x, tip.center().y);
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    var found_tooltip = false;
    for (snapshot.nodes) |node| if (node.role == .tooltip) {
        found_tooltip = true;
    };
    try std.testing.expect(found_tooltip);
    try std.testing.expect(demo.accessibilityAction(521, .click));
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    var found_dashboard = false;
    for (snapshot.nodes) |node| if (node.role == .heading and std.mem.indexOf(u8, node.label, "Dashboard:") != null) {
        found_dashboard = true;
    };
    try std.testing.expect(found_dashboard);
    try std.testing.expect(demo.accessibilityAction(452, .click));
    try std.testing.expect(demo.table_lines);
}

test "AccessKit sidebar views expose working project actions and shared settings" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(snapshotNode(snapshot, 530).?.actionable);
    try std.testing.expect(snapshotNode(snapshot, 533) == null);
    try std.testing.expect(demo.accessibilityAction(530, .click));
    try std.testing.expectEqual(@as(u32, 1), demo.files_created);
    try std.testing.expect(demo.accessibilityAction(531, .click));
    try std.testing.expectEqual(@as(u32, 1), demo.folders_created);
    try std.testing.expect(demo.accessibilityAction(536, .click));
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expectEqual(@as(u32, 300), demo.focusId());

    try std.testing.expect(demo.accessibilityAction(521, .click));
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(snapshotNode(snapshot, 530) == null);
    try std.testing.expect(!demo.accessibilityAction(530, .click));
    var dashboard_found = false;
    var totals_found = false;
    for (snapshot.nodes) |node| {
        if (node.role == .region and std.mem.eql(u8, node.label, "Dashboard view")) dashboard_found = true;
        if (node.role == .label and std.mem.indexOf(u8, node.label, "1 files, 1 folders created") != null) totals_found = true;
    }
    try std.testing.expect(dashboard_found and totals_found);

    try std.testing.expect(demo.accessibilityAction(522, .click));
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    var settings_found = false;
    for (snapshot.nodes) |node| if (node.role == .region and std.mem.eql(u8, node.label, "Settings view")) {
        settings_found = true;
    };
    try std.testing.expect(settings_found);
    try std.testing.expectEqual(true, snapshotNode(snapshot, 533).?.toggled.?);
    try std.testing.expect(demo.accessibilityAction(533, .click));
    try std.testing.expect(demo.accessibilityAction(534, .click));
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(!snapshotNode(snapshot, 533).?.toggled.?);
    try std.testing.expect(snapshotNode(snapshot, 534).?.toggled.?);
    try std.testing.expect(demo.accessibilityAction(535, .click));
    try std.testing.expectEqualStrings("Settings applied.", demo.status);
}

test "portable questionnaire keyboard rules preserve radio and tab selection and IME confirmation" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(demo.accessibilityAction(330, .focus));
    try std.testing.expect(demo.moveComposite(1));
    try std.testing.expectEqual(@as(u32, 331), demo.selected_radio);
    var snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(!snapshotNode(snapshot, 330).?.toggled.?);
    try std.testing.expect(snapshotNode(snapshot, 331).?.toggled.?);
    try std.testing.expect(demo.accessibilityAction(overview_tab_id, .focus));
    try std.testing.expect(demo.moveComposite(1));
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(snapshotNode(snapshot, details_tab_id).?.selected.?);
    try std.testing.expect(!snapshotNode(snapshot, overview_tab_id).?.selected.?);
    try std.testing.expect(demo.accessibilityAction(440, .focus));
    demo.command_open = true;
    _ = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    demo.setComposition("入力", 1);
    try std.testing.expect(!demo.confirmMenu());
    try std.testing.expectEqualStrings("new", demo.editable[4].text.text());
    demo.setComposition("", null);
    try std.testing.expect(demo.confirmMenu());
    try std.testing.expect(!demo.command_open);
    try std.testing.expectEqual(@as(u32, 1), demo.files_created);
}

fn snapshotNode(snapshot: ui.accessibility.Snapshot, id: u64) ?ui.accessibility.Node {
    for (snapshot.nodes) |node| if (node.id == id) return node;
    return null;
}
