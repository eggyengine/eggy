const std = @import("std");
const vit = @import("vitellus");
const sdl_adapter = @import("vitellus_sdl3");
const ui = @import("weeoui");
const ui_demo = @import("ui_demo.zig");
const viewport3d = @import("viewport3d.zig");
const weeoui_vitellus = @import("weeoui_vitellus");

const max_vertices = 30000;
pub const Graphics = struct {
    allocator: std.mem.Allocator,
    viewport: ui.Rect,
    instance: vit.Instance,
    adapter: vit.Adapter,
    device: vit.Device,
    queue: vit.Queue,
    swapchain: vit.Swapchain,
    commands: vit.CommandPool,
    color_format: vit.Format,
    window_extent: vit.Extent2D,
    ui_renderer: weeoui_vitellus.Renderer,
    preview: viewport3d.Preview,
    theme: ui.Theme = .{},
    demo: ui_demo.Demo = .{},
    font: ui.Font,

    pub fn init(allocator: std.mem.Allocator, window: sdl_adapter.Sdl3Window) !@This() {
        const instance = try vit.Instance.init(allocator, .{ .backend = .{ .vulkan = true }, .validation = .core });
        errdefer instance.deinit();
        const adapter = try vit.Adapter.init(instance, .{ .label = "vitellus adapter" });
        errdefer adapter.deinit();
        const device = try vit.Device.init(adapter, .{ .label = "vitellus device" });
        errdefer device.deinit();
        const queue = try vit.Queue.init(device, .{ .label = "graphics queue", .kind = .graphics });
        errdefer queue.deinit();
        const commands = try vit.CommandPool.init(device, .{ .kind = .graphics });
        errdefer commands.deinit();
        const caps = try adapter.surfaceCapabilities(instance.allocator, try window.asWindow());
        defer caps.deinit();
        if (caps.formats.len == 0 or caps.present_modes.len == 0 or caps.composite_alpha.len == 0) return error.NoSurfaceCapabilities;
        const size = try window.window.getSizeInPixels();
        const logical = try window.window.getSize();
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = @floatFromInt(logical.@"0"), .h = @floatFromInt(logical.@"1") };
        const extent = vit.Extent2D{ .width = @intCast(size.@"0"), .height = @intCast(size.@"1") };
        const swapchain = try vit.Swapchain.init(adapter, .{
            .label = "swapchain",
            .window = try window.asWindow(),
            .queue = queue,
            .extent = extent,
            .format = caps.formats[0],
            .present_mode = pickPresentMode(caps.present_modes),
            .image_count = 2,
            .composite_alpha = caps.composite_alpha[0],
        });
        errdefer swapchain.deinit();
        var font = try ui.Font.init(allocator, ui.default_font, 32);
        errdefer font.deinit();
        if (viewport.w > 0) font.dpi_scale = @as(f32, @floatFromInt(extent.width)) / viewport.w;
        var ui_renderer = try weeoui_vitellus.Renderer.init(device, colorFormat(caps.formats[0]), &font);
        errdefer ui_renderer.deinit();
        var preview = try viewport3d.Preview.init(device, colorFormat(caps.formats[0]), extent);
        errdefer preview.deinit();
        var result: @This() = .{ .allocator = allocator, .viewport = viewport, .instance = instance, .adapter = adapter, .device = device, .queue = queue, .swapchain = swapchain, .commands = commands, .color_format = colorFormat(caps.formats[0]), .window_extent = extent, .ui_renderer = ui_renderer, .preview = preview, .font = font };
        try result.demo.relayout(allocator, viewport, &result.font);
        return result;
    }

    pub fn syncSize(self: *@This(), window: sdl_adapter.Sdl3Window) !void {
        const pixels = try window.window.getSizeInPixels();
        const logical = try window.window.getSize();
        if (pixels.@"0" == 0 or pixels.@"1" == 0 or logical.@"0" == 0 or logical.@"1" == 0) return;
        const requested = vit.Extent2D{ .width = @intCast(pixels.@"0"), .height = @intCast(pixels.@"1") };
        if (requested.width != self.window_extent.width or requested.height != self.window_extent.height) {
            try self.queue.waitIdle();
            try self.preview.resize(self.device, requested);
            try self.swapchain.resize(requested);
            self.window_extent = requested;
        }
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = @as(f32, @floatFromInt(logical.@"0")) / self.demo.ui_scale, .h = @as(f32, @floatFromInt(logical.@"1")) / self.demo.ui_scale };
        const dpi_scale = @as(f32, @floatFromInt(requested.width)) / viewport.w;
        if (viewport.w != self.viewport.w or viewport.h != self.viewport.h or dpi_scale != self.font.dpi_scale) {
            self.viewport = viewport;
            self.font.dpi_scale = dpi_scale;
            try self.relayoutDemo();
            self.demo.scroll.ensureVisible(self.demo.controls[self.demo.focus]);
            try self.relayoutDemo();
        }
    }

    pub fn relayoutDemo(self: *@This()) !void {
        try self.demo.relayout(self.allocator, self.viewport, &self.font);
    }

    pub fn deinit(self: *@This()) void {
        self.queue.waitIdle() catch {};
        self.preview.deinit();
        self.ui_renderer.deinit();
        self.font.deinit();
        self.swapchain.deinit();
        self.commands.deinit();
        self.queue.deinit();
        self.device.deinit();
        self.adapter.deinit();
        self.instance.deinit();
    }

    pub fn frame(self: *@This()) !void {
        const info = self.swapchain.info();
        var vertex_data: [max_vertices]ui.Vertex = undefined;
        var canvas = ui.Canvas.init(&vertex_data, &self.font);
        canvas.theme = self.theme;
        canvas.srgb_target = weeoui_vitellus.isSrgb(self.color_format);
        canvas.pixel_scale = .{ @as(f32, @floatFromInt(info.extent.width)) / self.viewport.w, @as(f32, @floatFromInt(info.extent.height)) / self.viewport.h };
        const base_vertices = try self.demo.draw(self.allocator, &canvas, self.viewport);
        try self.commands.reset();
        const acquired = try self.swapchain.acquireNextImage(null);
        const cmd = try vit.CommandBuffer.init(self.commands, .{});
        defer cmd.deinit();
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .present, .after = .color_attachment } }});
        try self.ui_renderer.upload(cmd, vertex_data[0..canvas.len], self.viewport);
        try cmd.beginRenderPass(.{ .color_attachments = &.{.{
            .view = acquired.view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{
                .r = if (canvas.srgb_target) ui.linearChannel(self.theme.background[0]) else self.theme.background[0],
                .g = if (canvas.srgb_target) ui.linearChannel(self.theme.background[1]) else self.theme.background[1],
                .b = if (canvas.srgb_target) ui.linearChannel(self.theme.background[2]) else self.theme.background[2],
                .a = 1,
            },
        }} });
        self.ui_renderer.draw(cmd, info.extent, 0, base_vertices);
        cmd.endRenderPass();
        try self.preview.draw(cmd, acquired.view, self.demo.scene_viewport, self.demo.scene_clip, self.viewport, info.extent, canvas.srgb_target);
        if (canvas.len > base_vertices) {
            try cmd.beginRenderPass(.{ .color_attachments = &.{.{ .view = acquired.view, .load_op = .load, .store_op = .store }} });
            self.ui_renderer.draw(cmd, info.extent, base_vertices, canvas.len - base_vertices);
            cmd.endRenderPass();
        }
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .color_attachment, .after = .present } }});
        try cmd.finish();
        try self.queue.submit(.{ .command_buffers = &.{cmd} });
        _ = try self.swapchain.present(&.{});
    }
};

fn colorFormat(format: vit.SwapchainFormat) vit.Format {
    return switch (format) {
        .bgra8_unorm => .bgra8_unorm,
        .bgra8_unorm_srgb => .bgra8_unorm_srgb,
        .rgba8_unorm => .rgba8_unorm,
        .rgba8_unorm_srgb => .rgba8_unorm_srgb,
        .rgba16_float => .rgba16_float,
    };
}
fn pickPresentMode(modes: []const vit.PresentMode) vit.PresentMode {
    for (modes) |mode| if (mode == .mailbox) return mode;
    for (modes) |mode| if (mode == .immediate) return mode;
    return modes[0];
}
