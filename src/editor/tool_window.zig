//! A small OS window of the editor's own, such as the New Project wizard or its loading screen:
//! one page of Weeoui UI, drawn with the editor's font.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const PopOut = @import("popout.zig").PopOut;
const icon = @import("icon.zig");

pub const ToolWindow = struct {
    popout: PopOut,
    ui: ui.Context,
    /// Whether SDL is sending text input, which it does while a text field is focused.
    text_input: bool = false,

    /// Open a `size` window titled `title`, drawing with `font` (the editor's, which must outlive it).
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, title: [:0]const u8, size: [2]f32, flags: sdl3.video.Window.Flags) !ToolWindow {
        const popout = try PopOut.open(graphics, font, title, size, flags);
        icon.apply(popout.window.window);
        var context = ui.Context.initWithFont(gpa, font);
        context.density = .compact;
        return .{ .popout = popout, .ui = context };
    }

    pub fn close(self: *ToolWindow, graphics: *eggy.Graphics) void {
        self.popout.close(graphics);
        self.ui.deinit();
    }

    /// Whether `curr_event` is for this window.
    pub fn owns(self: *const ToolWindow, curr_event: sdl3.events.Event) bool {
        const id: ?sdl3.video.WindowId = switch (curr_event) {
            inline else => |payload| blk: {
                const T = @TypeOf(payload);
                if (T == sdl3.events.Window) break :blk payload.id;
                if (@typeInfo(T) == .@"struct" and @hasField(T, "window_id")) {
                    const window_id: ?sdl3.video.WindowId = payload.window_id;
                    break :blk window_id;
                }
                break :blk null;
            },
        };
        return id == self.popout.id;
    }

    /// Feed one of this window's events to its page.
    pub fn handle(self: *ToolWindow, curr_event: sdl3.events.Event) void {
        if (weeoui_sdl3.translate(curr_event)) |input| self.ui.handle(input);
    }

    /// Draw a frame: `page.build(&context)` describes the page, styled like `style` (the editor's
    /// own UI). Does nothing while the window is minimized.
    pub fn present(self: *ToolWindow, graphics: *eggy.Graphics, style: *const ui.Context, page: anytype) !void {
        const viewport = try self.popout.viewport() orelse return;
        const window = self.popout.window;
        try self.popout.surface.syncSize(graphics.queue, window);

        // Build the page at the window's pixel density, in the editor's theme.
        const pixel_width, const pixel_height = try window.window.getSizeInPixels();
        self.ui.theme = style.theme;
        self.ui.srgb_target = style.srgb_target;
        self.ui.pixel_scale = .{ @as(f32, @floatFromInt(pixel_width)) / viewport.w, @as(f32, @floatFromInt(pixel_height)) / viewport.h };
        self.ui.time_ms = sdl3.timer.getMillisecondsSinceInit();
        self.ui.newFrame(viewport);
        page.build(&self.ui);
        const vertices = try self.ui.render();

        // Text fields need SDL's text input while focused.
        if (self.ui.wants_text != self.text_input) {
            (if (self.ui.wants_text) sdl3.keyboard.startTextInput(window.window) else sdl3.keyboard.stopTextInput(window.window)) catch {};
            self.text_input = self.ui.wants_text;
        }

        // Clear to the theme's background, then draw the page.
        const frame = try self.popout.surface.beginFrame();
        try self.popout.overlay.upload(frame.cmd, self.ui.font, vertices, viewport);
        const background = self.ui.theme.background;
        const channel = struct {
            fn f(srgb: bool, value: f32) f32 {
                return if (srgb) ui.linearChannel(value) else value;
            }
        }.f;
        try frame.cmd.beginRenderPass(.{ .label = "tool window", .color_attachments = &.{.{
            .view = frame.target,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = channel(self.ui.srgb_target, background[0]), .g = channel(self.ui.srgb_target, background[1]), .b = channel(self.ui.srgb_target, background[2]), .a = 1 },
        }} });
        self.popout.overlay.draw(frame.cmd, frame.extent, 0, vertices.len);
        frame.cmd.endRenderPass();
        try self.popout.surface.endFrame(graphics.queue, frame);
    }
};
