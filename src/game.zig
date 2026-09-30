const std = @import("std");
const sdl_adapter = @import("vitellus_sdl3");
const sdl3 = sdl_adapter.sdl;
const weeoui_sdl3 = @import("weeoui_sdl3");

const graphics = @import("graphics.zig");
const accessibility = @import("accessibility.zig");
const builtin = @import("builtin");

const fps = 340000;
/// Every bounds-only accessibility update costs a full tree push to the platform (~13 ms on AT-SPI),
/// so scrolling and dragging publish at this rate instead of every frame.
const a11y_bounds_interval_ns = 250 * std.time.ns_per_ms;
const width = 900;
const height = 675;
const FileResult = struct {
    const Status = enum { selected, cancelled, failed, filename_too_long };
    status: Status,
    name: [128]u8 = undefined,
    len: usize = 0,
};
/// SDL user-event code for file picker results.
const file_event_code: i32 = -1;

fn fileSelected(_: ?*anyopaque, files: ?[]const [*:0]const u8, _: ?usize, failed: bool) void {
    const result = std.heap.page_allocator.create(FileResult) catch {
        std.log.err("Cannot allocate file dialog result", .{});
        return;
    };
    result.* = .{ .status = if (failed) .failed else if (files == null or files.?.len == 0) .cancelled else .selected };
    if (result.status == .selected) {
        const name = std.fs.path.basename(std.mem.span(files.?[0]));
        if (name.len > result.name.len) {
            std.log.err("Selected filename is too long to display", .{});
            result.status = .filename_too_long;
        } else {
            @memcpy(result.name[0..name.len], name);
            result.len = name.len;
        }
    }
    if (failed) std.log.err("Native file picker failed", .{});
    sdl3.events.push(.{ .user = .{
        .common = .{ .timestamp = 0 },
        .event_type = @intFromEnum(sdl3.events.Type.user),
        .code = file_event_code,
        .data1 = result,
    } }) catch |err| {
        std.heap.page_allocator.destroy(result);
        std.log.err("Cannot deliver file picker result: {s}", .{@errorName(err)});
    };
}

pub const Game = struct {
    window: sdl_adapter.Sdl3Window,
    init_flags: sdl3.InitFlags,
    m_graphics: graphics.Graphics,
    a11y: *@import("weeoui").accesskit.Adapter,
    text_input_active: bool = false,
    a11y_dirty: bool = false,
    /// Only bounds moved (scrolling, dragging): published at most every `a11y_bounds_interval_ns`.
    a11y_moved: bool = false,
    a11y_published_ns: u64 = 0,
    fps_capper: sdl3.extras.FramerateCapper(f32),

    pub fn init(i: sdl3.Init) !Game {
        const init_flags = sdl3.InitFlags{ .video = true };
        try sdl3.init(init_flags);
        errdefer sdl3.quit(init_flags);

        var window: sdl_adapter.Sdl3Window = .init(try sdl3.video.Window.init("eggy", width, height, .{
            .vulkan = true,
            .resizable = true,
            .high_pixel_density = true,
            .hidden = builtin.os.tag == .windows,
        }));
        errdefer window.deinit();

        var m_graphics = try graphics.Graphics.init(i.gpa, window);
        errdefer m_graphics.deinit();
        m_graphics.system_theme = weeoui_sdl3.systemTheme();
        const a11y = try @import("weeoui").accesskit.Adapter.create(i.gpa, try weeoui_sdl3.accessKitWindow(window.window), "eggy");
        errdefer a11y.destroy();
        try accessibility.publish(a11y, m_graphics.demo, m_graphics.viewport, &m_graphics.font);
        weeoui_sdl3.syncWindowBounds(a11y, window.window);
        if (builtin.os.tag == .windows) try window.window.show();

        return .{
            .window = window,
            .init_flags = init_flags,
            .m_graphics = m_graphics,
            .a11y = a11y,
            .fps_capper = .{ .mode = .{ .limited = fps } },
        };
    }

    pub fn deinit(self: *Game) void {
        if (self.text_input_active) sdl3.keyboard.stopTextInput(self.window.window) catch |err| std.log.err("Cannot stop text input: {s}", .{@errorName(err)});
        self.a11y.destroy();
        self.m_graphics.deinit();
        self.window.deinit();
        sdl3.quit(self.init_flags);
        sdl3.shutdown();
    }

    pub fn iterate(self: *Game) !sdl3.AppResult {
        const previous_viewport = self.m_graphics.viewport;
        const previous_dpi = self.m_graphics.font.dpi_scale;
        try self.m_graphics.syncSize(self.window);
        if (!std.meta.eql(previous_viewport, self.m_graphics.viewport) or previous_dpi != self.m_graphics.font.dpi_scale) self.a11y_dirty = true;
        const dt = self.fps_capper.delay();
        self.m_graphics.demo.animation_phase = @mod(self.m_graphics.demo.animation_phase + @min(dt, 0.25) / 1.2, 1);
        self.m_graphics.demo.tickScroll(dt);
        try self.m_graphics.ensureLayout();
        if (accessibility.applyActions(self.a11y, self.m_graphics.demo)) {
            try self.m_graphics.syncSize(self.window);
            try self.m_graphics.relayoutDemo();
            self.a11y_dirty = true;
        }
        const now = sdl3.timer.getNanosecondsSinceInit();
        if (self.a11y_dirty or (self.a11y_moved and now -| self.a11y_published_ns >= a11y_bounds_interval_ns)) {
            // Collected from the frame's own layout rather than a second one.
            var arena = std.heap.ArenaAllocator.init(self.a11y.allocator);
            errdefer arena.deinit();
            var snapshot: @import("weeoui").accessibility.Snapshot = undefined;
            try self.m_graphics.frame(.{ .allocator = arena.allocator(), .out = &snapshot });
            self.a11y.update(arena, snapshot, self.m_graphics.demo.ui_scale);
            self.a11y_dirty = false;
            self.a11y_moved = false;
            self.a11y_published_ns = now;
        } else try self.m_graphics.frame(null);
        weeoui_sdl3.setCursor(self.m_graphics.demo.pointerCursor());
        return .run;
    }

    /// Where the event's window starts in the demo's coordinate space: 0 for the main window,
    /// a far-off slice for a popped-out dock panel.
    fn eventOrigin(self: *const Game, curr_event: sdl3.events.Event) f32 {
        const id: ?sdl3.video.WindowId = switch (curr_event) {
            inline else => |payload| blk: {
                const T = @TypeOf(payload);
                if (T == sdl3.events.Window) break :blk payload.id;
                if (@typeInfo(T) == .@"struct" and @hasField(T, "window_id")) break :blk payload.window_id;
                break :blk null;
            },
        };
        const index = self.m_graphics.windowFor(id orelse return 0) orelse return 0;
        return @import("ui_demo.zig").windowOrigin(index);
    }

    pub fn event(self: *Game, curr_event: sdl3.events.Event) !sdl3.AppResult {
        var publish = false;
        // Handlers hit-test against the layout, so apply what earlier events in this batch changed.
        try self.m_graphics.ensureLayout();
        const origin = self.eventOrigin(curr_event);
        if (weeoui_sdl3.translate(curr_event)) |ui_event| switch (ui_event) {
            .pointer_move => |position| {
                const scale = self.m_graphics.demo.ui_scale;
                const old_hover = .{ self.m_graphics.demo.hover_card_open, self.m_graphics.demo.tooltip_open };
                self.m_graphics.demo.pointerMoveAt(position.x / scale + origin, position.y / scale, &self.m_graphics.font);
                if (self.m_graphics.demo.dragging_slider) {
                    try self.m_graphics.syncSize(self.window);
                    self.a11y_moved = true;
                } else if (old_hover[0] != self.m_graphics.demo.hover_card_open or old_hover[1] != self.m_graphics.demo.tooltip_open) {
                    try self.m_graphics.relayoutDemo();
                    publish = true;
                } else if (self.m_graphics.demo.scrollDragging() or self.m_graphics.demo.dragging_divider or self.m_graphics.demo.dragging_text) {
                    self.a11y_moved = true;
                }
            },
            .pointer_down => |button| {
                if (button.button == .left) {
                    const scale = self.m_graphics.demo.ui_scale;
                    self.m_graphics.demo.pointerDownWithClicks(button.position.x / scale + origin, button.position.y / scale, &self.m_graphics.font, button.clicks);
                    try self.m_graphics.syncSize(self.window);
                    try self.m_graphics.relayoutDemo();
                    publish = true;
                } else if (button.button == .right) {
                    const scale = self.m_graphics.demo.ui_scale;
                    self.m_graphics.demo.pointerContextDown(button.position.x / scale + origin, button.position.y / scale);
                    try self.m_graphics.relayoutDemo();
                    publish = true;
                }
            },
            .pointer_up => |button| if (button.button == .left) {
                // The release point decides where a dragged dock tab lands.
                const scale = self.m_graphics.demo.ui_scale;
                self.m_graphics.demo.pointer_x = button.position.x / scale + origin;
                self.m_graphics.demo.pointer_y = button.position.y / scale;
                self.m_graphics.demo.pointerUp();
                publish = true;
            },
            .wheel => |wheel| {
                const scale = self.m_graphics.demo.ui_scale;
                self.m_graphics.demo.scrollWheel(wheel.position.x / scale + origin, wheel.position.y / scale, wheel.delta.x, wheel.delta.y);
                self.a11y_moved = true;
            },
            .text => |text| {
                if (self.m_graphics.demo.insertText(text)) {
                    try self.m_graphics.relayoutDemo();
                    publish = true;
                } else if (self.m_graphics.demo.menuTypeAhead(text)) {
                    try self.m_graphics.relayoutDemo();
                    publish = true;
                }
            },
            .composition => |text| {
                self.m_graphics.demo.setComposition(text.text, text.cursor);
                publish = true;
            },
            .key_down => |key| {
                {
                    const code = key.key;
                    const demo = self.m_graphics.demo;
                    const command = if (builtin.os.tag == .macos) key.modifiers.super else key.modifiers.control;
                    const extend = key.modifiers.shift;
                    const word = key.modifiers.control or (builtin.os.tag == .macos and key.modifiers.alt);
                    const shortcut = switch (code) {
                        .a, .z, .y, .c, .x, .v, .enter => true,
                        else => false,
                    };
                    if (demo.composition_len > 0 and code != .escape and code != .tab) {
                        // The IME owns navigation until its preedit is committed or cancelled.
                    } else if (command and demo.isEditing() and shortcut) {
                        switch (code) {
                            .a => _ = demo.editKey(.select_all, false, false, &self.m_graphics.font),
                            .z => _ = demo.editKey(if (extend) .redo else .undo, false, false, &self.m_graphics.font),
                            .y => _ = demo.editKey(.redo, false, false, &self.m_graphics.font),
                            .c, .x => {
                                if (demo.selectedText()) |selection| {
                                    var buffer: [129]u8 = undefined;
                                    const copied = try std.fmt.bufPrintZ(&buffer, "{s}", .{selection});
                                    try sdl3.clipboard.setText(copied);
                                    if (code == .x) demo.cutSelection();
                                }
                            },
                            .v => {
                                if (sdl3.clipboard.hasText()) {
                                    const copied = try sdl3.clipboard.getText();
                                    defer sdl3.free(copied);
                                    _ = demo.insertText(copied);
                                } else demo.status = "Clipboard has no text.";
                            },
                            .enter => if (demo.focusId() == 300 or demo.focusId() == 301 or demo.focusId() == 302) demo.submitForm(),
                            else => {},
                        }
                    } else if (!key.repeat or code == .tab or demo.isEditing() or (code == .enter and demo.focusRepeats())) switch (code) {
                        // Holding Tab / Shift+Tab keeps moving focus at the keyboard's repeat rate.
                        .tab => demo.next(extend),
                        .f12 => if (!key.repeat) demo.toggleDevtools(),
                        .i => if (!key.repeat and key.modifiers.shift and command) demo.toggleDevtools(),
                        .escape => {
                            if (demo.composition_len > 0) {
                                demo.setComposition("", null);
                            } else {
                                _ = demo.dismiss();
                            }
                        },
                        .left => {
                            const moved = if (builtin.os.tag == .macos and command and demo.isEditing())
                                demo.editKey(.home, extend, false, &self.m_graphics.font)
                            else
                                demo.editKey(.left, extend, word, &self.m_graphics.font);
                            if (!moved and !demo.treeKey(.left) and !demo.moveComposite(-1)) demo.adjustFocused(-1);
                        },
                        .right => {
                            const moved = if (builtin.os.tag == .macos and command and demo.isEditing())
                                demo.editKey(.end, extend, false, &self.m_graphics.font)
                            else
                                demo.editKey(.right, extend, word, &self.m_graphics.font);
                            if (!moved and !demo.treeKey(.right) and !demo.moveComposite(1)) demo.adjustFocused(1);
                        },
                        .up => {
                            if (!demo.treeKey(.up) and !demo.adjustVertical(1, extend) and !demo.menuMove(-1) and !demo.editKey(.up, extend, false, &self.m_graphics.font)) _ = demo.moveComposite(-1);
                        },
                        .down => {
                            if (!demo.treeKey(.down) and !demo.adjustVertical(-1, extend) and !demo.menuMove(1) and !demo.editKey(.down, extend, false, &self.m_graphics.font)) _ = demo.moveComposite(1);
                        },
                        .backspace => {
                            if (word and demo.isEditing()) _ = demo.editKey(.left, true, true, &self.m_graphics.font);
                            if (!demo.editKey(.backspace, false, false, &self.m_graphics.font)) _ = demo.backspace();
                        },
                        .delete => {
                            if (word and demo.isEditing()) _ = demo.editKey(.right, true, true, &self.m_graphics.font);
                            _ = demo.editKey(.delete, false, false, &self.m_graphics.font);
                        },
                        .space => if (!demo.isEditing() and !key.repeat) demo.activate(),
                        .enter => if (demo.composition_len == 0) {
                            if (!demo.confirmMenu()) {
                                if (demo.isEditing()) {
                                    if (demo.focusId() == 301) _ = demo.insertText("\n") else _ = demo.commitEdit();
                                } else if (!key.repeat or demo.focusRepeats()) demo.activate();
                            }
                        },
                        .page_down => if (!demo.dialog_open) demo.scroll.wheel(0, -self.m_graphics.viewport.h / 40),
                        .page_up => if (!demo.dialog_open) demo.scroll.wheel(0, self.m_graphics.viewport.h / 40),
                        .home => {
                            if (!demo.editKey(.home, extend, word, &self.m_graphics.font) and !demo.dialog_open) demo.scroll.offset.y = 0;
                        },
                        .end => {
                            if (!demo.editKey(.end, extend, word, &self.m_graphics.font) and !demo.dialog_open) demo.scroll.offset.y = demo.scroll.content.y;
                        },
                        else => {},
                    };
                    try self.m_graphics.syncSize(self.window);
                    try self.m_graphics.relayoutDemo();
                    publish = true;
                }
            },
        } else switch (curr_event) {
            .quit, .terminating => return .success,
            // Closing a popped-out panel's window docks it back; closing the main window quits.
            .window_close_requested => |w| {
                if (self.m_graphics.windowFor(w.id)) |index| {
                    self.m_graphics.demo.dock.redock(.{ .window = @intCast(index) });
                    publish = true;
                } else return .success;
            },
            .window_resized, .window_pixel_size_changed, .window_display_scale_changed => {
                try self.m_graphics.syncSize(self.window);
                weeoui_sdl3.syncWindowBounds(self.a11y, self.window.window);
                publish = true;
            },
            .window_moved, .window_shown => weeoui_sdl3.syncWindowBounds(self.a11y, self.window.window),
            .system_theme_changed => self.m_graphics.system_theme = weeoui_sdl3.systemTheme(),
            .window_focus_gained => self.a11y.setFocused(true),
            .window_focus_lost => self.a11y.setFocused(false),
            .user => |user| {
                if (user.code == file_event_code) {
                    const result: *FileResult = @ptrCast(@alignCast(user.data1 orelse return error.InvalidFileDialogEvent));
                    defer std.heap.page_allocator.destroy(result);
                    switch (result.status) {
                        .selected => self.m_graphics.demo.selectedFile(result.name[0..result.len]),
                        .cancelled => {
                            self.m_graphics.demo.file_picker_open = false;
                            self.m_graphics.demo.status = "File selection cancelled.";
                        },
                        .failed => {
                            self.m_graphics.demo.file_picker_open = false;
                            self.m_graphics.demo.status = "File picker failed; see stderr.";
                        },
                        .filename_too_long => {
                            self.m_graphics.demo.file_picker_open = false;
                            self.m_graphics.demo.status = "Selected filename exceeds 128 bytes.";
                        },
                    }
                    publish = true;
                }
            },
            else => {},
        }
        // Title bar buttons: minimize and maximize go to the OS; close quits or docks a panel back.
        if (self.m_graphics.demo.window_request) |request| {
            self.m_graphics.demo.window_request = null;
            if (request.slot == 0) {
                if (weeoui_sdl3.windowAction(self.window.window, request.button)) return .success;
            } else if (self.m_graphics.windows[request.slot - 1]) |panel| {
                if (weeoui_sdl3.windowAction(panel.window.window, request.button)) self.m_graphics.demo.dock.redock(.{ .window = request.slot - 1 });
            }
        }
        if (self.m_graphics.demo.file_request) {
            self.m_graphics.demo.file_request = false;
            sdl3.dialog.showOpenFile(anyopaque, fileSelected, null, self.window.window, null, null, false);
        }
        try self.syncTextInput();
        self.a11y_dirty = self.a11y_dirty or publish;
        return .run;
    }

    fn syncTextInput(self: *Game) !void {
        const editing = self.m_graphics.demo.isEditing();
        if (editing == self.text_input_active) return;
        if (editing) try sdl3.keyboard.startTextInput(self.window.window) else try sdl3.keyboard.stopTextInput(self.window.window);
        self.text_input_active = editing;
    }

    pub fn run(self: *Game) !void {
        while (true) {
            while (sdl3.events.poll()) |curr_event| {
                switch (try self.event(curr_event)) {
                    .run => {},
                    .success, .failure => return,
                }
            }
            switch (try self.iterate()) {
                .run => {},
                .success, .failure => return,
            }
        }
    }
};
