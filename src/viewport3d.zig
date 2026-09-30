const std = @import("std");
const vit = @import("vitellus");
const ui = @import("weeoui");
const sdl3 = @import("sdl3");
const shaders = @import("ui_shaders");
const frames_in_flight = @import("weeoui_vitellus").frames_in_flight;

const Vertex = extern struct {
    position: [3]f32,
    color: [3]f32,
    kind: f32 = 0,
};

const SceneUniforms = extern struct {
    rotation: [4]f32,
    screen: [4]f32,
    projection: [4]f32,
};

const vertex_data = sceneVertices();

pub const Preview = struct {
    geometry: vit.Buffer,
    /// One per frame in flight, so `draw` never rewrites a transform the GPU is still reading.
    uniforms: [frames_in_flight]vit.Buffer,
    group_layout: vit.BindGroupLayout,
    groups: [frames_in_flight]vit.BindGroup,
    slot: usize = 0,
    pipeline_layout: vit.PipelineLayout,
    pipeline: vit.GraphicsPipeline,
    depth: vit.Texture,
    depth_view: vit.TextureView,
    depth_initialized: bool = false,

    pub fn init(device: vit.Device, format: vit.Format, extent: vit.Extent2D) !Preview {
        const geometry = try vit.Buffer.init(device, .{
            .label = "preview cube",
            .size = @sizeOf(@TypeOf(vertex_data)),
            .usage = .{ .vertex = true },
            .initial_data = std.mem.asBytes(&vertex_data),
        });
        errdefer geometry.deinit();
        const group_layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .vertex = true, .fragment = true } },
        } });
        errdefer group_layout.deinit();
        var uniforms: [frames_in_flight]vit.Buffer = undefined;
        var groups: [frames_in_flight]vit.BindGroup = undefined;
        for (&uniforms, &groups, 0..) |*buffer, *group, i| {
            errdefer for (uniforms[0..i], groups[0..i]) |b, g| {
                g.deinit();
                b.deinit();
            };
            buffer.* = try vit.Buffer.init(device, .{
                .label = "preview transform",
                .size = 256,
                .usage = .{ .uniform = true },
                .memory = .upload,
            });
            errdefer buffer.deinit();
            group.* = try vit.BindGroup.init(device, .{ .layout = group_layout, .entries = &.{
                .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = buffer.* } } },
            } });
        }
        errdefer for (uniforms, groups) |b, g| {
            g.deinit();
            b.deinit();
        };
        const vs = try vit.Shader.init(device, .{ .label = "preview vertex", .stage = .vertex, .source = vit.SPIRVShaderModule.init(.{ .code = shaders.viewport_vertex }) });
        defer vs.deinit();
        const fs = try vit.Shader.init(device, .{ .label = "preview fragment", .stage = .fragment, .source = vit.SPIRVShaderModule.init(.{ .code = shaders.viewport_fragment }) });
        defer fs.deinit();
        const pipeline_layout = try vit.PipelineLayout.init(device, .{ .label = "preview layout", .bind_group_layouts = &.{group_layout} });
        errdefer pipeline_layout.deinit();
        const pipeline = try vit.GraphicsPipeline.init(device, .{
            .label = "preview pipeline",
            .vertex = vs,
            .fragment = fs,
            .vertex_buffers = &.{.{ .stride = @sizeOf(Vertex), .attributes = &.{
                .{ .location = 0, .format = .float32x3, .offset = @offsetOf(Vertex, "position") },
                .{ .location = 1, .format = .float32x3, .offset = @offsetOf(Vertex, "color") },
                .{ .location = 2, .format = .float32, .offset = @offsetOf(Vertex, "kind") },
            } }},
            .color_targets = &.{.{ .format = format }},
            .depth_stencil = .{ .format = .d32_float, .depth_write = true, .depth_compare = .less },
            .raster = .{ .cull_mode = .none },
            .layout = pipeline_layout,
        });
        errdefer pipeline.deinit();
        const depth = try makeDepth(device, extent);
        errdefer depth.deinit();
        const depth_view = try vit.TextureView.init(device, .{ .texture = depth, .aspect = .depth });
        return .{
            .geometry = geometry,
            .uniforms = uniforms,
            .group_layout = group_layout,
            .groups = groups,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .depth = depth,
            .depth_view = depth_view,
        };
    }

    pub fn resize(self: *Preview, device: vit.Device, extent: vit.Extent2D) !void {
        const depth = try makeDepth(device, extent);
        errdefer depth.deinit();
        const depth_view = try vit.TextureView.init(device, .{ .texture = depth, .aspect = .depth });
        self.depth_view.deinit();
        self.depth.deinit();
        self.depth = depth;
        self.depth_view = depth_view;
        self.depth_initialized = false;
    }

    pub fn deinit(self: *Preview) void {
        self.depth_view.deinit();
        self.depth.deinit();
        self.pipeline.deinit();
        self.pipeline_layout.deinit();
        for (self.uniforms, self.groups) |b, g| {
            g.deinit();
            b.deinit();
        }
        self.group_layout.deinit();
        self.geometry.deinit();
    }

    pub fn draw(self: *Preview, cmd: vit.CommandBuffer, target: vit.TextureView, scene: ui.Rect, clip: ui.Rect, window: ui.Rect, extent: vit.Extent2D, srgb: bool) !void {
        const scissor = previewScissor(scene, clip, window, extent) orelse return;
        const millis = sdl3.timer.getMillisecondsSinceInit() % 100_000;
        const t: f32 = @as(f32, @floatFromInt(millis)) * 0.001;
        const yaw = t * 0.7 + 0.45;
        const pitch = t * 0.43 + 0.3;
        const aspect = scene.w / scene.h;
        const transform = SceneUniforms{
            .rotation = .{ @sin(yaw), @cos(yaw), @sin(pitch), @cos(pitch) },
            .screen = .{
                2 * (scene.x + scene.w / 2) / window.w - 1,
                1 - 2 * (scene.y + scene.h / 2) / window.h,
                scene.w / window.w,
                scene.h / window.h,
            },
            .projection = .{ aspect, 1.55 * @min(1, aspect), if (srgb) 1 else 0, 0 },
        };
        const bytes = std.mem.asBytes(&transform);
        self.slot = (self.slot + 1) % frames_in_flight;
        const uniforms = self.uniforms[self.slot];
        const mapped = try uniforms.map(.write, .{ .size = bytes.len });
        @memcpy(mapped[0..bytes.len], bytes);
        uniforms.unmap(.{ .size = bytes.len });

        try cmd.barrier(&.{.{ .texture = .{
            .texture = self.depth,
            .before = if (self.depth_initialized) .depth_stencil_write else .common,
            .after = .depth_stencil_write,
        } }});
        self.depth_initialized = true;
        try cmd.beginRenderPass(.{
            .label = "3D preview",
            .color_attachments = &.{.{ .view = target, .load_op = .load, .store_op = .store }},
            .depth_stencil_attachment = .{ .view = self.depth_view, .depth_clear = 1, .depth_store_op = .discard },
        });
        cmd.setViewport(.{ .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height) });
        cmd.setScissor(scissor);
        cmd.setGraphicsPipeline(self.pipeline);
        cmd.setBindGroup(0, self.groups[self.slot], &.{});
        cmd.setVertexBuffer(0, self.geometry, 0);
        cmd.draw(@intCast(vertex_data.len), 1, 0, 0);
        cmd.endRenderPass();
    }
};

fn makeDepth(device: vit.Device, extent: vit.Extent2D) !vit.Texture {
    return vit.Texture.init(device, .{
        .label = "preview depth",
        .width = extent.width,
        .height = extent.height,
        .format = .d32_float,
        .usage = .{ .depth_stencil_attachment = true },
    });
}

fn previewScissor(scene: ui.Rect, clip: ui.Rect, window: ui.Rect, extent: vit.Extent2D) ?vit.hal.command.ScissorRect {
    if (extent.width == 0 or extent.height == 0 or window.w <= 0 or window.h <= 0 or scene.w <= 0 or scene.h <= 0) return null;
    for ([_]f32{ scene.x, scene.y, scene.w, scene.h, clip.x, clip.y, clip.w, clip.h, window.x, window.y, window.w, window.h }) |v| {
        if (!std.math.isFinite(v)) return null;
    }
    const visible = scene.intersection(clip).intersection(window);
    if (visible.w <= 0 or visible.h <= 0) return null;
    const px = @as(f32, @floatFromInt(extent.width)) / window.w;
    const py = @as(f32, @floatFromInt(extent.height)) / window.h;
    const left: u32 = @intFromFloat(std.math.clamp(@ceil((visible.x - window.x) * px - 0.5), 0, @as(f32, @floatFromInt(extent.width))));
    const right: u32 = @intFromFloat(std.math.clamp(@ceil((visible.x + visible.w - window.x) * px - 0.5), 0, @as(f32, @floatFromInt(extent.width))));
    const top: u32 = @intFromFloat(std.math.clamp(@ceil((visible.y - window.y) * py - 0.5), 0, @as(f32, @floatFromInt(extent.height))));
    const bottom: u32 = @intFromFloat(std.math.clamp(@ceil((visible.y + visible.h - window.y) * py - 0.5), 0, @as(f32, @floatFromInt(extent.height))));
    if (left >= right or top >= bottom) return null;
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

fn sceneVertices() [42]Vertex {
    var vertices: [42]Vertex = undefined;
    const corners = [_][3]f32{
        .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 },
    };
    const backdrop_colors = [_][3]f32{
        .{ 0.016, 0.035, 0.085 }, .{ 0.016, 0.035, 0.085 },
        .{ 0.085, 0.13, 0.21 },   .{ 0.085, 0.13, 0.21 },
    };
    const triangles = [_]usize{ 0, 1, 2, 0, 2, 3 };
    for (triangles, 0..) |corner, i| {
        vertices[i] = .{ .position = corners[corner], .color = backdrop_colors[corner], .kind = 1 };
    }
    const faces = .{
        .{ .corners = [4][3]f32{ .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, 1, -1 }, .{ -1, 1, -1 } }, .color = [3]f32{ 0.07, 0.78, 0.96 } },
        .{ .corners = [4][3]f32{ .{ 1, -1, 1 }, .{ -1, -1, 1 }, .{ -1, 1, 1 }, .{ 1, 1, 1 } }, .color = [3]f32{ 0.31, 0.5, 0.96 } },
        .{ .corners = [4][3]f32{ .{ -1, 1, -1 }, .{ 1, 1, -1 }, .{ 1, 1, 1 }, .{ -1, 1, 1 } }, .color = [3]f32{ 0.94, 0.68, 0.26 } },
        .{ .corners = [4][3]f32{ .{ -1, -1, 1 }, .{ 1, -1, 1 }, .{ 1, -1, -1 }, .{ -1, -1, -1 } }, .color = [3]f32{ 0.24, 0.55, 0.67 } },
        .{ .corners = [4][3]f32{ .{ 1, -1, -1 }, .{ 1, -1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, -1 } }, .color = [3]f32{ 0.85, 0.36, 0.64 } },
        .{ .corners = [4][3]f32{ .{ -1, -1, 1 }, .{ -1, -1, -1 }, .{ -1, 1, -1 }, .{ -1, 1, 1 } }, .color = [3]f32{ 0.44, 0.79, 0.55 } },
    };
    inline for (faces, 0..) |face, index| {
        for (triangles, 0..) |corner, i| {
            vertices[6 + index * 6 + i] = .{ .position = face.corners[corner], .color = face.color };
        }
    }
    return vertices;
}

test "preview scissor respects UI clipping, window and fractional pixel scale" {
    const window = ui.Rect{ .x = 0, .y = 0, .w = 100, .h = 60 };
    const scene = ui.Rect{ .x = 20, .y = 10, .w = 80, .h = 50 };
    const clip = ui.Rect{ .x = 30.25, .y = 0, .w = 40, .h = 30.25 };
    const scissor = previewScissor(scene, clip, window, .{ .width = 200, .height = 120 }).?;
    try std.testing.expectEqual(vit.hal.command.ScissorRect{ .x = 60, .y = 20, .width = 80, .height = 40 }, scissor);
    try std.testing.expect(previewScissor(scene, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, window, .{ .width = 200, .height = 120 }) == null);
    try std.testing.expect(previewScissor(.{ .x = 0, .y = 0, .w = 0, .h = 20 }, clip, window, .{ .width = 200, .height = 120 }) == null);
    try std.testing.expect(previewScissor(.{ .x = 110, .y = 0, .w = 20, .h = 20 }, clip, window, .{ .width = 200, .height = 120 }) == null);
}

test "preview skips an empty viewport without recording commands" {
    var preview: Preview = undefined;
    const empty = ui.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    try preview.draw(undefined, undefined, empty, empty, empty, .{ .width = 200, .height = 120 }, false);
}
