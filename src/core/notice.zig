//! A notice drawn across a whole frame instead of the scene: a line of text, centred on the
//! dark colour the scene's backdrop fades to. The runtime shows "No camera available" with it when the scene has
//! no `Camera` to look through.
const std = @import("std");
const ui = @import("weeoui");
const weeoui_vitellus = @import("weeoui_vitellus");
const Graphics = @import("graphics.zig").Graphics;
const Frame = @import("graphics.zig").Frame;

pub const Notice = struct {
    context: ui.Context,
    renderer: weeoui_vitellus.Renderer,

    /// Allocate a host-owned notice UI/renderer matching `graphics`' target format.
    /// The graphics device must outlive it; UI/GPU creation errors propagate.
    /// Release with `deinit` after the GPU finishes its draws.
    ///
    /// ```zig
    /// var notice = try Notice.init(gpa, &graphics);
    /// defer notice.deinit(); // Finish any GPU use before leaving this host scope.
    /// ```
    pub fn init(gpa: std.mem.Allocator, graphics: *const Graphics) !Notice {
        var context = try ui.Context.init(gpa);
        errdefer context.deinit();
        context.srgb_target = weeoui_vitellus.isSrgb(graphics.color_format);
        const renderer = try weeoui_vitellus.Renderer.init(graphics.device, graphics.color_format, context.font);
        return .{ .context = context, .renderer = renderer };
    }

    /// Free it. The GPU must be done with its frames.
    /// Host teardown: call once before destroying the graphics device.
    ///
    /// ```zig
    /// try graphics.queue.waitIdle();
    /// notice.deinit();
    /// ```
    pub fn deinit(self: *Notice) void {
        self.renderer.deinit();
        self.context.deinit();
    }

    /// Clear `frame` and draw `text` in its middle. Call outside a render pass.
    /// Host fallback rendering: borrows `text` for this call, records into the active frame,
    /// and replaces its contents. UI allocation/upload/render errors propagate.
    ///
    /// ```zig
    /// const frame = try graphics.beginFrame();
    /// try notice.draw(frame, "No camera available");
    /// try graphics.endFrame(frame);
    /// ```
    pub fn draw(self: *Notice, frame: Frame, text: []const u8) !void {
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = @floatFromInt(frame.extent.width), .h = @floatFromInt(frame.extent.height) };
        self.context.newFrame(viewport);
        const b = self.context.builder();
        const page = try b.node(0, .{ .width = viewport.w, .height = viewport.h, .align_items = .center, .justify = .center }, .none, &.{
            try b.node(0, .{ .width = viewport.w }, .{ .text = .{ .value = text, .size = 20, .tone = .muted, .alignment = .center } }, &.{}),
        });
        self.context.element(page);
        const vertices = try self.context.render();

        try self.renderer.upload(frame.cmd, self.context.font, vertices, viewport);
        try frame.cmd.beginRenderPass(.{ .label = "notice", .color_attachments = &.{.{ .view = frame.target, .load_op = .clear, .store_op = .store, .clear_value = if (self.context.srgb_target) .{ .r = 0.001, .g = 0.002, .b = 0.006, .a = 1 } else .{ .r = 0.02, .g = 0.03, .b = 0.06, .a = 1 } }} });
        self.renderer.draw(frame.cmd, frame.extent, 0, vertices.len);
        frame.cmd.endRenderPass();
    }
};
