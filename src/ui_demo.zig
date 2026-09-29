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
const appearance_id = 560;
const debug_id = 565;
const date_input_id = 402;
const date_button_id = 403;
const gallery_id = 700;
const layout_first_id = 710;
const question_first_id = 720;
const menubar_first_id = 800;
const nav_first_id = 850;
const menubar_popup_id = 890;
const submenu_popup_id = 891;
const nav_popup_id = 892;
/// Color editor ids: +0..+9 wheel, bars and sliders (`ui.ColorChannel`), +10/+11 hex linear/sRGB,
/// +12 OK, +13 Cancel, +14 the Old swatch, +15.. swatches.
const color_first_id = 750;
const wheel_id = color_first_id;
const hex_linear_id = color_first_id + 10;
const hex_srgb_id = color_first_id + 11;
const first_swatch_id = color_first_id + 15;
const accent_id = 777;
const swatches = [_]ui.Color{
    ui.rgb(0xF2, 0xB2, 0x33), ui.rgb(0xE8, 0x6A, 0x3A), ui.rgb(0xD9, 0x3F, 0x5B), ui.rgb(0xB0, 0x4B, 0xD6), ui.rgb(0x5B, 0x6C, 0xF0), ui.rgb(0x2F, 0x9C, 0xE0),
    ui.rgb(0x23, 0xB5, 0xA3), ui.rgb(0x4C, 0xB8, 0x5A), ui.rgb(0x9B, 0xC4, 0x3A), ui.rgb(0x8A, 0x6E, 0x55), ui.rgb(0x6B, 0x63, 0x58), ui.rgb(0x1C, 0x19, 0x15),
};
const W = ui.widgets;
const native_options = [_][]const u8{ "Low", "Medium", "High", "Ultra" };
const share_items = [_]W.MenuItem{
    .{ .id = menubar_first_id + 14, .label = "Email link" },
    .{ .id = menubar_first_id + 15, .label = "Messages" },
    .{ .id = menubar_first_id + 16, .label = "Notes" },
};
/// Structure of the menubar; checked states are filled in per frame.
const menubar_menus = [_]W.MenubarMenu{
    .{ .id = menubar_first_id + 1, .label = "File", .items = &.{
        .{ .id = menubar_first_id + 10, .label = "New Tab", .shortcut = "Ctrl+T" },
        .{ .id = menubar_first_id + 11, .label = "New Window", .shortcut = "Ctrl+N" },
        .{ .id = menubar_first_id + 12, .label = "New Incognito Window", .disabled = true },
        .{ .kind = .separator },
        .{ .id = menubar_first_id + 13, .label = "Share", .kind = .submenu, .items = &share_items },
        .{ .kind = .separator },
        .{ .id = menubar_first_id + 17, .label = "Print...", .shortcut = "Ctrl+P" },
    } },
    .{ .id = menubar_first_id + 2, .label = "Edit", .items = &.{
        .{ .id = menubar_first_id + 20, .label = "Undo", .shortcut = "Ctrl+Z" },
        .{ .id = menubar_first_id + 21, .label = "Redo", .shortcut = "Shift+Ctrl+Z" },
        .{ .kind = .separator },
        .{ .id = menubar_first_id + 22, .label = "Cut" },
        .{ .id = menubar_first_id + 23, .label = "Copy" },
        .{ .id = menubar_first_id + 24, .label = "Paste" },
    } },
    .{ .id = menubar_first_id + 3, .label = "View", .items = &.{
        .{ .id = menubar_first_id + 30, .label = "Always Show Bookmarks Bar", .kind = .checkbox },
        .{ .id = menubar_first_id + 31, .label = "Always Show Full URLs", .kind = .checkbox },
        .{ .kind = .separator },
        .{ .id = menubar_first_id + 32, .label = "Reload", .shortcut = "Ctrl+R" },
        .{ .id = menubar_first_id + 33, .label = "Force Reload", .shortcut = "Shift+Ctrl+R", .disabled = true },
        .{ .kind = .separator },
        .{ .id = menubar_first_id + 34, .label = "Toggle Fullscreen" },
        .{ .kind = .separator },
        .{ .id = menubar_first_id + 35, .label = "Hide Sidebar" },
    } },
    .{ .id = menubar_first_id + 4, .label = "Profiles", .items = &.{
        .{ .id = menubar_first_id + 40, .label = "Andy", .kind = .radio },
        .{ .id = menubar_first_id + 41, .label = "Benoit", .kind = .radio },
        .{ .id = menubar_first_id + 42, .label = "Luis", .kind = .radio },
        .{ .kind = .separator },
        .{ .id = menubar_first_id + 43, .label = "Edit..." },
        .{ .kind = .separator },
        .{ .id = menubar_first_id + 44, .label = "Add Profile..." },
    } },
};
fn menubarStatus(id: u32) []const u8 {
    for (menubar_menus) |entry| for (entry.items) |row| {
        if (row.id == id) return row.label;
        for (row.items) |sub| if (sub.id == id) return sub.label;
    };
    return "Menu command";
}
const ui_questions = [_]W.Question{
    .{ .title = "What should the agent build next?", .description = "Pick the one that matters most this week.", .choices = &.{ "A settings page", "A search experience", "An onboarding flow" } },
    .{ .title = "What should every progress update include?", .description = "Choose all that apply.", .choices = &.{ "What changed", "What's next", "Open questions" }, .multiple = true },
    .{ .title = "Anything else the agent should know?", .choices = &.{ "Keep it small", "Match the existing style", "Ask before large changes" }, .optional = true, .freeform = true },
};

/// Controls that repeat while the pointer (or Enter) is held: calendar steps, pagination, carousel.
fn repeatable(id: u32) bool {
    return switch (id) {
        1032...1039, 390, 393, 410, 411 => true,
        else => false,
    };
}
pub const Appearance = enum { system, light, dark };
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
    /// Hit targets from the last layout, on the heap so the DevTools tree (two per page element)
    /// can't bloat `Demo`, which is copied by value into the app state.
    control_ids: []u32 = &.{},
    control_clips: []ui.Rect = &.{},
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
    calendar_open: bool = false,
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
    editable: [9]Editable = .{
        .{ .id = 300, .text = textBuffer("Eggy") },
        .{ .id = 301, .text = textBuffer("Describe the project") },
        .{ .id = 302, .text = textBuffer("42") },
        .{ .id = 430, .text = textBuffer("sea") },
        .{ .id = 440, .text = textBuffer("new") },
        .{ .id = date_input_id, .text = textBuffer("2024-02-29  00:00") },
        .{ .id = question_first_id + 16, .text = textBuffer("") },
        .{ .id = hex_linear_id, .text = textBuffer("DB7E0BFF") },
        .{ .id = hex_srgb_id, .text = textBuffer("F2B233FF") },
    },
    editing_scroll_x: [9]f32 = @splat(0),
    editing_scroll_y: [9]f32 = @splat(0),
    composition: [128]u8 = undefined,
    composition_len: usize = 0,
    composition_cursor: ?usize = null,
    dragging_text: bool = false,
    otp: [4]u8 = .{ '1', '2', '3', 0 },
    ui_scale: f32 = 1,
    appearance: Appearance = .system,
    /// Outline every hit target in red.
    debug_hitboxes: bool = false,
    /// Focus ring only after keyboard navigation, like CSS :focus-visible.
    keyboard_focus: bool = false,
    /// Pointer-held control that auto-repeats, and how long it has been held.
    held_id: u32 = 0,
    held_time: f32 = 0,
    gallery_top: f32 = 0,
    bold: bool = false,
    native_index: usize = 0,
    dialog_kind: ui.widgets.Modal = .alert_dialog,
    dialog_opener: u32 = 489,
    attachment_visible: bool = true,
    menubar_open: u32 = 0,
    menubar_highlight: u32 = 0,
    menubar_submenu: u32 = 0,
    bookmarks_bar: bool = false,
    full_urls: bool = true,
    profile: u32 = menubar_first_id + 41,
    nav_open: u32 = 0,
    layout_justify: u32 = layout_first_id,
    layout_wrap: bool = true,
    grid_columns: u16 = 3,
    rtl: bool = false,
    question: usize = 0,
    answers: [3]u16 = .{ 0, 0, 0 },
    questionnaire_done: bool = false,
    wide_scroll: L.ScrollState = .{},
    color: ui.ColorEditor = ui.ColorEditor.init(ui.rgb(0xF2, 0xB2, 0x33), 1),
    /// Paint the theme's primary and focus colors with the picked color.
    custom_accent: bool = false,
    /// Chrome-style inspector (F12).
    devtools: ui.devtools.Devtools = .{},
    /// Where each DevTools view is on screen this frame (zero when not shown).
    tool_rects: [3]ui.Rect = @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0 }),
    /// DevTools panel slots to fill this frame, and the page they inspect.
    tool_slots: [3]struct { tool: ui.devtools.Tool, element: *L.Element } = undefined,
    tool_slot_count: usize = 0,
    inspected: ?*L.Element = null,
    logged_status: []const u8 = "",
    /// Editor layout: the app root is a dockspace (the tests use the plain page).
    docked: bool = false,
    dock: ui.dock.DockSpace = ui.dock.DockSpace.init(),
    dock_ready: bool = false,
    /// Logical size of each popped-out panel's OS window, once the app has opened it.
    window_sizes: [ui.dock.max_windows]?[2]f32 = @splat(null),
    /// Draw our own title bars (the app window is borderless); off in tests.
    custom_frame: bool = false,
    frame_layout: ui.titlebar.Layout = ui.titlebar.Layout.default(@import("builtin").os.tag),
    /// Slot 0 is the main window, slot i + 1 panel window i.
    window_state: [ui.dock.max_windows + 1]ui.titlebar.State = @splat(.{}),
    /// Title bar and button rectangles per slot, in window-local units, for the OS hit test.
    frames: [ui.dock.max_windows + 1]FrameRects = @splat(.{}),
    /// A title bar button the app should carry out (minimize, maximize, close).
    window_request: ?struct { slot: u8, button: ui.titlebar.Button } = null,
    /// Which dock windows were built this frame, in root-child order after the main tree.
    frame_windows: u8 = 0,
    frame_window_index: [ui.dock.max_windows]u8 = undefined,
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
    controls: []ui.Rect = &.{},
    /// Pointer shape over each control (see `cursor`).
    control_cursors: []ui.Cursor = &.{},
    scene_viewport: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    scene_clip: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    overlay_rects: [10]ui.Rect = [_]ui.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 10,

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
        const ranged = id == slider_id or id == 480 or (id >= color_first_id and id <= color_first_id + 9);
        if ((action == .click and ranged) or ((action == .increment or action == .decrement) and !ranged)) return false;
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
                } else if (id >= color_first_id and id <= color_first_id + 9) {
                    self.adjustFocused(if (action == .increment) 1 else -1);
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
        return self.drawWindows(allocator, canvas, viewport, &.{});
    }
    /// A popped-out panel's OS window to draw into; `base` returns where its overlays begin.
    pub const WindowTarget = struct { index: u8, canvas: *ui.Canvas, base: usize = 0 };
    /// Draw the main window into `canvas` and each open panel window into its target.
    pub fn drawWindows(self: *Demo, allocator: std.mem.Allocator, canvas: *ui.Canvas, viewport: ui.Rect, targets: []WindowTarget) !usize {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var count_buf: [20]u8 = undefined;
        const tree = try layoutTree(.{ .allocator = arena.allocator() }, self, viewport, &count_buf, canvas.font);
        try self.saveControls(tree, canvas.font);
        const root = if (self.frame_windows > 0) tree.children[0] else tree;
        for (targets) |*target| {
            target.base = 0;
            for (self.frame_window_index[0..self.frame_windows], 1..) |index, child| if (index == target.index) {
                const window_root = tree.children[child];
                target.canvas.focus_id = if (self.keyboard_focus) self.focusId() else 0;
                target.canvas.hot_id = self.hotId();
                try window_root.drawWithoutOverlays(target.canvas);
                target.base = target.canvas.len;
                try window_root.drawOverlays(target.canvas);
                if (self.debug_hitboxes) try window_root.drawHitboxes(target.canvas);
            };
        }
        canvas.focus_id = if (self.keyboard_focus) self.focusId() else 0;
        canvas.hot_id = self.hotId();
        try root.drawWithoutOverlays(canvas);
        const base_vertices = canvas.len;
        try root.drawOverlays(canvas);
        if (self.debug_hitboxes) try root.drawHitboxes(canvas);
        try self.devtools.highlight(canvas, devtools_gpa);
        self.devtools.vertices = canvas.len;
        // Status messages double as console output.
        ui.devtools.console = &self.devtools;
        if (self.status.ptr != self.logged_status.ptr) {
            self.logged_status = self.status;
            self.devtools.log(.info, "{s}", .{self.status});
        }
        return base_vertices;
    }
    /// Pointer shape for this moment: what an ongoing drag implies, else what is under the
    /// pointer (hand on clickable things, I-beam on text, resize arrows on dividers).
    pub fn pointerCursor(self: *const Demo) ui.Cursor {
        if (self.dock.cursor()) |c| return c;
        if (self.dragging_text) return .text;
        if (self.dragging_divider) return .ew_resize;
        if (self.dragging_slider) return .pointer;
        if (self.color.drag) |channel| return switch (channel) {
            .wheel => .crosshair,
            .saturation, .value => .ns_resize,
            else => .ew_resize,
        };
        if (self.devtools.inspecting and !self.inTools(self.pointer_x, self.pointer_y)) return .crosshair;
        var i = self.control_count;
        while (i > 0) {
            i -= 1;
            if (self.control_clips[i].contains(self.pointer_x, self.pointer_y)) return self.control_cursors[i];
        }
        return .default;
    }
    /// Whether (x, y) is over a DevTools panel (so it isn't the page being inspected).
    pub fn inTools(self: *const Demo, x: f32, y: f32) bool {
        for (self.tool_rects) |rect| if (rect.contains(x, y)) return true;
        return false;
    }
    /// F12: show the Elements and Performance panels beside the page, or take them away.
    pub fn toggleDevtools(self: *Demo) void {
        if (!self.docked) return;
        const elements = @intFromEnum(Panel.elements);
        const performance = @intFromEnum(Panel.performance);
        if (self.dock.nodeOf(elements) != null or self.dock.nodeOf(performance) != null) {
            self.dock.remove(elements);
            self.dock.remove(performance);
            self.devtools.inspecting = false;
            return;
        }
        const near: ?u32 = if (self.dock.nodeOf(@intFromEnum(Panel.components)) != null) @intFromEnum(Panel.components) else null;
        self.dock.add(elements, near, .right) catch return;
        self.dock.add(performance, elements, .center) catch {};
        _ = self.dock.activate(ui.dock.first_id + elements);
    }
    /// Topmost control under the pointer, for hover styling.
    fn hotId(self: *const Demo) u32 {
        var i = self.control_count;
        while (i > 0) {
            i -= 1;
            if (self.control_clips[i].contains(self.pointer_x, self.pointer_y)) return self.control_ids[i];
        }
        return 0;
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
        for ([_]u32{ 325, 423, 427, 433, 436, 438, 445, menubar_popup_id, submenu_popup_id, nav_popup_id }, 0..) |id, i| {
            self.overlay_rects[i] = if (root.find(id)) |overlay| overlay.bounds.intersection(overlay.clip) else .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        }
        self.divider_track = if (root.find(481)) |track| track.bounds else .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        for (&self.tool_rects, 0..) |*rect, i| rect.* = if (root.find(ui.devtools.view_id + @as(u32, @intCast(i)))) |view| view.bounds.intersection(view.clip) else .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        for (&self.frames, 0..) |*frame, slot| {
            frame.* = .{};
            const origin: f32 = if (slot == 0) 0 else windowOrigin(slot - 1);
            const local = struct {
                fn f(r: ui.Rect, dx: f32) ui.Rect {
                    return .{ .x = r.x - dx, .y = r.y, .w = r.w, .h = r.h };
                }
            }.f;
            const bar = root.find(ui.titlebar.id(titlebar_first, @intCast(slot), .bar)) orelse continue;
            frame.bar = local(bar.bounds, origin);
            inline for (.{ .close, .minimize, .maximize }) |part| if (root.find(ui.titlebar.id(titlebar_first, @intCast(slot), part))) |button| {
                frame.buttons[frame.count] = local(button.bounds, origin);
                frame.count += 1;
            };
        }
        if (root.find(gallery_id)) |gallery| self.gallery_top = gallery.bounds.y + self.scroll.offset.y - self.scroll.viewport.y;
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
            else => {},
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
    pub fn deinit(self: *Demo) void {
        devtools_gpa.free(self.control_ids);
        devtools_gpa.free(self.control_clips);
        devtools_gpa.free(self.controls);
        devtools_gpa.free(self.control_cursors);
        self.devtools.deinit(devtools_gpa);
    }
    fn recordControl(self: *Demo, element: *const L.Element) !void {
        if (self.control_count == self.controls.len) {
            const capacity = @max(256, self.controls.len * 2);
            self.control_ids = try devtools_gpa.realloc(self.control_ids, capacity);
            self.control_clips = try devtools_gpa.realloc(self.control_clips, capacity);
            self.controls = try devtools_gpa.realloc(self.controls, capacity);
            self.control_cursors = try devtools_gpa.realloc(self.control_cursors, capacity);
        }
        self.control_cursors[self.control_count] = element.cursorFor();
        const i = self.control_count;
        self.controls[i] = element.bounds;
        self.control_clips[i] = element.bounds.intersection(element.clip);
        self.control_ids[i] = element.id;
        self.control_count += 1;
    }
    fn panes(self: *Demo) [6]*L.ScrollState {
        return .{ &self.preview_scroll, &self.message_scroll, &self.wide_scroll, &self.devtools.tree_scroll, &self.devtools.details_scroll, &self.devtools.console_scroll };
    }
    pub fn tickScroll(self: *Demo, dt: f32) void {
        for (self.panes()) |pane| pane.tick(dt);
        self.devtools.recordFrame(dt * 1000);
        if (self.held_id == 0) return;
        // Hold: first repeat after 0.4 s, then every 0.08 s.
        const before = self.held_time;
        self.held_time += dt;
        const delay: f32 = 0.4;
        const interval: f32 = 0.08;
        if (self.held_time < delay) return;
        const fired_before: i32 = if (before < delay) -1 else @intFromFloat(@floor((before - delay) / interval));
        const fired_now: i32 = @intFromFloat(@floor((self.held_time - delay) / interval));
        // A slow frame may cross several repeat points; fire each (capped so a stall can't run away).
        for (0..@min(8, @as(usize, @intCast(fired_now - fired_before)))) |_| {
            const index = self.indexOf(self.held_id) orelse {
                self.held_id = 0;
                return;
            };
            self.focus = index;
            self.activate();
        }
    }
    pub fn scrollDragging(self: *Demo) bool {
        if (self.dock.dragging()) return true;
        if (self.color.drag != null) return true;
        for (self.panes()) |pane| if (pane.dragging != .none) return true;
        return self.scroll.dragging != .none;
    }
    /// The part of `pane` on screen: DevTools panes live in the panel, the rest in the page.
    fn paneVisible(self: *Demo, pane: *L.ScrollState) ui.Rect {
        // DevTools panes live in their own panels, not inside the page.
        if (pane == &self.devtools.tree_scroll or pane == &self.devtools.details_scroll or pane == &self.devtools.console_scroll) return pane.viewport;
        return pane.viewport.intersection(self.scroll.viewport);
    }
    pub fn scrollWheel(self: *Demo, x: f32, y: f32, dx: f32, dy: f32) void {
        const over_panel = self.inTools(x, y);
        if (self.dialog_open and !over_panel) return;
        for (self.panes()) |pane| {
            if (self.paneVisible(pane).contains(x, y)) {
                const old = pane.offset;
                pane.wheel(dx, dy);
                if (old.x != pane.offset.x or old.y != pane.offset.y) return;
                break;
            }
        }
        // Never scroll the page from over the DevTools panel (or, docked, from another panel).
        if (!over_panel and (!self.docked or self.scroll.viewport.contains(x, y))) self.scroll.wheel(dx, dy);
    }
    /// Whether Enter may auto-repeat on the focused control.
    pub fn focusRepeats(self: *const Demo) bool {
        return repeatable(self.focusId());
    }
    /// Enter in a single-line field that has a meaning: parse the typed date.
    pub fn commitEdit(self: *Demo) bool {
        if (self.devtools.commit(devtools_gpa, self.focusId())) return true;
        switch (self.focusId()) {
            date_input_id => {
                const typed = self.editable[5].text.text();
                self.date = ui.widgets.parseDate(typed) catch {
                    self.status = "Type a date as YYYY-MM-DD HH:MM.";
                    return true;
                };
                self.syncDateText();
                self.status = "Date set.";
                return true;
            },
            question_first_id + 16 => {
                self.activateId(question_first_id + 19);
                return true;
            },
            hex_linear_id, hex_srgb_id => {
                const linear = self.focusId() == hex_linear_id;
                const typed = self.editable[if (linear) 7 else 8].text.text();
                (if (linear) self.color.setHex(typed, .linear) else self.color.setHex(typed, .srgb)) catch {
                    self.status = "Type a color as RRGGBB or RRGGBBAA.";
                    return true;
                };
                self.syncHex();
                self.status = "Color set.";
                return true;
            },
            else => return false,
        }
    }
    fn syncDateText(self: *Demo) void {
        var buffer: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2}  {d:0>2}:{d:0>2}", .{ self.date.year, self.date.month, self.date.day, self.date.hour, self.date.minute }) catch unreachable;
        self.editable[5].text.set(text) catch unreachable;
    }
    fn activateId(self: *Demo, id: u32) void {
        const saved = self.focus;
        self.focus = self.indexOf(id) orelse return;
        self.activate();
        if (self.indexOf(id) == null) self.focus = saved;
    }
    pub fn isEditing(self: *const Demo) bool {
        const id = self.focusId();
        if (self.devtools.isField(id)) return true;
        return self.editableFor(id) != null or (id >= 310 and id <= 313);
    }
    fn editableFor(self: *const Demo, id: u32) ?usize {
        for (self.editable, 0..) |field, i| if (field.id == id) return i;
        return null;
    }
    pub fn insertText(self: *Demo, text: []const u8) bool {
        self.composition_len = 0;
        const id = self.focusId();
        if (self.devtools.insertText(id, text)) return true;
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
            const truncated = self.editable[i].text.insertFitting(text) catch |err| {
                self.status = "Invalid text input.";
                std.log.warn("Text input rejected: {s}", .{@errorName(err)});
                return true;
            };
            if (truncated) self.status = "Text was cut to fit the field (128 bytes).";
            if (id == 430) self.combo_open = true;
            if (id == 440) self.command_open = true;
            return true;
        }
        return false;
    }
    pub fn backspace(self: *Demo) bool {
        const id = self.focusId();
        if (self.devtools.editKey(devtools_gpa, id, .backspace, false, false)) return true;
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
        if (self.devtools.isField(id)) return self.devtools.editKey(devtools_gpa, id, switch (key) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
            .home => .home,
            .end => .end,
            .delete => .delete,
            .backspace => .backspace,
            .select_all => .select_all,
            .undo, .redo => return false,
        }, extend, word);
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
        self.keyboard_focus = true;
        if (self.menubar_open != 0) {
            var rows: [16]u32 = undefined;
            const count = self.menubarRows(&rows);
            if (count == 0) return false;
            const at = std.mem.indexOfScalar(u32, rows[0..count], id) orelse (if (direction > 0) count - 1 else 0);
            const next_row = rows[if (direction > 0) (at + 1) % count else (at + count - 1) % count];
            self.focus = self.indexOf(next_row) orelse return false;
            self.menubar_highlight = next_row;
            return true;
        }
        if (id >= menubar_first_id + 1 and id <= menubar_first_id + 4 and self.menubar_open == 0) {
            _ = self.dismiss();
            self.menubar_open = id;
            var rows: [16]u32 = undefined;
            if (self.menubarRows(&rows) > 0) {
                self.menubar_highlight = rows[0];
                self.restore_focus = rows[0];
            }
            return true;
        }
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
    /// Actionable rows of the open menubar menu (and its open submenu), in order.
    fn menubarRows(self: *const Demo, out: *[16]u32) usize {
        var count: usize = 0;
        for (menubar_menus) |entry| if (entry.id == self.menubar_open) {
            for (entry.items) |row| {
                if (row.kind == .separator or row.kind == .label or row.disabled) continue;
                out[count] = row.id;
                count += 1;
                if (row.kind == .submenu and row.id == self.menubar_submenu) for (row.items) |sub| {
                    out[count] = sub.id;
                    count += 1;
                };
            }
        };
        return count;
    }
    /// Arrow keys on a DevTools tree row (up/down/left/right).
    pub fn treeKey(self: *Demo, key: EditKey) bool {
        const target = self.devtools.treeKey(devtools_gpa, self.focusId(), switch (key) {
            .up => .up,
            .down => .down,
            .left => .left,
            .right => .right,
            else => return false,
        }) orelse return false;
        self.keyboard_focus = true;
        self.restore_focus = target;
        return true;
    }
    pub fn moveComposite(self: *Demo, direction: i8) bool {
        const id = self.focusId();
        self.keyboard_focus = true;
        // Left/right across the menubar keeps a menu open, like desktop menu bars.
        if (self.menubar_open != 0 or (id >= menubar_first_id + 1 and id <= menubar_first_id + 4)) {
            if (direction > 0 and self.menubar_open != 0 and id == menubar_first_id + 13) {
                self.menubar_submenu = id;
                return true;
            }
            const current = if (self.menubar_open != 0) self.menubar_open else id;
            const next_menu = menubar_first_id + 1 + @as(u32, @intCast(@mod(@as(i32, @intCast(current - menubar_first_id - 1)) + direction, 4)));
            const was_open = self.menubar_open != 0;
            self.focus = self.indexOf(next_menu) orelse return false;
            if (was_open) {
                self.menubar_open = next_menu;
                self.menubar_submenu = 0;
                var rows: [16]u32 = undefined;
                if (self.menubarRows(&rows) > 0) self.menubar_highlight = rows[0];
            }
            return true;
        }
        const peers: []const u32 = switch (id) {
            330, 331 => &.{ 330, 331 },
            340, 341 => &.{ 340, 341 },
            appearance_id...appearance_id + 2 => &.{ appearance_id, appearance_id + 1, appearance_id + 2 },
            layout_first_id...layout_first_id + 3 => &.{ layout_first_id, layout_first_id + 1, layout_first_id + 2, layout_first_id + 3 },
            layout_first_id + 5...layout_first_id + 7 => &.{ layout_first_id + 5, layout_first_id + 6, layout_first_id + 7 },
            question_first_id...question_first_id + 2 => &.{ question_first_id, question_first_id + 1, question_first_id + 2 },
            overview_tab_id, details_tab_id => &.{ overview_tab_id, details_tab_id },
            370, 371 => &.{ 370, 371 },
            else => return false,
        };
        const current = std.mem.indexOfScalar(u32, peers, id).?;
        const next_index = if (direction > 0) (current + 1) % peers.len else (current + peers.len - 1) % peers.len;
        const index = self.indexOf(peers[next_index]) orelse return false;
        self.focus = index;
        if (id != 370 and id != 371 and !(id >= question_first_id and id <= question_first_id + 2 and ui_questions[self.question].multiple)) self.activate();
        return true;
    }
    pub fn confirmMenu(self: *Demo) bool {
        if (self.composition_len > 0) return false;
        const id = self.focusId();
        if (self.menubar_open != 0 and id >= menubar_first_id + 1 and id <= menubar_first_id + 4) {
            self.focus = self.indexOf(self.menubar_highlight) orelse return false;
            self.activate();
            return true;
        }
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
        if (!self.inTools(x, y) and self.devtools.pointerDown(x, y)) return;
        if (!self.dialog_open and self.scroll.pointerDown(x, y)) return;
        for (self.panes()) |pane| if ((!self.dialog_open or self.inTools(x, y)) and self.paneVisible(pane).contains(x, y) and pane.pointerDown(x, y)) return;
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
            if (self.dock.press(self.control_ids[i], x, y)) {
                self.focus = i;
                self.keyboard_focus = false;
                return;
            }
            self.restore_focus = null;
            if (self.control_ids[i] != self.focusId()) self.devtools.blur(devtools_gpa);
            self.focus = i;
            self.keyboard_focus = false;
            if (repeatable(self.focusId())) {
                self.held_id = self.focusId();
                self.held_time = 0;
            }
            if (!self.dialog_open and !popupRelated(self.focusId())) _ = self.dismiss();
            self.composition_len = 0;
            switch (self.focusId()) {
                slider_id => {
                    self.dragging_slider = true;
                    self.drag_scale = self.ui_scale;
                    self.drag_rect = self.controls[i];
                    self.setScaleFromPointer(x);
                },
                color_first_id...color_first_id + 9 => {
                    self.color.press(@enumFromInt(self.focusId() - color_first_id), self.controls[i], x, y);
                    self.syncHex();
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
        if (self.dock.dragging()) self.dock.dragTo(x, y);
        self.scroll.pointerMove(x, y);
        for (self.panes()) |pane| pane.pointerMove(x, y);
        if (self.inTools(x, y)) self.devtools.pointer = null else self.devtools.pointerMove(x, y);
        if (self.dragging_slider) self.setScaleFromPointer(x);
        if (self.dragging_divider) self.setDividerFromPointer(x);
        if (self.color.drag != null) {
            self.color.dragTo(x, y);
            self.syncHex();
        }
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
        if (self.dock.dragging()) self.dock.release(self.pointer_x, self.pointer_y);
        self.held_id = 0;
        self.color.release();
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
    fn syncHex(self: *Demo) void {
        var buffer: [8]u8 = undefined;
        self.editable[7].text.set(self.color.hex(&buffer, .linear)) catch unreachable;
        self.editable[8].text.set(self.color.hex(&buffer, .srgb)) catch unreachable;
    }
    fn focusedChannel(self: *const Demo) ?ui.ColorChannel {
        const id = self.focusId();
        return if (id >= color_first_id and id <= color_first_id + 9) @enumFromInt(id - color_first_id) else null;
    }
    /// Up/Down: saturation on the wheel, the bar's own value on the vertical bars.
    pub fn adjustVertical(self: *Demo, direction: f32, fine: bool) bool {
        const channel = self.focusedChannel() orelse return false;
        if (channel != .wheel and channel != .saturation and channel != .value) return false;
        self.keyboard_focus = true;
        self.color.nudge(channel, direction * @as(f32, if (fine) 1 else 5), channel == .wheel);
        self.syncHex();
        return true;
    }
    pub fn adjustFocused(self: *Demo, direction: f32) void {
        if (self.focusedChannel()) |channel| {
            self.color.nudge(channel, direction * 5, false);
            self.syncHex();
        } else if (self.focusId() == 480) {
            self.divider = std.math.clamp(@round((self.divider + direction * 0.05) * 20) / 20, 0.1, 0.9);
        } else self.nudgeScale(direction);
    }
    pub fn next(self: *Demo, reverse: bool) void {
        if (self.control_count == 0) return;
        self.devtools.blur(devtools_gpa);
        self.keyboard_focus = true;
        self.composition_len = 0;
        // One Tab stop for the DevTools tree: skip every row but the selected one.
        for (0..self.control_count) |_| {
            self.focus = if (reverse) (self.focus + self.control_count - 1) % self.control_count else (self.focus + 1) % self.control_count;
            if (!self.devtools.skipInTabOrder(self.focusId())) break;
        }
        if (!self.dialog_open) self.scroll.ensureVisible(self.controls[self.indexOf(self.popupAnchor(self.focusId())) orelse self.focus]);
    }
    pub fn dismiss(self: *Demo) bool {
        if (self.devtools.cancel()) return true;
        if (self.devtools.inspecting) {
            self.devtools.inspecting = false;
            return true;
        }
        if (self.dialog_open) {
            self.closeDialog();
            return true;
        }
        if (self.dock.dismissMenu()) return true;
        const had_popup = self.select_open or self.menu_open or self.context_point != null or self.combo_open or self.command_open or self.popover_open or self.menubar_open != 0 or self.nav_open != 0 or self.calendar_open;
        if (self.menubar_open != 0) self.restore_focus = self.menubar_open;
        if (self.nav_open != 0) self.restore_focus = self.nav_open;
        self.menubar_open = 0;
        self.menubar_submenu = 0;
        self.nav_open = 0;
        self.calendar_open = false;
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
        self.restore_focus = self.dialog_opener;
    }
    fn popupAnchor(self: *const Demo, id: u32) u32 {
        return switch (id) {
            322...324 => 320,
            420, 421 => if (self.context_point != null) 426 else 419,
            431, 432 => 430,
            441, 442 => 440,
            1001...1039 => date_button_id,
            menubar_first_id + 10...menubar_first_id + 49 => self.menubar_open,
            nav_first_id + 10...nav_first_id + 19 => self.nav_open,
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
            appearance_id...appearance_id + 2 => self.appearance = @enumFromInt(id - appearance_id),
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
            380 => {
                self.scroll.offset.y = 0;
                self.status = "Back at the top (Home).";
            },
            381 => {
                self.scroll.offset.y = self.gallery_top;
                self.scroll.clamp();
                self.status = "Jumped to the component gallery.";
            },
            debug_id => self.debug_hitboxes = !self.debug_hitboxes,
            color_first_id...color_first_id + 11 => {},
            color_first_id + 12 => {
                self.color.commit();
                self.status = "Color applied.";
            },
            color_first_id + 13, color_first_id + 14 => {
                self.color.revert();
                self.syncHex();
                self.status = "Color restored.";
            },
            first_swatch_id...first_swatch_id + swatches.len - 1 => {
                self.color.hsv = ui.Hsv.fromRgb(swatches[id - first_swatch_id], self.color.hsv.h);
                self.syncHex();
            },
            accent_id => self.custom_accent = !self.custom_accent,
            342 => self.bold = !self.bold,
            345 => self.native_index = (self.native_index + 1) % native_options.len,
            471 => self.attachment_visible = false,
            485, 486, 487 => {
                _ = self.dismiss();
                self.dialog_kind = switch (id) {
                    485 => .drawer,
                    486 => .dialog,
                    else => .sheet,
                };
                self.dialog_opener = id;
                self.dialog_open = true;
            },
            493 => {
                self.closeDialog();
                self.status = "Panel closed.";
            },
            layout_first_id...layout_first_id + 3 => self.layout_justify = id,
            layout_first_id + 4 => self.layout_wrap = !self.layout_wrap,
            layout_first_id + 5...layout_first_id + 7 => self.grid_columns = @intCast(id - layout_first_id - 3),
            layout_first_id + 8 => self.rtl = !self.rtl,
            question_first_id...question_first_id + 2 => {
                const bit = @as(u16, 1) << @intCast(id - question_first_id);
                const answer = &self.answers[self.question];
                answer.* = if (ui_questions[self.question].multiple) answer.* ^ bit else bit;
            },
            question_first_id + 16 => {},
            question_first_id + 17 => self.question -|= 1,
            question_first_id + 18, question_first_id + 19 => {
                const skip = id == question_first_id + 18;
                if (!skip and self.answers[self.question] == 0 and !ui_questions[self.question].optional) {
                    self.status = "Choose an answer to continue.";
                    return;
                }
                if (self.question + 1 < ui_questions.len) {
                    self.question += 1;
                    self.restore_focus = question_first_id;
                } else {
                    self.questionnaire_done = true;
                    self.status = "Plan saved.";
                }
            },
            question_first_id + 3 => {
                self.questionnaire_done = false;
                self.question = 0;
                self.answers = .{ 0, 0, 0 };
            },
            menubar_first_id + 1...menubar_first_id + 4 => {
                const open = self.menubar_open != id;
                _ = self.dismiss();
                self.restore_focus = id;
                if (open) {
                    self.menubar_open = id;
                    var rows: [16]u32 = undefined;
                    if (self.menubarRows(&rows) > 0) self.menubar_highlight = rows[0];
                }
            },
            menubar_first_id + 10...menubar_first_id + 49 => {
                self.menubar_highlight = id;
                if (id == menubar_first_id + 13) {
                    self.menubar_submenu = if (self.menubar_submenu == id) 0 else id;
                    return;
                }
                switch (id) {
                    menubar_first_id + 30 => self.bookmarks_bar = !self.bookmarks_bar,
                    menubar_first_id + 31 => self.full_urls = !self.full_urls,
                    menubar_first_id + 40...menubar_first_id + 42 => self.profile = id,
                    else => {},
                }
                self.status = menubarStatus(id);
                const menu_id = self.menubar_open;
                _ = self.dismiss();
                self.restore_focus = menu_id;
            },
            nav_first_id...nav_first_id + 2 => {
                const open = self.nav_open != id and id != nav_first_id + 2;
                _ = self.dismiss();
                self.restore_focus = id;
                if (open) self.nav_open = id;
                if (id == nav_first_id + 2) self.status = "Docs link followed.";
            },
            nav_first_id + 10...nav_first_id + 19 => {
                self.status = "Navigation link followed.";
                const trigger = self.nav_open;
                _ = self.dismiss();
                self.restore_focus = trigger;
            },
            390 => {
                self.page = @max(1, self.page -| 1);
                self.focus = self.indexOf(390 + self.page) orelse self.focus;
            },
            391, 392 => self.page = @intCast(id - 390),
            393 => {
                self.page = @min(2, self.page + 1);
                self.focus = self.indexOf(390 + self.page) orelse self.focus;
            },
            date_input_id => {},
            date_button_id => {
                const open = !self.calendar_open;
                _ = self.dismiss();
                self.calendar_open = open;
            },
            1001...1031 => {
                self.date.day = @intCast(id - 1000);
                self.calendar_open = false;
                self.restore_focus = date_button_id;
                self.syncDateText();
            },
            1032, 1033, 1038, 1039 => {
                const shifted = if (id == 1032 or id == 1033)
                    ui.widgets.shiftMonth(self.date, if (id == 1032) .previous else .next)
                else
                    ui.widgets.shiftYear(self.date, if (id == 1038) .previous else .next);
                self.date = shifted catch |err| {
                    self.status = "Cannot navigate beyond supported calendar years.";
                    std.log.warn("Calendar navigation rejected: {s}", .{@errorName(err)});
                    return;
                };
                self.syncDateText();
            },
            1034...1037 => {
                switch (id) {
                    1034 => self.date.hour = (self.date.hour + 23) % 24,
                    1035 => self.date.hour = (self.date.hour + 1) % 24,
                    1036 => self.date.minute = (self.date.minute + 45) % 60,
                    else => self.date.minute = (self.date.minute + 15) % 60,
                }
                self.syncDateText();
            },
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
                self.attachment_visible = true;
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
                self.dialog_kind = .alert_dialog;
                self.dialog_opener = 489;
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
            titlebar_first...titlebar_first + (ui.dock.max_windows + 1) * 4 - 1 => {
                const part = (id - titlebar_first) % 4;
                if (part < 3) self.window_request = .{ .slot = @intCast((id - titlebar_first) / 4), .button = @enumFromInt(part) };
            },
            else => if (!self.dock.activate(id) and !self.devtools.activate(devtools_gpa, id)) std.log.warn("Unimplemented demo control: {d}", .{id}),
        }
    }
};

fn popupRelated(id: u32) bool {
    return switch (id) {
        320, 322...324, 419...421, 426, 430...432, 435, 437, 439...442, date_button_id, 1001...1039, menubar_first_id + 1...menubar_first_id + 49, nav_first_id...nav_first_id + 19 => true,
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
/// Persistent memory for DevTools' expanded-row set.
const devtools_gpa = std.heap.smp_allocator;

/// Title bar controls: `ui.titlebar.id(titlebar_first, slot, part)`.
pub const titlebar_first: u32 = 0xC0FF_0000;
pub const FrameRects = struct {
    bar: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    buttons: [3]ui.Rect = @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0 }),
    count: u8 = 0,
};

/// Dock panels in the editor layout.
pub const Panel = enum(u32) { components = 1, scene, console, notes, elements, performance };
/// Each OS window's tree is laid out in its own slice of one coordinate space, so a single
/// control list (hover, focus, clicks) spans every window; window `i` starts at this x.
pub const window_stride: f32 = 20000;
pub fn windowOrigin(index: usize) f32 {
    return window_stride * @as(f32, @floatFromInt(index + 1));
}
const notes_markdown =
    \\## Docking
    \\- Drag a tab onto the compass to dock it left, right, above, below, or into a stack.
    \\- Drop a tab anywhere else to float it; drag the floating tab bar to move it and the corner to resize.
    \\- Drag a tab past the window's edge, or press Pop out, to give it its own OS window.
    \\- Press Dock, or close that window, to bring the panel back.
    \\- Drag the thin bars between panels to resize them.
    \\- F12 (or Ctrl+Shift+I) adds the Elements and Performance panels; Console is always here.
;

/// Title of dock panel `panel`, for OS window titles.
pub fn panelTitle(panel: u32) []const u8 {
    return DockPanels.title(undefined, panel);
}
const DockPanels = struct {
    demo: *Demo,
    count_buf: *[20]u8,
    font: *const ui.Font,

    pub fn title(_: DockPanels, panel: u32) []const u8 {
        return switch (@as(Panel, @enumFromInt(panel))) {
            .components => "Components",
            .scene => "Scene",
            .console => "Console",
            .notes => "Notes",
            .elements => "Elements",
            .performance => "Performance",
        };
    }
    pub fn content(self: DockPanels, b: L.Builder, panel: u32, rect: ui.Rect) !*L.Element {
        switch (@as(Panel, @enumFromInt(panel))) {
            .components => return layoutPage(b, self.demo, rect, self.count_buf, self.font),
            .scene => {
                const scene = try b.node(500, .{ .width = rect.w, .height = rect.h }, .none, &.{});
                scene.accessibility = .{ .role = .image, .label = "Rotating 3D viewport" };
                return scene;
            },
            // DevTools inspects the finished tree, so its panels start as empty slots filled in
            // once every window is laid out (see `fillTools`).
            .console, .elements, .performance => {
                const slot = try b.node(0, .{ .width = rect.w, .height = rect.h }, .none, &.{});
                const demo = self.demo;
                if (demo.tool_slot_count < demo.tool_slots.len) {
                    demo.tool_slots[demo.tool_slot_count] = .{ .tool = switch (@as(Panel, @enumFromInt(panel))) {
                        .elements => .elements,
                        .performance => .performance,
                        else => .console,
                    }, .element = slot };
                    demo.tool_slot_count += 1;
                }
                return slot;
            },
            .notes => return b.node(0, .{ .padding = .{ .left = 16, .right = 16, .top = 12, .bottom = 12 } }, .none, &.{try W.typeset(b, notes_markdown, .{ .density = .chat })}),
        }
    }
};

fn layoutDock(b: L.Builder, demo: *Demo, viewport: ui.Rect, count_buf: *[20]u8, font: *const ui.Font) !*L.Element {
    if (!demo.dock_ready) {
        demo.dock_ready = true;
        const dock = &demo.dock;
        try dock.add(@intFromEnum(Panel.components), null, .center);
        try dock.add(@intFromEnum(Panel.scene), @intFromEnum(Panel.components), .right);
        try dock.add(@intFromEnum(Panel.console), @intFromEnum(Panel.scene), .bottom);
        try dock.add(@intFromEnum(Panel.notes), @intFromEnum(Panel.console), .center);
        dock.nodes[dock.root].ratio = 0.64;
        dock.nodes[dock.nodes[dock.root].second].ratio = 0.52;
    }
    const root = try demo.dock.build(b, .main, viewport, DockPanels{ .demo = demo, .count_buf = count_buf, .font = font });
    root.layout(viewport, font);
    return root;
}

/// `content` under a title bar for window `slot`, laid out in `full`.
fn framed(b: L.Builder, demo: *Demo, slot: u32, title: []const u8, full: ui.Rect, content: *L.Element, font: *const ui.Font) !*L.Element {
    const title_bar = try ui.titlebar.bar(b, titlebar_first, slot, title, demo.frame_layout, demo.window_state[slot]);
    const root = try b.node(0, .{ .width = full.w, .height = full.h }, .none, &.{ title_bar, content });
    root.layout(full, font);
    return root;
}
fn belowBar(demo: *const Demo, full: ui.Rect) ui.Rect {
    if (!demo.custom_frame) return full;
    return .{ .x = full.x, .y = full.y + ui.titlebar.height, .w = full.w, .h = @max(0, full.h - ui.titlebar.height) };
}
fn layoutTree(b: L.Builder, demo: *Demo, full: ui.Rect, count_buf: *[20]u8, font: *const ui.Font) !*L.Element {
    demo.tool_slot_count = 0;
    const tree = try layoutWindows(b, demo, full, count_buf, font);
    try fillTools(b, demo, font);
    return tree;
}
/// Put the DevTools views into their panel slots, now that the page they inspect is laid out.
fn fillTools(b: L.Builder, demo: *Demo, font: *const ui.Font) !void {
    if (demo.tool_slot_count == 0) return;
    try demo.devtools.prepare(devtools_gpa, demo.inspected orelse return);
    for (demo.tool_slots[0..demo.tool_slot_count]) |slot| {
        const view = try demo.devtools.view(b, devtools_gpa, slot.tool, slot.element.bounds);
        view.layout(slot.element.bounds, font);
        slot.element.children = try b.allocator.dupe(*L.Element, &.{view});
    }
}
fn layoutWindows(b: L.Builder, demo: *Demo, full: ui.Rect, count_buf: *[20]u8, font: *const ui.Font) !*L.Element {
    const inner = try layoutMain(b, demo, belowBar(demo, full), count_buf, font);
    const main = if (demo.custom_frame) try framed(b, demo, 0, "eggy", full, inner, font) else inner;
    demo.frame_windows = 0;
    if (!demo.docked) return main;
    // Popped-out panels: each OS window's tree, in its own slice of the coordinate space.
    var roots: std.ArrayList(*L.Element) = .empty;
    try roots.append(b.allocator, main);
    for (demo.dock.windows, demo.window_sizes, 0..) |window, size, i| {
        if (window == null or size == null) continue;
        const full_window = ui.Rect{ .x = windowOrigin(i), .y = 0, .w = size.?[0], .h = size.?[1] };
        const viewport = belowBar(demo, full_window);
        const dock_tree = try demo.dock.build(b, .{ .window = @intCast(i) }, viewport, DockPanels{ .demo = demo, .count_buf = count_buf, .font = font });
        dock_tree.layout(viewport, font);
        const node = demo.dock.nodes[demo.dock.windows[i].?.root];
        const tree = if (demo.custom_frame) try framed(b, demo, @intCast(i + 1), if (node.count > 0) panelTitle(node.panels[node.active]) else "Panel", full_window, dock_tree, font) else dock_tree;
        demo.frame_window_index[demo.frame_windows] = @intCast(i);
        demo.frame_windows += 1;
        try roots.append(b.allocator, tree);
    }
    if (demo.frame_windows == 0) return main;
    // Not laid out as a whole: it only groups the per-window trees for focus and hit-testing.
    return b.node(0, .{}, .none, roots.items);
}
fn layoutMain(b: L.Builder, demo: *Demo, full: ui.Rect, count_buf: *[20]u8, font: *const ui.Font) !*L.Element {
    const page = if (demo.docked) try layoutDock(b, demo, full, count_buf, font) else try layoutPage(b, demo, full, count_buf, font);
    // DevTools property edits outlive the rebuild, like styles edited in a browser.
    if (demo.devtools.apply(page)) page.layout(full, font);
    demo.inspected = page;
    return page;
}
fn layoutPage(b: L.Builder, demo: *Demo, viewport: ui.Rect, count_buf: *[20]u8, font: *const ui.Font) !*L.Element {
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
    const badge = try b.node(0, .{ .height = 24 }, .{ .badge = .{ .label = "Alpha" } }, &.{});
    const header = try b.node(0, .{ .direction = if (page_width < 320) .column else .row, .gap = 12, .align_items = .center }, .none, &.{ title, badge });
    const introduction = try b.node(0, .{ .direction = .column, .gap = 4 }, .none, &.{
        try label(b, "Clean building blocks", 22, false, true),
        try label(b, "A small UI kit for the Eggy engine.", 15, true, true),
    });
    const button = try b.node(button_id, .{ .width = 168, .height = 40 }, .{ .button = .{ .label = "Try button" } }, &.{});
    const slider = try b.node(slider_id, .{ .height = 32 }, .{ .slider = .{ .value = (demo.ui_scale - 0.75) / 1.25 } }, &.{});
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
        try b.node(checkbox_id, .{ .height = 32 }, .{ .checkbox = .{ .label = "Show hints", .checked = demo.checked } }, &.{}),
        try line(b),
        try b.node(toggle_id, .{ .height = 32 }, .{ .toggle = .{ .label = "Live updates", .enabled = demo.enabled } }, &.{}),
        try line(b),
        try label(b, scale_label, 15, true, false),
        slider,
        try line(b),
        try label(b, "Appearance", 15, true, false),
        try ui.widgets.toggleGroup(b, &.{ .{ .id = appearance_id, .label = "System" }, .{ .id = appearance_id + 1, .label = "Light" }, .{ .id = appearance_id + 2, .label = "Dark" } }, &.{appearance_id + @as(u32, @intFromEnum(demo.appearance))}),
        try line(b),
        try b.node(0, .{ .direction = .row, .gap = 12, .align_items = .center }, .none, &.{
            try b.node(debug_id, .{ .height = 32 }, .{ .toggle_button = .{ .label = "Debug hitboxes", .pressed = demo.debug_hitboxes } }, &.{}),
            try label(b, "Outline every click target in red.", 14, true, true),
        }),
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
        const modal = if (demo.dialog_kind == .alert_dialog) try ui.widgets.modal(b, viewport, .alert_dialog, &.{
            try label(b, "Confirm action", 22, false, false),
            try label(b, "The rest of the page is unavailable until this closes.", 15, true, true),
            try b.node(0, .{ .direction = .row, .gap = 8 }, .none, &.{ try b.button(490, "Continue"), try b.buttonVariant(492, "Cancel", .outline) }),
        }) else try ui.widgets.modal(b, viewport, demo.dialog_kind, &.{
            try label(b, switch (demo.dialog_kind) {
                .sheet => "Sheet",
                .drawer => "Drawer",
                else => "Dialog",
            }, 22, false, false),
            try label(b, switch (demo.dialog_kind) {
                .sheet => "Slides in from the edge for secondary tasks.",
                .drawer => "Rises from the bottom, handy on small screens.",
                else => "A focused window over the page. Escape closes it.",
            }, 15, true, true),
            try b.buttonVariant(493, "Close", .outline),
        });
        modal.id = 488;
        modal.style.z_index = 300;
        modal.overlay = .viewport;
        modal.children[0].accessibility.label = if (demo.dialog_kind == .alert_dialog) "Confirm action" else "Panel";
        layers[count_layers] = modal;
        count_layers += 1;
    }
    if (demo.toast_visible and !demo.dialog_open) {
        layers[count_layers] = try ui.widgets.dismissibleToastAt(b, viewport, "Saved", "Your changes are ready.", 444);
        count_layers += 1;
    }
    return b.node(0, .{ .width = viewport.w, .height = viewport.h }, .none, layers[0..count_layers]);
}

fn menusCard(b: L.Builder, demo: *Demo) !*L.Element {
    // Copy the static menus so checkbox and radio rows reflect current state.
    const menus = try b.allocator.dupe(W.MenubarMenu, &menubar_menus);
    for (menus) |*entry| {
        const rows = try b.allocator.dupe(W.MenuItem, entry.items);
        for (rows) |*row| row.checked = switch (row.id) {
            menubar_first_id + 30 => demo.bookmarks_bar,
            menubar_first_id + 31 => demo.full_urls,
            menubar_first_id + 40...menubar_first_id + 42 => row.id == demo.profile,
            else => false,
        };
        entry.items = rows;
    }
    const bar = try W.menubar(b, menus, demo.menubar_open, demo.menubar_highlight, demo.menubar_submenu);
    for (bar.children[0].children) |child| if (child.overlay != null) {
        child.id = menubar_popup_id;
        for (child.children) |row| if (row.overlay != null) {
            row.id = submenu_popup_id;
        };
    };
    const nav = try W.navigationMenu(b, &.{
        .{ .id = nav_first_id, .label = "Getting started", .links = &.{
            .{ .id = nav_first_id + 10, .title = "Introduction", .description = "Immediate-mode widgets for the Eggy engine." },
            .{ .id = nav_first_id + 11, .title = "Installation", .description = "Add weeoui with zig fetch and two imports." },
            .{ .id = nav_first_id + 12, .title = "Theming", .description = "Light, dark, or follow the system." },
            .{ .id = nav_first_id + 13, .title = "Accessibility", .description = "AccessKit exposes every control to screen readers." },
        } },
        .{ .id = nav_first_id + 1, .label = "Components", .links = &.{
            .{ .id = nav_first_id + 14, .title = "Menubar", .description = "Desktop menus with shortcuts and submenus." },
            .{ .id = nav_first_id + 15, .title = "Calendar", .description = "Type a date or step months and years." },
        } },
        .{ .id = nav_first_id + 2, .label = "Docs" },
    }, demo.nav_open);
    for (nav.children) |child| if (child.overlay != null) {
        child.id = nav_popup_id;
    };
    return b.card(&.{
        try label(b, "Menubar and navigation", 22, false, false),
        try label(b, "Arrow keys move between menus and items; Escape closes.", 14, true, true),
        bar,
        nav,
    });
}

fn layoutCard(b: L.Builder, demo: *Demo, inner_width: f32) !*L.Element {
    const names = [_][]const u8{ "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta" };
    var chips: [names.len]*L.Element = undefined;
    for (&chips, names) |*chip, name| chip.* = try b.node(0, .{ .height = 28, .padding = .{ .left = 12, .right = 12 } }, .{ .surface = .track }, &.{try b.node(0, .{ .height = 28 }, .{ .text = .{ .value = name, .size = 14 } }, &.{})});
    const flex = try b.node(0, .{
        .direction = .row,
        .gap = 8,
        .wrap = demo.layout_wrap,
        .justify = switch (demo.layout_justify - layout_first_id) {
            0 => .start,
            1 => .center,
            2 => .end,
            else => .space_between,
        },
        .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
    }, .{ .surface = .card }, &chips);
    var tiles: [6]*L.Element = undefined;
    for (&tiles, 0..) |*tile, i| tile.* = try b.node(0, .{ .height = @floatFromInt(40 + (i % 3) * 16), .padding = .{ .left = 10, .top = 8 } }, .{ .surface = .track }, &.{try label(b, try std.fmt.allocPrint(b.allocator, "Cell {d}", .{i + 1}), 13, true, false)});
    const grid = try b.node(0, .{ .columns = demo.grid_columns, .gap = 8 }, .none, &tiles);
    const mirrored = try W.textDirection(b, demo.rtl, &.{
        try b.node(0, .{ .direction = .row, .gap = 8, .align_items = .center }, .none, &.{
            try b.avatar("RT"),
            try b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = if (demo.rtl) "Right-to-left: rows start on the right" else "Left-to-right: rows start on the left", .size = 14 } }, &.{}),
            try b.node(0, .{ .height = 22 }, .{ .badge = .{ .label = if (demo.rtl) "RTL" else "LTR", .variant = .secondary } }, &.{}),
        }),
    });
    var cards: [10]*L.Element = undefined;
    for (&cards, 0..) |*card, i| card.* = try b.node(0, .{ .width = 100, .height = 80, .padding = .{ .left = 10, .top = 10 } }, .{ .surface = .card }, &.{try label(b, try std.fmt.allocPrint(b.allocator, "Card {d}", .{i + 1}), 14, false, false)});
    return b.card(&.{
        try label(b, "Layout: flexbox, grid and direction", 22, false, true),
        try label(b, "Justify", 14, true, false),
        try W.toggleGroup(b, &.{ .{ .id = layout_first_id, .label = "Start" }, .{ .id = layout_first_id + 1, .label = "Center" }, .{ .id = layout_first_id + 2, .label = "End" }, .{ .id = layout_first_id + 3, .label = "Between" } }, &.{demo.layout_justify}),
        try b.node(0, .{ .direction = .row, .gap = 8, .wrap = true }, .none, &.{
            try b.node(layout_first_id + 4, .{ .height = 36 }, .{ .toggle_button = .{ .label = "Wrap", .pressed = demo.layout_wrap } }, &.{}),
            try b.node(layout_first_id + 8, .{ .height = 36 }, .{ .toggle_button = .{ .label = "Right to left", .pressed = demo.rtl } }, &.{}),
        }),
        try b.node(0, .{ .width = @min(inner_width, 420) }, .none, &.{flex}),
        try label(b, "Grid columns", 14, true, false),
        try W.toggleGroup(b, &.{ .{ .id = layout_first_id + 5, .label = "2" }, .{ .id = layout_first_id + 6, .label = "3" }, .{ .id = layout_first_id + 7, .label = "4" } }, &.{layout_first_id + 3 + @as(u32, demo.grid_columns)}),
        grid,
        mirrored,
        try label(b, "Sideways scroll (Shift + wheel or trackpad)", 14, true, false),
        try W.scrollArea(b, .{ .x = 0, .y = 0, .w = @min(inner_width, 420), .h = 96 }, &demo.wide_scroll, &.{
            try b.node(0, .{ .direction = .row, .gap = 8, .width = 1080 }, .none, &cards),
        }),
    });
}

fn conversationCard(b: L.Builder) !*L.Element {
    return b.card(&.{
        try label(b, "Conversation", 22, false, false),
        try W.marker(b, "Today", .separator, null),
        try W.bubble(b, "Hey there! what's up? \u{1f44b}", .{}),
        try W.bubble(b, "Sure. Hit me with your best demo", .{ .alignment = .end, .variant = .default }),
        try W.bubble(b, "Yes. You are reading a demo that is demoing itself.", .{ .reactions = "\u{1f44d} \u{1f525} \u{1f440} +2" }),
        try W.marker(b, "Agent is typing...", .default, .info),
        try W.marker(b, "Conversation archived", .border, null),
        try W.message(b, "Eggy", "Messages pair an avatar with the author and body. \u{1f95a}"),
    });
}

fn colorCard(b: L.Builder, demo: *Demo) !*L.Element {
    return b.card(&.{
        try label(b, "Color picker", 22, false, false),
        try label(b, "Unreal-style: the wheel picks hue and saturation, the bars saturation and value. Drag any slider, use the arrow keys, or type a hex value and press Enter.", 14, true, true),
        try W.colorEditor(b, color_first_id, demo.color, .{ .value = demo.editable[7].text.text() }, .{ .value = demo.editable[8].text.text() }, &swatches),
        try b.node(0, .{ .direction = .row, .gap = 12, .align_items = .center }, .none, &.{
            try b.node(accent_id, .{ .height = 36 }, .{ .toggle_button = .{ .label = "Use as accent", .pressed = demo.custom_accent } }, &.{}),
            try label(b, "Recolors buttons and focus rings.", 14, true, true),
        }),
    });
}

const typography_markdown =
    \\# Taxing Laughter: The Joke Tax Chronicles
    \\Once upon a time, in a far-off land, there was a very lazy king who spent all day lounging on his throne. One day, his advisors came to him with a problem: the kingdom was running out of money.
    \\## The King's Plan
    \\The king thought long and hard, and finally came up with a brilliant plan: he would tax the jokes in the kingdom.
    \\> "After all," he said, "everyone enjoys a good joke, so it's only fair that they should pay for the privilege."
    \\### The Joke Tax
    \\The king's subjects were not amused. They grumbled and complained, but the king was firm:
    \\- 1st level of puns: 5 gold coins
    \\- 2nd level of jokes: 10 gold coins
    \\- 3rd level of one-liners: 20 gold coins
    \\As a result, people stopped telling jokes, and the kingdom fell into a gloom.
    \\| King's Treasury | People's happiness |
    \\| --- | --- |
    \\| Empty | Overflowing |
    \\| Modest | Satisfied |
    \\| Full | Ecstatic |
    \\### Render your own
    \\1. Write markdown
    \\2. Pass it to `W.typeset`
    \\```
    \\try W.typeset(b, markdown, .{});
    \\```
;

fn typographyCard(b: L.Builder) !*L.Element {
    return b.card(&.{
        try label(b, "Typography (Typeset)", 14, true, false),
        try W.typeset(b, typography_markdown, .{}),
    });
}

fn questionnaireCard(b: L.Builder, demo: *Demo) !*L.Element {
    if (demo.questionnaire_done) return b.card(&.{
        try label(b, "Questionnaire", 22, false, false),
        try W.marker(b, "Plan saved", .default, .check),
        try b.buttonVariant(question_first_id + 3, "Start over", .outline),
    });
    return b.card(&.{
        try label(b, "Questionnaire", 22, false, false),
        try W.questionnaire(b, question_first_id, ui_questions[demo.question], demo.question, ui_questions.len, demo.answers[demo.question], .{ .value = demo.editable[6].text.text() }),
    });
}

fn componentGallery(b: L.Builder, demo: *Demo, page_width: f32) !*L.Element {
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
        try W.field(b, 300, "Project", if (demo.editable[0].text.text().len == 0) "A project name is required." else "Shown in the window title.", .{ .value = demo.editable[0].text.text(), .placeholder = "Project name", .invalid = demo.editable[0].text.text().len == 0 }),
        try b.textarea(301, .{ .value = demo.editable[1].text.text(), .placeholder = "Description" }),
        try W.inputGroup(b, 302, "$", .{ .value = demo.editable[2].text.text(), .placeholder = "Amount" }, "USD"),
        try W.inputOtp(b, 310, demo.otp[0..otp_len], 4),
        if (size_menu) |popup| try b.node(0, .{}, .none, &.{ select, blk: {
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
        try b.node(0, .{ .direction = .row, .gap = 12, .align_items = .center, .wrap = true }, .none, &.{
            try b.node(342, .{ .height = 36 }, .{ .toggle_button = .{ .label = "Bold", .pressed = demo.bold } }, &.{}),
            try label(b, "Quality", 14, true, false),
            blk: {
                const native = try W.nativeSelect(b, 345, &native_options, demo.native_index);
                native.style.width = 140;
                break :blk native;
            },
        }),
        try b.node(0, .{ .direction = .row, .gap = 8, .wrap = true }, .none, &.{
            try b.buttonVariant(0, "Default", .default),
            try b.buttonVariant(0, "Secondary", .secondary),
            try b.buttonVariant(0, "Outline", .outline),
            try b.buttonVariant(0, "Ghost", .ghost),
            try b.buttonVariant(0, "Destructive", .destructive),
            try b.buttonVariant(0, "Link", .link),
        }),
        try b.node(0, .{ .direction = .row, .gap = 8, .wrap = true }, .none, &.{
            try b.node(0, .{ .height = 22 }, .{ .badge = .{ .label = "Default" } }, &.{}),
            try b.node(0, .{ .height = 22 }, .{ .badge = .{ .label = "Secondary", .variant = .secondary } }, &.{}),
            try b.node(0, .{ .height = 22 }, .{ .badge = .{ .label = "Destructive", .variant = .destructive } }, &.{}),
            try b.node(0, .{ .height = 22 }, .{ .badge = .{ .label = "Outline", .variant = .outline } }, &.{}),
        }),
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
        try label(b, "Type a date and press Enter, or hold the arrows to skip months and years.", 14, true, true),
        try W.datePickerInput(b, date_input_id, date_button_id, 1000, demo.date, .{ .value = demo.editable[5].text.text() }, demo.calendar_open, @min(300, inner_width)),
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
    for ([_]*L.Element{ workspace_button, dashboard_button, settings_button }, 520..) |entry, id| {
        entry.paint_kind.button.variant = .ghost;
        entry.paint_kind.button.hot = demo.sidebar_selection == id;
    }
    const sidebar = try W.sidebar(b, 172, &.{ workspace_button, dashboard_button, settings_button });
    sidebar.style.width = @min(240, inner_width);
    const sidebar_content = switch (demo.sidebar_selection) {
        520 => try b.card(&.{
            try label(b, "Workspace", 20, false, false),
            try label(b, try std.fmt.allocPrint(b.allocator, "Project: {s}", .{demo.editable[0].text.text()}), 15, false, true),
            try b.node(0, .{ .direction = .row, .gap = 8 }, .none, &.{ try b.button(530, "New file"), try b.button(531, "New folder") }),
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
        try label(b, if (demo.docked) "3D scene (Vitellus): see the Scene panel" else "3D scene (Vitellus)", 14, true, false),
        if (demo.docked) try b.node(0, .{ .height = 0 }, .none, &.{}) else scene,
        try b.row(&.{ try b.avatar("AB"), try b.spinner(demo.animation_phase), try b.animatedSkeleton(72, 24, demo.animation_phase) }),
        try b.node(0, .{ .width = 160, .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 }, .gap = 8 }, .card, &.{
            image,
            try label(b, "Lucide SVG image", 14, true, false),
        }),
        item,
        try b.node(0, .{ .direction = .row, .gap = 8, .align_items = .center }, .none, &.{ blk: {
            const choose = try b.buttonVariant(470, "Choose file", .outline);
            choose.style.width = 132;
            break :blk choose;
        }, try b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = demo.filename.text(), .tone = .muted, .size = 14 } }, &.{}) }),
        if (demo.attachment_visible) try W.attachment(b, 471, .{ .name = "report.pdf", .state = .uploading, .progress = 0.64 }) else try b.node(0, .{ .height = 0 }, .none, &.{}),
        try W.attachment(b, 0, .{ .name = "workspace.png", .description = "PNG image, 1.2 MB", .icon = .image }),
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
        try b.node(0, .{ .direction = .row, .gap = 8 }, .none, &.{ try b.button(498, "Add message"), try b.buttonVariant(499, "Jump to latest", .outline) }),
        resizable,
        try W.aspectRatio(b, 160, 1.6, &.{try b.skeleton(160, 100)}),
        try b.node(0, .{ .direction = .row, .gap = 8, .wrap = true }, .none, &.{
            try b.button(489, "Alert dialog"),
            try b.buttonVariant(486, "Dialog", .outline),
            try b.buttonVariant(487, "Sheet", .outline),
            try b.buttonVariant(485, "Drawer", .outline),
        }),
    });

    const gallery = try b.node(gallery_id, .{ .gap = gap }, .none, &.{
        try label(b, "Component gallery", 22, false, false),
        try label(b, "Every control responds to pointer, keyboard, and accessible actions.", 14, true, true),
        try b.node(0, .{ .width = @min(inner_width, 400), .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 }, .gap = 0 }, .card, &.{
            try b.node(0, .{ .height = 32 }, .{ .text = .{ .value = "Start aligned", .alignment = .start } }, &.{}),
            try b.node(0, .{ .height = 32 }, .{ .text = .{ .value = "Center aligned", .alignment = .center } }, &.{}),
            try b.node(0, .{ .height = 32 }, .{ .text = .{ .value = "End aligned", .alignment = .end } }, &.{}),
        }),
        try b.node(0, .{ .direction = .row, .gap = 8, .align_items = .center }, .none, &.{ try b.icon(.search), try b.icon(.check), try label(b, "Lucide SVG icons", 14, true, false) }),
        try menusCard(b, demo),
        choices,
        navigation,
        feedback,
        try layoutCard(b, demo, inner_width),
        try conversationCard(b),
        try colorCard(b, demo),
        try typographyCard(b),
        try questionnaireCard(b, demo),
        data,
    });
    return gallery;
}

test "responsive cards and controls follow scrolling" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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
    try std.testing.expect(snapshotNode(snapshot, 1029) == null);
    try std.testing.expect(!snapshotNode(snapshot, date_button_id).?.expanded.?);
    try std.testing.expect(demo.accessibilityAction(date_button_id, .click));
    const calendar_open = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    const day = snapshotNode(calendar_open, 1029).?;
    try std.testing.expectEqualStrings("29", day.label);
    try std.testing.expect(!day.disabled and day.actionable);
    try std.testing.expectEqual(L.Accessibility.Role.column_header, snapshotNode(snapshot, 450).?.role);
    try std.testing.expect(snapshotNode(calendar_open, date_button_id).?.expanded.?);
    _ = demo.dismiss();
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
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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
        appearance_id...appearance_id + 2,
        350...351,
        360...361,
        370...371,
        342,
        345,
        380...381,
        390...393,
        date_input_id,
        date_button_id,
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
        470...471,
        480,
        485...487,
        489,
        491,
        498...499,
        520...522,
        530...531,
        533...536,
        debug_id,
        layout_first_id...layout_first_id + 8,
        question_first_id...question_first_id + 2,
        question_first_id + 17,
        question_first_id + 19,
        menubar_first_id + 1...menubar_first_id + 4,
        nav_first_id...nav_first_id + 2,
        color_first_id...color_first_id + 14,
        first_swatch_id...first_swatch_id + swatches.len - 1,
        accent_id,
        1001...1039,
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
    try std.testing.expect(demo.accessibilityAction(date_button_id, .click));
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expect(demo.accessibilityAction(1028, .click));
    try std.testing.expectEqualStrings("2024-02-28  00:00", demo.editable[5].text.text());
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
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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

    try std.testing.expect(demo.accessibilityAction(date_button_id, .click));
    _ = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(demo.accessibilityAction(1033, .click));
    try std.testing.expectEqual(@as(u8, 3), demo.date.month);
    try std.testing.expect(demo.accessibilityAction(1035, .click));
    try std.testing.expect(demo.accessibilityAction(1037, .click));
    try std.testing.expectEqual(@as(u8, 1), demo.date.hour);
    try std.testing.expectEqual(@as(u8, 15), demo.date.minute);
    snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    try std.testing.expect(std.mem.indexOf(u8, snapshotNode(snapshot, date_input_id).?.value, "01:15") != null);

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
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
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

test "appearance choices switch theme mode and arrow between peers" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var demo: Demo = .{};
    try demo.relayout(std.testing.allocator, .{ .x = 0, .y = 0, .w = 900, .h = 675 }, &font);
    demo.focus = demo.indexOf(appearance_id + 2).?;
    demo.activate();
    try std.testing.expectEqual(Appearance.dark, demo.appearance);
    try std.testing.expect(demo.moveComposite(1));
    try std.testing.expectEqual(@as(u32, appearance_id), demo.focusId());
}

test "holding a calendar arrow repeats after a delay and typed dates commit on Enter" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var demo: Demo = .{};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expect(!demo.calendar_open);
    try std.testing.expect(demo.accessibilityAction(date_button_id, .click));
    try demo.relayout(std.testing.allocator, viewport, &font);
    const next_month = demo.controls[demo.indexOf(1033).?];
    demo.pointerDown(next_month.center().x, next_month.center().y);
    try std.testing.expectEqual(@as(u8, 3), demo.date.month);
    demo.tickScroll(0.3);
    try std.testing.expectEqual(@as(u8, 3), demo.date.month); // still inside the initial delay
    demo.tickScroll(0.2); // 0.5 s: repeats at 0.40 and 0.48
    try std.testing.expectEqual(@as(u8, 5), demo.date.month);
    demo.tickScroll(0.16); // 0.66 s: 0.56 and 0.64
    try std.testing.expectEqual(@as(u8, 7), demo.date.month);
    demo.pointerUp();
    demo.tickScroll(1);
    try std.testing.expectEqual(@as(u8, 7), demo.date.month);
    try std.testing.expect(demo.accessibilityAction(date_input_id, .focus));
    try std.testing.expect(demo.editKey(.select_all, false, false, &font));
    try std.testing.expect(demo.insertText("1999-12-31 23:59"));
    try std.testing.expect(demo.commitEdit());
    try std.testing.expectEqual(ui.widgets.Date{ .year = 1999, .month = 12, .day = 31, .hour = 23, .minute = 59 }, demo.date);
}

test "color editor drags, hex entry, swatches, and cancel share one color" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var demo: Demo = .{};
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    demo.scroll.ensureVisible(demo.controls[demo.indexOf(wheel_id).?]);
    try demo.relayout(std.testing.allocator, viewport, &font);
    const wheel = demo.controls[demo.indexOf(wheel_id).?];
    demo.pointerDown(wheel.x + wheel.w - 0.5, wheel.center().y); // right edge: hue 90 degrees, full saturation
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), demo.color.hsv.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), demo.color.hsv.s, 0.01);
    demo.pointerMove(wheel.center().x, wheel.y + wheel.h - 0.5); // drag to the bottom
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), demo.color.hsv.h, 0.01);
    demo.pointerUp();
    const value_bar = demo.controls[demo.indexOf(color_first_id + 2).?];
    demo.pointerDown(value_bar.center().x, value_bar.y + value_bar.h - 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 0), demo.color.hsv.v, 0.01);
    demo.pointerUp();
    try std.testing.expect(demo.accessibilityAction(hex_srgb_id, .focus));
    try std.testing.expect(demo.editKey(.select_all, false, false, &font));
    try std.testing.expect(demo.insertText("2f9ce0"));
    try std.testing.expect(demo.commitEdit());
    try std.testing.expectEqualStrings("2F9CE0FF", demo.editable[8].text.text());
    try std.testing.expect(demo.accessibilityAction(first_swatch_id + 1, .click));
    try std.testing.expectEqualStrings("E86A3AFF", demo.editable[8].text.text());
    try std.testing.expect(demo.accessibilityAction(color_first_id + 6, .decrement)); // alpha down
    try std.testing.expectEqualStrings("E86A3AF2", demo.editable[8].text.text());
    try std.testing.expect(demo.accessibilityAction(color_first_id + 13, .click)); // Cancel
    try std.testing.expectEqualStrings("F2B233FF", demo.editable[8].text.text());
}

test "F12 docks the DevTools panels beside the page; Inspect picks without clicking through" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var demo: Demo = .{ .docked = true };
    defer demo.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 1400, .h = 900 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    // Console starts as a panel, tabbed behind Notes; Elements and Performance come with F12.
    try std.testing.expect(demo.dock.nodeOf(@intFromEnum(Panel.console)) != null);
    try std.testing.expectEqual(@as(f32, 0), demo.tool_rects[@intFromEnum(ui.devtools.Tool.console)].w);
    demo.toggleDevtools();
    try demo.relayout(std.testing.allocator, viewport, &font);
    const elements = demo.tool_rects[@intFromEnum(ui.devtools.Tool.elements)];
    try std.testing.expect(elements.w > 0);
    const button = demo.controls[demo.indexOf(button_id).?];
    try std.testing.expect(elements.x > button.x); // docked to the right of the page
    try std.testing.expect(demo.accessibilityAction(ui.devtools.first_id + 8, .click)); // Inspect
    try std.testing.expect(demo.devtools.inspecting);
    demo.pointerDown(button.center().x, button.center().y);
    try std.testing.expectEqual(@as(u32, 0), demo.count); // the click went to the inspector
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expect(!demo.devtools.inspecting and demo.devtools.selected != 0);
    // Every element, text and buttons included, has a row (the tree is fully expanded).
    try std.testing.expect(demo.devtools.row_count > 500);
    // Performance is a tab in the same stack; drawing it works with frame history.
    for (0..90) |i| demo.tickScroll(0.01 + @as(f32, @floatFromInt(i % 7)) * 0.001);
    _ = demo.dock.activate(ui.dock.first_id + @intFromEnum(Panel.performance));
    const vertices = try std.testing.allocator.alloc(ui.Vertex, 250_000);
    defer std.testing.allocator.free(vertices);
    var canvas = ui.Canvas.init(vertices, &font);
    _ = try demo.draw(std.testing.allocator, &canvas, viewport);
    try std.testing.expect(demo.tool_rects[@intFromEnum(ui.devtools.Tool.performance)].w > 0);
    try std.testing.expect(demo.devtools.vertices > 0);
    // F12 again takes them away.
    demo.toggleDevtools();
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expectEqual(@as(f32, 0), demo.tool_rects[@intFromEnum(ui.devtools.Tool.elements)].w);
}

test "DevTools edits stick to the rebuilt page" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var demo: Demo = .{ .docked = true };
    defer demo.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 1400, .h = 900 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    demo.toggleDevtools();
    try demo.relayout(std.testing.allocator, viewport, &font);
    // Select the Try button by inspecting it, then type a new label into its text field.
    const button = demo.controls[demo.indexOf(button_id).?];
    demo.devtools.inspecting = true;
    demo.pointerDown(button.center().x, button.center().y);
    try demo.relayout(std.testing.allocator, viewport, &font);
    const text_field = ui.devtools.first_id + 200 + @intFromEnum(ui.devtools.Prop.text);
    try std.testing.expect(demo.accessibilityAction(text_field, .click));
    try std.testing.expect(demo.isEditing());
    try std.testing.expect(demo.insertText("Edited"));
    try std.testing.expect(demo.commitEdit());
    const width_field = ui.devtools.first_id + 200 + @intFromEnum(ui.devtools.Prop.width);
    try std.testing.expect(demo.accessibilityAction(width_field, .focus));
    try std.testing.expect(demo.editKey(.up, true, false, &font)); // +10
    try demo.relayout(std.testing.allocator, viewport, &font);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, &font);
    for (snapshot.nodes) |node| if (node.id == button_id) {
        try std.testing.expectEqualStrings("Edited", node.label);
    };
    try std.testing.expectApproxEqAbs(@as(f32, 178), demo.controls[demo.indexOf(button_id).?].w, 0.5);
}

test "the wheel scrolls DevTools panes, not the page behind them" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var demo: Demo = .{ .docked = true };
    defer demo.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 1400, .h = 900 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    demo.toggleDevtools();
    try demo.relayout(std.testing.allocator, viewport, &font);
    const tree = demo.devtools.tree_scroll.viewport;
    try std.testing.expect(demo.inTools(tree.center().x, tree.center().y));
    demo.scrollWheel(tree.center().x, tree.center().y, 0, -3);
    try std.testing.expect(demo.devtools.tree_scroll.offset.y > 0);
    try std.testing.expectEqual(@as(f32, 0), demo.scroll.offset.y);
    // Scrolled all the way down, extra wheel over the panel still leaves the page alone.
    demo.scrollWheel(tree.center().x, tree.center().y, 0, -100000);
    try std.testing.expectEqual(@as(f32, 0), demo.scroll.offset.y);
    // Over the page, the page scrolls as before.
    const button = demo.controls[demo.indexOf(button_id).?];
    demo.scrollWheel(button.center().x, button.center().y, 0, -3);
    try std.testing.expect(demo.scroll.offset.y > 0);
}

test "docked editor pops panels into windows that share one control list, and docks them back" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var demo: Demo = .{ .docked = true };
    defer demo.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 1400, .h = 900 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    // Components (the page) sits left of the Scene panel, which holds the 3D view.
    const button = demo.controls[demo.indexOf(button_id).?];
    try std.testing.expect(demo.scene_viewport.w > 0 and demo.scene_viewport.x > button.x);
    const scene_tab = ui.dock.first_id + @intFromEnum(Panel.scene);
    try std.testing.expect(demo.indexOf(scene_tab) != null);
    // Pop the Scene out; once the app reports its window size, its tree joins the controls.
    try demo.dock.detach(@intFromEnum(Panel.scene));
    demo.window_sizes[0] = .{ 500, 400 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expect(demo.scene_viewport.x >= windowOrigin(0));
    const tab = demo.controls[demo.indexOf(scene_tab).?];
    try std.testing.expect(tab.x >= windowOrigin(0));
    // A click in that window (its x offset by the window's origin) reaches its controls.
    demo.pointerDown(tab.center().x, tab.center().y);
    try std.testing.expectEqual(scene_tab, demo.focusId());
    try std.testing.expect(demo.indexOf(button_id) != null); // the main window's controls remain
    // Closing the window docks the panel back into the main window.
    demo.dock.redock(.{ .window = 0 });
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expect(demo.scene_viewport.x < windowOrigin(0) and demo.scene_viewport.w > 0);
    const vertices = try std.testing.allocator.alloc(ui.Vertex, 250_000);
    defer std.testing.allocator.free(vertices);
    var canvas = ui.Canvas.init(vertices, &font);
    _ = try demo.draw(std.testing.allocator, &canvas, viewport);
}

test "custom title bars follow the desktop's button layout and request window actions" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var demo: Demo = .{ .docked = true, .custom_frame = true, .frame_layout = ui.titlebar.Layout.parse(":close", .gnome) };
    defer demo.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 1200, .h = 800 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    // A bar across the top, with only a close button (minimize and maximize turned off).
    try std.testing.expectEqual(viewport.w, demo.frames[0].bar.w);
    try std.testing.expectEqual(@as(u8, 1), demo.frames[0].count);
    try std.testing.expect(demo.frames[0].buttons[0].x > viewport.w / 2);
    try std.testing.expect(demo.indexOf(ui.titlebar.id(titlebar_first, 0, .minimize)) == null);
    // Everything else starts below it.
    try std.testing.expect(demo.controls[demo.indexOf(ui.dock.first_id + @intFromEnum(Panel.components)).?].y >= ui.titlebar.height);
    try std.testing.expect(demo.accessibilityAction(ui.titlebar.id(titlebar_first, 0, .close), .click));
    try std.testing.expectEqual(ui.titlebar.Button.close, demo.window_request.?.button);
    // A popped-out panel gets its own bar in its own slot, with window-local coordinates.
    try demo.dock.detach(@intFromEnum(Panel.notes));
    demo.window_sizes[0] = .{ 400, 300 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    try std.testing.expectEqual(@as(f32, 0), demo.frames[1].bar.x);
    try std.testing.expectEqual(@as(f32, 400), demo.frames[1].bar.w);
}

test "the cursor follows hovered controls and ongoing drags" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var demo: Demo = .{};
    defer demo.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };
    try demo.relayout(std.testing.allocator, viewport, &font);
    const button = demo.controls[demo.indexOf(button_id).?];
    demo.pointerMove(button.center().x, button.center().y);
    try std.testing.expectEqual(ui.Cursor.pointer, demo.pointerCursor());
    demo.scroll.ensureVisible(demo.controls[demo.indexOf(300).?]);
    try demo.relayout(std.testing.allocator, viewport, &font);
    const field = demo.controls[demo.indexOf(300).?];
    demo.pointerMove(field.center().x, field.center().y);
    try std.testing.expectEqual(ui.Cursor.text, demo.pointerCursor());
    demo.pointerMove(2, 2);
    try std.testing.expectEqual(ui.Cursor.default, demo.pointerCursor());
    demo.dragging_divider = true;
    try std.testing.expectEqual(ui.Cursor.ew_resize, demo.pointerCursor());
}
