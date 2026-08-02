const std = @import("std");
const sdl3 = @import("sdl3");
const vit = @import("vitellus");
const zigimg = @import("zigimg");
const emath = @import("eggenvector");
const camera = @import("camera.zig");

const slangc = @import("shaders/slangc.zig");

const width = 1280;
const height = 720;

const Vertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
};

const SceneUniform = extern struct {
    model: [4][4]f32,
    view: [4][4]f32,
    proj: [4][4]f32,
};

const vertices = [_]Vertex{
    .{ .position = .{ -0.6, 0.6 }, .uv = .{ 0, 0 } },
    .{ .position = .{ 0.6, 0.6 }, .uv = .{ 1, 0 } },
    .{ .position = .{ 0.6, -0.6 }, .uv = .{ 1, 1 } },
    .{ .position = .{ -0.6, -0.6 }, .uv = .{ 0, 1 } },
};

const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };

const triangle_slang_code = @embedFile("shaders/triangle.slang");

pub fn main(init: std.process.Init) !void {
    defer sdl3.shutdown();

    const init_flags = sdl3.InitFlags{ .video = true };
    try sdl3.init(init_flags);
    defer sdl3.quit(init_flags);

    const window = try sdl3.video.Window.init("eggyengine", width, height, .{
        .resizable = true,
        .maximized = true,
    });
    defer window.deinit();

    const window_adapter = vit.windowing.sdl3.Sdl3Window.init(window);

    const instance = try vit.Instance.init(init.gpa, .{
        .backend = .all(),
        .validation = .core,
    });
    defer instance.deinit();

    const adapter = try vit.Adapter.init(instance, .{ .label = "vitellus adapter" });
    defer adapter.deinit();

    const device = try vit.Device.init(adapter, .{ .label = "vitellus device" });
    defer device.deinit();

    const queue = try vit.Queue.init(device, .{ .label = "vitellus graphics queue", .kind = .graphics });
    defer queue.deinit();

    const caps = try adapter.surfaceCapabilities(instance.allocator, try window_adapter.asWindow());
    defer caps.deinit();
    printStartupInfo(adapter.info(), instance.backend(), caps);

    const swapchain = try vit.Swapchain.init(adapter, .{
        .label = "vitellus swapchain",
        .window = try window_adapter.asWindow(),
        .queue = queue,
        .extent = .{ .width = width, .height = height },
        .format = caps.formats[0],
        .present_mode = caps.present_modes[0],
        .image_count = 2,
        .composite_alpha = caps.composite_alpha[0],
    });
    defer swapchain.deinit();

    const vertex_shader = try vit.Shader.init(device, .{
        .label = "triangle vertex shader",
        .stage = .vertex,
        .source = slangc.SlangShaderModule.init(.{ .code = triangle_slang_code, .entry_point = "vsMain" }),
    });
    defer vertex_shader.deinit();

    const fragment_shader = try vit.Shader.init(device, .{
        .label = "triangle fragment shader",
        .stage = .fragment,
        // .source = vit.SPIRVShaderModule.init(.{
        //     .code = @embedFile("shaders/compiled/triangle.psMain.spv"),
        //     .entry_point = "psMain",
        // }),
        .source = slangc.SlangShaderModule.init(.{ .code = triangle_slang_code, .entry_point = "psMain" }),
    });

    defer fragment_shader.deinit();

    const vertex_buffer = try vit.Buffer.init(device, .{
        .label = "quad vertices",
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .vertex = true },
        .initial_data = std.mem.asBytes(&vertices),
    });
    defer vertex_buffer.deinit();

    const index_buffer = try vit.Buffer.init(device, .{
        .label = "quad indices",
        .size = @sizeOf(@TypeOf(indices)),
        .usage = .{ .index = true },
        .initial_data = std.mem.asBytes(&indices),
    });
    defer index_buffer.deinit();

    const camera_buffer = try vit.Buffer.init(device, .{
        .label = "camera uniform buffer",
        .size = 256,
        .usage = .{
            .uniform = true,
        },
        .memory = .upload,
    });
    defer camera_buffer.deinit();

    const layout = try vit.BindGroupLayout.init(device, .{
        .label = "scene layout",
        .entries = &.{
            .{
                .binding = 0,
                .kind = .{
                    .buffer = .{
                        .kind = .uniform,
                        .min_size = @sizeOf(SceneUniform),
                    },
                },
                .visibility = .{ .vertex = true },
            },
        },
    });
    defer layout.deinit();

    const group = try vit.BindGroup.init(device, .{
        .layout = layout,
        .entries = &.{
            .{
                .binding = 0,
                .resource = .{
                    .buffer = .{
                        .buffer = camera_buffer,
                        .size = 256,
                    },
                },
            },
        },
    });
    defer group.deinit();

    const vertex_attributes = [_]vit.hal.pipeline.VertexAttribute{
        .{ .location = 0, .format = .float32x2, .offset = @offsetOf(Vertex, "position") },
        .{ .location = 1, .format = .float32x2, .offset = @offsetOf(Vertex, "uv") },
    };
    const vertex_layouts = [_]vit.hal.pipeline.VertexBufferLayout{.{
        .stride = @sizeOf(Vertex),
        .attributes = &vertex_attributes,
    }};
    const color_targets = [_]vit.hal.pipeline.ColorTargetState{
        .{ .format = .bgra8_unorm },
    };
    const pipeline_layout = try vit.PipelineLayout.init(device, .{ .bind_group_layouts = &.{layout} });
    defer pipeline_layout.deinit();
    const pipeline = try vit.GraphicsPipeline.init(device, .{
        .label = "indexed quad pipeline",
        .vertex = vertex_shader,
        .fragment = fragment_shader,
        .vertex_buffers = &vertex_layouts,
        .topology = .triangle_list,
        .raster = .{ .cull_mode = .none },
        .color_targets = &color_targets,
        .layout = pipeline_layout,
    });
    defer pipeline.deinit();

    const command_pool = try vit.CommandPool.init(device, .{
        .label = "vitellus command pool",
        .transient = false,
        .reset_individually = true,
    });
    defer command_pool.deinit();
    const frame_fence = try vit.Fence.init(device, .{ .label = "vitellus frame fence" });
    defer frame_fence.deinit();
    var frame_value: u64 = 0;

    const setup_commands = try vit.CommandBuffer.init(command_pool, .{ .label = "vitellus setup commands" });
    try setup_commands.barrier(&.{
        .{ .buffer = .{ .buffer = vertex_buffer, .before = .common, .after = .vertex } },
        .{ .buffer = .{ .buffer = index_buffer, .before = .common, .after = .index } },
    });
    try setup_commands.finish();
    try queue.submit(.{ .command_buffers = &.{setup_commands} });
    try queue.waitIdle();
    setup_commands.deinit();

    var cam = camera.Camera.init(.{ .x = 0, .y = 0, .z = 3 });
    try sdl3.mouse.setWindowRelativeMode(window, true);

    var last_time_ns = sdl3.timer.getNanosecondsSinceInit();
    var quit = false;
    while (!quit) {
        const now_ns = sdl3.timer.getNanosecondsSinceInit();
        const dt: f32 = @as(f32, @floatFromInt(now_ns -% last_time_ns)) / 1_000_000_000.0;
        last_time_ns = now_ns;

        while (sdl3.events.poll()) |event| switch (event) {
            .quit, .terminating => quit = true,
            .mouse_wheel => |wheel| cam.processMouseScroll(wheel.scroll_y),
            else => {},
        };
        if (processInput(&cam, dt)) quit = true;
        if (quit) break;

        const scene_uniform = SceneUniform{
            .model = emath.identity(f32, 4).data,
            .view = cam.getViewMatrix().data,
            .proj = cam.getProjectionMatrix(
                @as(f32, width) / @as(f32, height),
                0.1,
                100.0,
            ).data,
        };

        const camera_bytes = std.mem.asBytes(&scene_uniform);
        const mapped = try camera_buffer.map(.write, .{
            .offset = 0,
            .size = camera_bytes.len,
        });
        @memcpy(mapped, camera_bytes);
        camera_buffer.unmap(.{
            .offset = 0,
            .size = camera_bytes.len,
        });

        const acquired = try swapchain.acquireNextImage(null);
        const back_buffer = acquired.view;
        const commands = try vit.CommandBuffer.init(command_pool, .{ .label = "vitellus frame commands" });
        try commands.barrier(&.{.{ .texture_view = .{ .view = back_buffer, .before = .present, .after = .color_attachment } }});

        const color_attachments = [_]vit.hal.command.ColorAttachment{.{
            .view = back_buffer,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0.025, .g = 0.035, .b = 0.055, .a = 1.0 },
        }};

        try commands.beginRenderPass(.{
            .label = "triangle render pass",
            .color_attachments = &color_attachments,
        });
        commands.setGraphicsPipeline(pipeline);
        commands.setVertexBuffer(0, vertex_buffer, 0);
        commands.setIndexBuffer(index_buffer, .uint16, 0);
        commands.setBindGroup(0, group, &.{});
        commands.drawIndexed(@intCast(indices.len), 1, 0, 0, 0);
        commands.endRenderPass();
        try commands.barrier(&.{.{ .texture_view = .{ .view = back_buffer, .before = .color_attachment, .after = .present } }});
        try commands.finish();

        const command_buffers = [_]vit.CommandBuffer{commands};
        frame_value += 1;
        try queue.submit(.{ .command_buffers = &command_buffers, .signal_fences = &.{.{ .fence = frame_fence, .value = frame_value }} });
        _ = try swapchain.present(&.{});
        _ = try frame_fence.wait(frame_value, null);
        commands.deinit();
    }

    try queue.waitIdle();
}

fn processInput(cam: *camera.Camera, delta_time: f32) bool {
    const keys = sdl3.keyboard.getState();
    if (keys[@intFromEnum(sdl3.Scancode.escape)]) return true;

    if (keys[@intFromEnum(sdl3.Scancode.w)]) cam.processKeyboard(.forward, delta_time);
    if (keys[@intFromEnum(sdl3.Scancode.s)]) cam.processKeyboard(.backward, delta_time);
    if (keys[@intFromEnum(sdl3.Scancode.a)]) cam.processKeyboard(.left, delta_time);
    if (keys[@intFromEnum(sdl3.Scancode.d)]) cam.processKeyboard(.right, delta_time);
    if (keys[@intFromEnum(sdl3.Scancode.space)]) cam.processKeyboard(.up, delta_time);
    if (keys[@intFromEnum(sdl3.Scancode.left_ctrl)]) cam.processKeyboard(.down, delta_time);

    const mouse_state = sdl3.mouse.getRelativeState();
    const x_rel = mouse_state[1];
    const y_rel = mouse_state[2];
    if (x_rel != 0 or y_rel != 0) {
        cam.processMouseMovement(x_rel, -y_rel, true);
    }

    return false;
}

fn printStartupInfo(info: vit.AdapterInfo, backend: vit.Backend, caps: vit.hal.adapter.SurfaceCapabilities) void {
    std.debug.print(
        \\================
        \\eggyengine; built with love <3
        \\================
        \\
        \\info:
        \\  name: {s}
        \\  vendor: {s}
        \\  kind: {s}
        \\  dedicated VRAM: {} MiB ({} bytes)
        \\  backend: {s}
        \\surface capabilities:
        \\  image count: {}..
    , .{
        info.nameSlice(),
        @tagName(info.vendor),
        @tagName(info.kind),
        info.dedicated_vram / (1024 * 1024),
        info.dedicated_vram,
        backend.name(),
        caps.min_image_count,
    });
    if (caps.max_image_count == 0) {
        std.debug.print("unbounded\n", .{});
    } else {
        std.debug.print("{}\n", .{caps.max_image_count});
    }
    std.debug.print(
        \\  extent: {}x{}..{}x{}
        \\  formats: 
    , .{
        caps.min_extent.width,
        caps.min_extent.height,
        caps.max_extent.width,
        caps.max_extent.height,
    });
    printEnumList(caps.formats);
    std.debug.print("  present modes: ", .{});
    printEnumList(caps.present_modes);
    std.debug.print("  composite alpha: ", .{});
    printEnumList(caps.composite_alpha);
    std.debug.print("\n", .{});
}

fn printEnumList(values: anytype) void {
    if (values.len == 0) {
        std.debug.print("(none)\n", .{});
        return;
    }

    for (values, 0..) |value, index| {
        std.debug.print("{s}{s}", .{ if (index == 0) "" else ", ", @tagName(value) });
    }
    std.debug.print("\n", .{});
}

test {
    _ = @import("camera.zig");
    _ = slangc;
}
