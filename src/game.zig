const std = @import("std");
const sdl_adapter = @import("vitellus_sdl3");
const sdl3 = sdl_adapter.sdl;

const graphics = @import("graphics.zig");
const accessibility = @import("accessibility.zig");
const builtin = @import("builtin");

const fps = 60;
const width = 900;
const height = 675;
const FileResult = struct {
    const Status = enum { selected, cancelled, failed, filename_too_long };
    status: Status,
    name: [128]u8 = undefined,
    len: usize = 0,
};
const FileRequest = struct { event_type: @FieldType(sdl3.events.User, "event_type") };

fn fileSelected(request: ?*FileRequest, files: ?[]const [*:0]const u8, _: ?usize, failed: bool) void {
    const data = request orelse {
        std.log.err("Missing file dialog callback context", .{});
        return;
    };
    defer std.heap.page_allocator.destroy(data);
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
        .event_type = data.event_type,
        .code = 0,
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
    a11y: *accessibility.Bridge,
    file_event_type: @FieldType(sdl3.events.User, "event_type"),
    text_input_active: bool = false,
    a11y_dirty: bool = false,
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
        const a11y = try accessibility.Bridge.init(i.gpa, window, &m_graphics.demo, m_graphics.viewport, &m_graphics.font);
        errdefer a11y.deinit();
        const file_event_type = sdl3.events.register(1) orelse return error.NoFileDialogEvent;
        if (builtin.os.tag == .windows) try window.window.show();

        return .{
            .window = window,
            .init_flags = init_flags,
            .m_graphics = m_graphics,
            .a11y = a11y,
            .file_event_type = file_event_type,
            .fps_capper = .{ .mode = .{ .limited = fps } },
        };
    }

    pub fn deinit(self: *Game) void {
        if (self.text_input_active) sdl3.keyboard.stopTextInput(self.window.window) catch |err| std.log.err("Cannot stop text input: {s}", .{@errorName(err)});
        self.a11y.deinit();
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
        if (self.a11y_dirty) {
            try self.a11y.publish(&self.m_graphics.demo, self.m_graphics.viewport, &self.m_graphics.font);
            self.a11y_dirty = false;
        }
        try self.m_graphics.frame();
        return .run;
    }

    pub fn event(self: *Game, curr_event: sdl3.events.Event) !sdl3.AppResult {
        var publish = false;
        switch (curr_event) {
            .quit, .terminating => return .success,
            .window_resized, .window_pixel_size_changed, .window_display_scale_changed => {
                try self.m_graphics.syncSize(self.window);
                try self.a11y.windowBounds(self.window);
                publish = true;
            },
            .window_moved, .window_shown => try self.a11y.windowBounds(self.window),
            .window_focus_gained => self.a11y.windowFocus(true),
            .window_focus_lost => self.a11y.windowFocus(false),
            .mouse_motion => |motion| {
                const scale = self.m_graphics.demo.ui_scale;
                const old_hover = .{ self.m_graphics.demo.hover_card_open, self.m_graphics.demo.tooltip_open };
                self.m_graphics.demo.pointerMoveAt(motion.x / scale, motion.y / scale, &self.m_graphics.font);
                if (self.m_graphics.demo.dragging_slider) {
                    try self.m_graphics.syncSize(self.window);
                    publish = true;
                } else if (self.m_graphics.demo.scroll.dragging != .none or self.m_graphics.demo.dragging_divider or self.m_graphics.demo.dragging_text or old_hover[0] != self.m_graphics.demo.hover_card_open or old_hover[1] != self.m_graphics.demo.tooltip_open) {
                    if (old_hover[0] != self.m_graphics.demo.hover_card_open or old_hover[1] != self.m_graphics.demo.tooltip_open) try self.m_graphics.relayoutDemo();
                    publish = true;
                }
            },
            .mouse_button_down => |button| {
                if (button.button == .left) {
                    const scale = self.m_graphics.demo.ui_scale;
                    self.m_graphics.demo.pointerDownAt(button.x / scale, button.y / scale, &self.m_graphics.font);
                    try self.m_graphics.syncSize(self.window);
                    try self.m_graphics.relayoutDemo();
                    publish = true;
                } else if (button.button == .right) {
                    const scale = self.m_graphics.demo.ui_scale;
                    self.m_graphics.demo.pointerContextDown(button.x / scale, button.y / scale);
                    try self.m_graphics.relayoutDemo();
                    publish = true;
                }
            },
            .mouse_button_up => |button| if (button.button == .left) self.m_graphics.demo.pointerUp(),
            .mouse_wheel => |wheel| {
                const scale = self.m_graphics.demo.ui_scale;
                self.m_graphics.demo.scrollWheel(wheel.x / scale, wheel.y / scale, wheel.scroll_x, wheel.scroll_y);
                publish = true;
            },
            .text_input => |text| {
                if (self.m_graphics.demo.insertText(text.text)) {
                    try self.m_graphics.relayoutDemo();
                    publish = true;
                } else if (self.m_graphics.demo.menuTypeAhead(text.text)) {
                    try self.m_graphics.relayoutDemo();
                    publish = true;
                }
            },
            .text_editing => |text| {
                self.m_graphics.demo.setComposition(text.text, text.start);
                publish = true;
            },
            .key_down => |key| {
                if (key.key) |code| {
                    const demo = &self.m_graphics.demo;
                    const command = if (builtin.os.tag == .macos) key.mod.guiDown() else key.mod.controlDown();
                    const extend = key.mod.shiftDown();
                    const word = key.mod.controlDown() or (builtin.os.tag == .macos and key.mod.altDown());
                    const shortcut = switch (code) {
                        .a, .z, .y, .c, .x, .v, .return_key, .kp_enter => true,
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
                            .return_key, .kp_enter => if (demo.focusId() == 300 or demo.focusId() == 301 or demo.focusId() == 302) demo.submitForm(),
                            else => {},
                        }
                    } else if (!key.repeat or demo.isEditing()) switch (code) {
                        .tab => if (!key.repeat) demo.next(extend),
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
                            if (!moved and !demo.moveComposite(-1)) demo.adjustFocused(-1);
                        },
                        .right => {
                            const moved = if (builtin.os.tag == .macos and command and demo.isEditing())
                                demo.editKey(.end, extend, false, &self.m_graphics.font)
                            else
                                demo.editKey(.right, extend, word, &self.m_graphics.font);
                            if (!moved and !demo.moveComposite(1)) demo.adjustFocused(1);
                        },
                        .up => {
                            if (!demo.menuMove(-1) and !demo.editKey(.up, extend, false, &self.m_graphics.font)) _ = demo.moveComposite(-1);
                        },
                        .down => {
                            if (!demo.menuMove(1) and !demo.editKey(.down, extend, false, &self.m_graphics.font)) _ = demo.moveComposite(1);
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
                        .return_key, .kp_enter => if (demo.composition_len == 0) {
                            if (!demo.confirmMenu()) {
                                if (demo.isEditing()) {
                                    if (demo.focusId() == 301) _ = demo.insertText("\n");
                                } else if (!key.repeat) demo.activate();
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
            .user => |user| {
                if (user.event_type == self.file_event_type) {
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
                } else if (self.a11y.event(user, &self.m_graphics.demo)) {
                    try self.m_graphics.syncSize(self.window);
                    publish = true;
                }
            },
            else => {},
        }
        if (self.m_graphics.demo.file_request) {
            self.m_graphics.demo.file_request = false;
            const request = try std.heap.page_allocator.create(FileRequest);
            request.* = .{ .event_type = self.file_event_type };
            sdl3.dialog.showOpenFile(FileRequest, fileSelected, request, self.window.window, null, null, false);
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
