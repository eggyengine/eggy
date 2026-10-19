//! Multisample scene targets resolved and filtered into a single-sampled presentation target.
const std = @import("std");
const vit = @import("vitellus");
const shaders = @import("scene_shaders");

const triangle = [3][2]f32{ .{ 0, 0 }, .{ 2, 0 }, .{ 0, 2 } };

pub const Resolve = struct {
    device: vit.Device,
    format: vit.Format,
    samples: u32,
    fxaa: bool,
    target: Target,
    vertices: vit.Buffer,
    uniform: vit.Buffer,
    sampler: vit.Sampler,
    layout: vit.BindGroupLayout,
    pipeline_layout: vit.PipelineLayout,
    pipeline: vit.GraphicsPipeline,

    const Target = struct {
        texture: vit.Texture,
        view: vit.TextureView,
        group: vit.BindGroup,
        multisample: ?vit.Texture = null,
        multisample_view: ?vit.TextureView = null,
        initialized: bool = false,

        fn deinit(self: Target) void {
            self.group.deinit();
            if (self.multisample_view) |view| view.deinit();
            if (self.multisample) |texture| texture.deinit();
            self.view.deinit();
            self.texture.deinit();
        }
    };

    pub fn init(device: vit.Device, format: vit.Format, extent: vit.Extent2D, samples: u32, fxaa: bool, shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule) !Resolve {
        const vertices = try vit.Buffer.init(device, .{ .label = "scene resolve triangle", .size = @sizeOf(@TypeOf(triangle)), .usage = .{ .vertex = true }, .initial_data = std.mem.asBytes(&triangle) });
        errdefer vertices.deinit();
        const uniform = try vit.Buffer.init(device, .{ .label = "scene resolve options", .size = 256, .usage = .{ .uniform = true }, .memory = .upload });
        errdefer uniform.deinit();
        const sampler = try vit.Sampler.init(device, .{ .address_u = .clamp_to_edge, .address_v = .clamp_to_edge });
        errdefer sampler.deinit();
        const layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
            .{ .binding = 1, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
            .{ .binding = 2, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .fragment = true } },
        } });
        errdefer layout.deinit();
        const pipeline_layout = try vit.PipelineLayout.init(device, .{ .label = "scene resolve", .bind_group_layouts = &.{layout} });
        errdefer pipeline_layout.deinit();
        const vs = try vit.Shader.init(device, .{ .stage = .vertex, .source = shaderSource(shaders.resolve_vertex, "vertexMain") });
        defer vs.deinit();
        const fs = try vit.Shader.init(device, .{ .stage = .fragment, .source = shaderSource(shaders.resolve_fragment, "fragmentMain") });
        defer fs.deinit();
        const pipeline = try vit.GraphicsPipeline.init(device, .{
            .label = "scene resolve",
            .vertex = vs,
            .fragment = fs,
            .vertex_buffers = &.{.{ .stride = 8, .attributes = &.{.{ .location = 0, .format = .float32x2, .offset = 0 }} }},
            .color_targets = &.{.{ .format = format }},
            .raster = .{ .cull_mode = .none },
            .layout = pipeline_layout,
        });
        errdefer pipeline.deinit();
        var self = Resolve{ .device = device, .format = format, .samples = samples, .fxaa = fxaa, .target = undefined, .vertices = vertices, .uniform = uniform, .sampler = sampler, .layout = layout, .pipeline_layout = pipeline_layout, .pipeline = pipeline };
        self.target = try self.makeTarget(extent);
        return self;
    }

    pub fn deinit(self: *Resolve) void {
        self.target.deinit();
        self.pipeline.deinit();
        self.pipeline_layout.deinit();
        self.layout.deinit();
        self.sampler.deinit();
        self.uniform.deinit();
        self.vertices.deinit();
    }

    /// Replace targets only after the caller has waited for earlier GPU use.
    pub fn resize(self: *Resolve, extent: vit.Extent2D) !void {
        const target = try self.makeTarget(extent);
        self.target.deinit();
        self.target = target;
    }

    fn makeTarget(self: *Resolve, extent: vit.Extent2D) !Target {
        const texture = try vit.Texture.init(self.device, .{ .label = "resolved scene", .width = extent.width, .height = extent.height, .format = self.format, .usage = .{ .color_attachment = true, .sampled = true } });
        errdefer texture.deinit();
        const view = try vit.TextureView.init(self.device, .{ .texture = texture });
        errdefer view.deinit();
        const group = try vit.BindGroup.init(self.device, .{ .layout = self.layout, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = view } },
            .{ .binding = 1, .resource = .{ .sampler = self.sampler } },
            .{ .binding = 2, .resource = .{ .buffer = .{ .buffer = self.uniform } } },
        } });
        errdefer group.deinit();
        var multisample: ?vit.Texture = null;
        errdefer if (multisample) |made| made.deinit();
        var multisample_view: ?vit.TextureView = null;
        errdefer if (multisample_view) |made| made.deinit();
        if (self.samples > 1) {
            multisample = try vit.Texture.init(self.device, .{ .label = "multisample scene", .width = extent.width, .height = extent.height, .sample_count = self.samples, .format = self.format, .usage = .{ .color_attachment = true } });
            multisample_view = try vit.TextureView.init(self.device, .{ .texture = multisample.? });
        }
        const options = [4]f32{ 1 / @as(f32, @floatFromInt(extent.width)), 1 / @as(f32, @floatFromInt(extent.height)), if (self.fxaa) 1 else 0, 0 };
        const mapped = try self.uniform.map(.write, .{ .size = @sizeOf(@TypeOf(options)) });
        @memcpy(mapped, std.mem.asBytes(&options));
        self.uniform.unmap(.{ .size = @sizeOf(@TypeOf(options)) });
        return .{ .texture = texture, .view = view, .group = group, .multisample = multisample, .multisample_view = multisample_view };
    }

    pub fn begin(self: *Resolve, cmd: vit.CommandBuffer) !void {
        try cmd.barrier(&.{.{ .texture = .{ .texture = self.target.texture, .before = if (self.target.initialized) .sampled else .common, .after = .color_attachment } }});
        if (self.target.multisample) |texture| try cmd.barrier(&.{.{ .texture = .{ .texture = texture, .before = if (self.target.initialized) .color_attachment else .common, .after = .color_attachment } }});
    }

    pub fn attachment(self: *const Resolve) vit.hal.command.ColorAttachment {
        return .{
            .view = self.target.multisample_view orelse self.target.view,
            .resolve_target = if (self.samples > 1) self.target.view else null,
            .load_op = .clear,
            .store_op = if (self.samples > 1) .discard else .store,
        };
    }

    pub fn draw(self: *Resolve, cmd: vit.CommandBuffer, destination: vit.TextureView, extent: vit.Extent2D, scissor: vit.hal.command.ScissorRect) !void {
        try cmd.barrier(&.{.{ .texture = .{ .texture = self.target.texture, .before = .color_attachment, .after = .sampled } }});
        self.target.initialized = true;
        try cmd.beginRenderPass(.{ .label = "scene presentation", .color_attachments = &.{.{ .view = destination, .load_op = .load, .store_op = .store }} });
        cmd.setViewport(.{ .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height) });
        cmd.setScissor(scissor);
        cmd.setGraphicsPipeline(self.pipeline);
        cmd.setBindGroup(0, self.target.group, &.{});
        cmd.setVertexBuffer(0, self.vertices, 0);
        cmd.draw(3, 1, 0, 0);
        cmd.endRenderPass();
    }
};
