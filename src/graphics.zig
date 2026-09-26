const std = @import("std");
const vit = @import("vitellus");
const sdl_adapter = @import("vitellus_sdl3");
const ui = @import("weeoui");
const ui_demo = @import("ui_demo.zig");
const shaders = @import("ui_shaders");
const vert_spv = shaders.vertex;
const frag_spv = shaders.fragment;

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
    vertices: vit.Buffer,
    pipeline_layout: vit.PipelineLayout,
    pipeline: vit.GraphicsPipeline,
    demo: ui_demo.Demo = .{},
    font: ui.Font,
    font_texture: vit.Texture,
    font_view: vit.TextureView,
    font_sampler: vit.Sampler,
    font_layout: vit.BindGroupLayout,
    font_group: vit.BindGroup,
    font_needs_barrier: bool = true,

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
        const vertices = try vit.Buffer.init(device, .{
            .label = "ui vertices",
            .size = max_vertices * @sizeOf(ui.Vertex),
            .usage = .{ .vertex = true },
            .memory = .upload,
        });
        errdefer vertices.deinit();
        var font = try ui.Font.init(allocator, ui.default_font, 32);
        errdefer font.deinit();
        if (viewport.w > 0) font.dpi_scale = @as(f32, @floatFromInt(extent.width)) / viewport.w;
        const font_texture = try vit.Texture.init(device, .{ .label = "ui font", .width = ui.atlas_width, .height = ui.atlas_height, .format = .r8_unorm, .usage = .{ .sampled = true }, .initial_data = font.pixels });
        errdefer font_texture.deinit();
        const font_view = try vit.TextureView.init(device, .{ .texture = font_texture });
        errdefer font_view.deinit();
        const font_sampler = try vit.Sampler.init(device, .{ .address_u = .clamp_to_edge, .address_v = .clamp_to_edge });
        errdefer font_sampler.deinit();
        const font_layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
            .{ .binding = 1, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
        } });
        errdefer font_layout.deinit();
        const font_group = try vit.BindGroup.init(device, .{ .layout = font_layout, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = font_view } },
            .{ .binding = 1, .resource = .{ .sampler = font_sampler } },
        } });
        errdefer font_group.deinit();
        const vs = try vit.Shader.init(device, .{ .label = "ui vert", .stage = .vertex, .source = vit.SPIRVShaderModule.init(.{ .code = vert_spv }) });
        defer vs.deinit();
        const fs = try vit.Shader.init(device, .{ .label = "ui frag", .stage = .fragment, .source = vit.SPIRVShaderModule.init(.{ .code = frag_spv }) });
        defer fs.deinit();
        const pipeline_layout = try vit.PipelineLayout.init(device, .{ .label = "ui layout", .bind_group_layouts = &.{font_layout} });
        errdefer pipeline_layout.deinit();
        const pipeline = try vit.GraphicsPipeline.init(device, .{
            .label = "ui pipeline",
            .vertex = vs,
            .fragment = fs,
            .vertex_buffers = &.{.{ .stride = @sizeOf(ui.Vertex), .attributes = &.{
                .{ .location = 0, .format = .float32x2, .offset = 0 },
                .{ .location = 1, .format = .float32x4, .offset = @offsetOf(ui.Vertex, "color") },
                .{ .location = 2, .format = .float32x2, .offset = @offsetOf(ui.Vertex, "uv") },
            } }},
            .color_targets = &.{.{ .format = colorFormat(caps.formats[0]), .blend = .{ .color = .{ .source = .src_alpha, .destination = .one_minus_src_alpha }, .alpha = .{ .source = .one, .destination = .one_minus_src_alpha } } }},
            .raster = .{ .cull_mode = .none },
            .layout = pipeline_layout,
        });
        errdefer pipeline.deinit();
        var result: @This() = .{ .allocator = allocator, .viewport = viewport, .instance = instance, .adapter = adapter, .device = device, .queue = queue, .swapchain = swapchain, .commands = commands, .color_format = colorFormat(caps.formats[0]), .window_extent = extent, .vertices = vertices, .pipeline_layout = pipeline_layout, .pipeline = pipeline, .font = font, .font_texture = font_texture, .font_view = font_view, .font_sampler = font_sampler, .font_layout = font_layout, .font_group = font_group };
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
        self.pipeline.deinit();
        self.pipeline_layout.deinit();
        self.font_group.deinit();
        self.font_layout.deinit();
        self.font_sampler.deinit();
        self.font_view.deinit();
        self.font_texture.deinit();
        self.font.deinit();
        self.vertices.deinit();
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
        canvas.pixel_scale = .{ @as(f32, @floatFromInt(info.extent.width)) / self.viewport.w, @as(f32, @floatFromInt(info.extent.height)) / self.viewport.h };
        try self.demo.draw(self.allocator, &canvas, self.viewport);
        for (vertex_data[0..canvas.len]) |*vertex| {
            vertex.position[0] = 2 * vertex.position[0] / self.viewport.w - 1;
            vertex.position[1] = 1 - 2 * vertex.position[1] / self.viewport.h;
        }
        const bytes = std.mem.sliceAsBytes(vertex_data[0..canvas.len]);
        const mapped = try self.vertices.map(.write, .{ .size = bytes.len });
        @memcpy(mapped[0..bytes.len], bytes);
        self.vertices.unmap(.{ .size = bytes.len });
        try self.commands.reset();
        const acquired = try self.swapchain.acquireNextImage(null);
        const cmd = try vit.CommandBuffer.init(self.commands, .{});
        defer cmd.deinit();
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .present, .after = .color_attachment } }});
        if (self.font_needs_barrier) {
            try cmd.barrier(&.{.{ .texture = .{ .texture = self.font_texture, .before = .common, .after = .sampled } }});
            self.font_needs_barrier = false;
        }
        try cmd.beginRenderPass(.{ .color_attachments = &.{.{
            .view = acquired.view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0.965, .g = 0.968, .b = 0.973, .a = 1 },
        }} });
        cmd.setGraphicsPipeline(self.pipeline);
        cmd.setBindGroup(0, self.font_group, &.{});
        cmd.setViewport(.{ .width = @floatFromInt(info.extent.width), .height = @floatFromInt(info.extent.height) });
        cmd.setScissor(.{ .width = info.extent.width, .height = info.extent.height });
        cmd.setVertexBuffer(0, self.vertices, 0);
        cmd.draw(@intCast(canvas.len), 1, 0, 0);
        cmd.endRenderPass();
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
