const std = @import("std");
const builtin = @import("builtin");
const vit = @import("vitellus");
const math = @import("eggenvector");

const vert_spv = @embedFile("shaders/cube.vert.spv");
const frag_spv = @embedFile("shaders/cube.frag.spv");

const Vertex = extern struct {
    pos: [3]f32,
    color: [3]f32,
};

const cube_vertices = [_]Vertex{
    .{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.90, 0.22, 0.21 } },
    .{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.18, 0.80, 0.44 } },
    .{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.20, 0.60, 0.86 } },
    .{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.95, 0.77, 0.06 } },
    .{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.61, 0.35, 0.71 } },
    .{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.90, 0.49, 0.13 } },
    .{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.20, 0.29, 0.37 } },
    .{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.93, 0.94, 0.95 } },
};

const cube_indices = [_]u16{
    0, 1, 2, 2, 3, 0,
    4, 5, 6, 6, 7, 4,
    4, 0, 3, 3, 7, 4,
    1, 5, 6, 6, 2, 1,
    3, 2, 6, 6, 7, 3,
    4, 5, 1, 1, 0, 4,
};

pub const Graphics = struct {
    instance: vit.Instance,
    adapter: vit.Adapter,
    device: vit.Device,
    queue: vit.Queue,
    swapchain: vit.Swapchain,
    commands: vit.CommandPool,
    color_format: vit.Format,
    depth: vit.Texture,
    depth_view: vit.TextureView,
    vertices: vit.Buffer,
    indices: vit.Buffer,
    uniforms: vit.Buffer,
    bind_layout: vit.BindGroupLayout,
    bind_group: vit.BindGroup,
    pipeline_layout: vit.PipelineLayout,
    pipeline: vit.GraphicsPipeline,
    angle: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, window: vit.windowing.sdl3.Sdl3Window) !@This() {
        const instance = try vit.Instance.init(allocator, .{
            .backend = .{ .vulkan = true },
            .validation = if (builtin.abi.isAndroid()) .none else .core,
        });
        errdefer instance.deinit();

        const adapter = try vit.Adapter.init(instance, .{ .label = "vitellus adapter" });
        errdefer adapter.deinit();

        const device = try vit.Device.init(adapter, .{ .label = "vitellus device" });
        errdefer device.deinit();

        const queue = try vit.Queue.init(device, .{ .label = "vitellus graphics queue", .kind = .graphics });
        errdefer queue.deinit();

        const commands = try vit.CommandPool.init(device, .{ .kind = .graphics });
        errdefer commands.deinit();

        const caps = try adapter.surfaceCapabilities(instance.allocator, try window.asWindow());
        defer caps.deinit();
        if (caps.formats.len == 0 or caps.present_modes.len == 0 or caps.composite_alpha.len == 0)
            return error.NoSurfaceCapabilities;

        const size = try window.window.getSizeInPixels();
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

        const color_format = colorFormat(caps.formats[0]);
        const depth, const depth_view = try createDepth(device, extent);
        errdefer {
            depth_view.deinit();
            depth.deinit();
        }

        const vertices = try vit.Buffer.init(device, .{
            .label = "cube vertices",
            .size = @sizeOf(@TypeOf(cube_vertices)),
            .usage = .{ .vertex = true },
            .initial_data = std.mem.asBytes(&cube_vertices),
        });
        errdefer vertices.deinit();

        const indices = try vit.Buffer.init(device, .{
            .label = "cube indices",
            .size = @sizeOf(@TypeOf(cube_indices)),
            .usage = .{ .index = true },
            .initial_data = std.mem.asBytes(&cube_indices),
        });
        errdefer indices.deinit();

        const uniforms = try vit.Buffer.init(device, .{
            .label = "cube uniforms",
            .size = 64,
            .usage = .{ .uniform = true },
            .memory = .upload,
        });
        errdefer uniforms.deinit();

        const vs = try vit.Shader.init(device, .{
            .label = "cube vert",
            .stage = .vertex,
            .source = vit.SPIRVShaderModule.init(.{ .code = vert_spv }),
        });
        defer vs.deinit();
        const fs = try vit.Shader.init(device, .{
            .label = "cube frag",
            .stage = .fragment,
            .source = vit.SPIRVShaderModule.init(.{ .code = frag_spv }),
        });
        defer fs.deinit();

        const bind_layout = try vit.BindGroupLayout.init(device, .{
            .label = "cube uniforms",
            .entries = &.{.{
                .binding = 0,
                .kind = .{ .buffer = .{ .kind = .uniform, .min_size = 64 } },
                .visibility = .{ .vertex = true },
            }},
        });
        errdefer bind_layout.deinit();

        const bind_group = try vit.BindGroup.init(device, .{
            .label = "cube uniforms",
            .layout = bind_layout,
            .entries = &.{.{
                .binding = 0,
                .resource = .{ .buffer = .{ .buffer = uniforms, .size = 64 } },
            }},
        });
        errdefer bind_group.deinit();

        const pipeline_layout = try vit.PipelineLayout.init(device, .{
            .label = "cube pipeline layout",
            .bind_group_layouts = &.{bind_layout},
        });
        errdefer pipeline_layout.deinit();

        const pipeline = try vit.GraphicsPipeline.init(device, .{
            .label = "cube pipeline",
            .vertex = vs,
            .fragment = fs,
            .vertex_buffers = &.{.{
                .stride = @sizeOf(Vertex),
                .attributes = &.{
                    .{ .location = 0, .format = .float32x3, .offset = 0 },
                    .{ .location = 1, .format = .float32x3, .offset = @offsetOf(Vertex, "color") },
                },
            }},
            .color_targets = &.{.{ .format = color_format }},
            .depth_stencil = .{ .format = .d32_float },
            .layout = pipeline_layout,
        });

        return .{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .swapchain = swapchain,
            .commands = commands,
            .color_format = color_format,
            .depth = depth,
            .depth_view = depth_view,
            .vertices = vertices,
            .indices = indices,
            .uniforms = uniforms,
            .bind_layout = bind_layout,
            .bind_group = bind_group,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
        };
    }

    pub fn onResize(self: *@This(), window: vit.windowing.sdl3.Sdl3Window) !void {
        const size = try window.window.getSizeInPixels();
        if (size.@"0" == 0 or size.@"1" == 0) return;
        try self.queue.waitIdle();
        const extent = vit.Extent2D{ .width = @intCast(size.@"0"), .height = @intCast(size.@"1") };
        try self.swapchain.resize(extent);
        self.depth_view.deinit();
        self.depth.deinit();
        self.depth, self.depth_view = try createDepth(self.device, extent);
    }

    pub fn deinit(self: *@This()) void {
        self.queue.waitIdle() catch {};
        self.pipeline.deinit();
        self.pipeline_layout.deinit();
        self.bind_group.deinit();
        self.bind_layout.deinit();
        self.uniforms.deinit();
        self.indices.deinit();
        self.vertices.deinit();
        self.depth_view.deinit();
        self.depth.deinit();
        self.swapchain.deinit();
        self.commands.deinit();
        self.queue.deinit();
        self.device.deinit();
        self.adapter.deinit();
        self.instance.deinit();
    }

    pub fn frame(self: *@This(), dt: f32) !void {
        self.angle += dt;
        const info = self.swapchain.info();
        const aspect = if (info.extent.height == 0)
            1
        else
            @as(f32, @floatFromInt(info.extent.width)) / @as(f32, @floatFromInt(info.extent.height));

        const model = math.rotationY4x4(f32, self.angle);
        const tilt = math.rotationX4x4(f32, 0.4);
        const model_tilt = math.multiply4x4(f32, tilt, model);
        const view = math.lookAt(
            math.Vec3.init(1.6, 1.3, 2.2),
            math.Vec3.zero,
            math.Vec3.unit_y,
        );
        const proj = math.perspective(std.math.pi / 4.0, aspect, 0.1, 50.0);
        const mvp = math.multiply4x4(f32, math.multiply4x4(f32, proj, view), model_tilt);

        {
            const mapped = try self.uniforms.map(.write, .{ .size = 64 });
            defer self.uniforms.unmap(.{ .size = 64 });
            @memcpy(mapped[0..64], std.mem.asBytes(&mvp.data));
        }

        try self.commands.reset();
        const acquired = try self.swapchain.acquireNextImage(null);
        const cmd = try vit.CommandBuffer.init(self.commands, .{});
        defer cmd.deinit();

        try cmd.barrier(&.{
            .{ .texture_view = .{ .view = acquired.view, .before = .present, .after = .color_attachment } },
            .{ .texture = .{ .texture = self.depth, .before = .common, .after = .depth_stencil_write } },
        });
        try cmd.beginRenderPass(.{
            .color_attachments = &.{.{
                .view = acquired.view,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.07, .g = 0.08, .b = 0.10, .a = 1 },
            }},
            .depth_stencil_attachment = .{
                .view = self.depth_view,
                .depth_load_op = .clear,
                .depth_store_op = .store,
                .depth_clear = 1,
            },
        });
        cmd.setGraphicsPipeline(self.pipeline);
        cmd.setViewport(.{
            .width = @floatFromInt(info.extent.width),
            .height = @floatFromInt(info.extent.height),
        });
        cmd.setScissor(.{ .width = info.extent.width, .height = info.extent.height });
        cmd.setVertexBuffer(0, self.vertices, 0);
        cmd.setIndexBuffer(self.indices, .uint16, 0);
        cmd.setBindGroup(0, self.bind_group, &.{});
        cmd.drawIndexed(cube_indices.len, 1, 0, 0, 0);
        cmd.endRenderPass();
        try cmd.barrier(&.{.{
            .texture_view = .{ .view = acquired.view, .before = .color_attachment, .after = .present },
        }});
        try cmd.finish();
        try self.queue.submit(.{ .command_buffers = &.{cmd} });
        _ = try self.swapchain.present(&.{});
    }
};

fn createDepth(device: vit.Device, extent: vit.Extent2D) !struct { vit.Texture, vit.TextureView } {
    const depth = try vit.Texture.init(device, .{
        .label = "depth",
        .width = extent.width,
        .height = extent.height,
        .format = .d32_float,
        .usage = .{ .depth_stencil_attachment = true },
    });
    errdefer depth.deinit();
    const depth_view = try vit.TextureView.init(device, .{
        .label = "depth view",
        .texture = depth,
        .aspect = .depth,
    });
    return .{ depth, depth_view };
}

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
