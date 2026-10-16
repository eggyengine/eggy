//! The editor's infinite grid on the ground (y = 0), drawn over a scene's meshes in its render
//! pass, behind whatever stands in front of it (`shaders/grid.slang`). Only the editor's Scene
//! panel asks for it, looking through its own camera; the game never draws it.
const std = @import("std");
const vit = @import("vitellus");
const ui = @import("weeoui");
const shaders = @import("scene_shaders");
const frames_in_flight = @import("weeoui_vitellus").frames_in_flight;
const camera = @import("camera.zig");

/// How far away the grid still shows, in metres.
const reach_m: f32 = 150;
/// (0, 0), (2, 0) and (0, 2): one triangle that covers the viewport.
const triangle = [3][2]f32{ .{ 0, 0 }, .{ 2, 0 }, .{ 0, 2 } };

const Uniforms = extern struct {
    view_projection: [4][4]f32,
    eye: [4]f32,
    forward: [4]f32,
    across: [4]f32,
    upward: [4]f32,
    viewport: [4]f32,
    options: [4]f32,
};

pub const Grid = struct {
    vertices: vit.Buffer,
    /// One per frame in flight, so `draw` never rewrites what the GPU is still reading.
    uniforms: [frames_in_flight]vit.Buffer,
    groups: [frames_in_flight]vit.BindGroup,
    slot: usize = 0,
    group_layout: vit.BindGroupLayout,
    pipeline_layout: vit.PipelineLayout,
    pipeline: vit.GraphicsPipeline,

    /// A grid drawing into `format`, with a `.d32_float` depth buffer it tests against.
    pub fn init(device: vit.Device, format: vit.Format, shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule) !Grid {
        const vertices = try vit.Buffer.init(device, .{ .label = "grid triangle", .size = @sizeOf(@TypeOf(triangle)), .usage = .{ .vertex = true }, .initial_data = std.mem.asBytes(&triangle) });
        errdefer vertices.deinit();
        const group_layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .vertex = true, .fragment = true } },
        } });
        errdefer group_layout.deinit();
        var uniforms: [frames_in_flight]vit.Buffer = undefined;
        var groups: [frames_in_flight]vit.BindGroup = undefined;
        for (&uniforms, &groups, 0..) |*buffer, *group, i| {
            errdefer for (uniforms[0..i], groups[0..i]) |made_buffer, made_group| {
                made_group.deinit();
                made_buffer.deinit();
            };
            buffer.* = try vit.Buffer.init(device, .{ .label = "grid uniforms", .size = 256, .usage = .{ .uniform = true }, .memory = .upload });
            errdefer buffer.deinit();
            group.* = try vit.BindGroup.init(device, .{ .layout = group_layout, .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = buffer.* } } }} });
        }
        errdefer for (uniforms, groups) |buffer, group| {
            group.deinit();
            buffer.deinit();
        };
        const pipeline_layout = try vit.PipelineLayout.init(device, .{ .label = "grid layout", .bind_group_layouts = &.{group_layout} });
        errdefer pipeline_layout.deinit();
        const vs = try vit.Shader.init(device, .{ .label = "grid vertex", .stage = .vertex, .source = shaderSource(shaders.grid_vertex, "vertexMain") });
        defer vs.deinit();
        const fs = try vit.Shader.init(device, .{ .label = "grid fragment", .stage = .fragment, .source = shaderSource(shaders.grid_fragment, "fragmentMain") });
        defer fs.deinit();
        // Blended over the scene, tested against its depth but not changing it.
        const pipeline = try vit.GraphicsPipeline.init(device, .{
            .label = "grid",
            .vertex = vs,
            .fragment = fs,
            .vertex_buffers = &.{.{ .stride = @sizeOf([2]f32), .attributes = &.{.{ .location = 0, .format = .float32x2, .offset = 0 }} }},
            .color_targets = &.{.{ .format = format, .blend = .{ .color = .{ .source = .src_alpha, .destination = .one_minus_src_alpha }, .alpha = .{ .source = .one, .destination = .one_minus_src_alpha } } }},
            .depth_stencil = .{ .format = .d32_float, .depth_write = false, .depth_compare = .less },
            .raster = .{ .cull_mode = .none },
            .layout = pipeline_layout,
        });
        return .{ .vertices = vertices, .uniforms = uniforms, .groups = groups, .group_layout = group_layout, .pipeline_layout = pipeline_layout, .pipeline = pipeline };
    }

    /// Free everything. The GPU must be done with it.
    pub fn deinit(self: *Grid) void {
        self.pipeline.deinit();
        self.pipeline_layout.deinit();
        for (self.uniforms, self.groups) |buffer, group| {
            group.deinit();
            buffer.deinit();
        }
        self.group_layout.deinit();
        self.vertices.deinit();
    }

    /// Draw the grid seen from `view` in the render pass in progress, whose viewport covers
    /// `viewport_px` (in the target's pixels). `srgb`: whether the target encodes sRGB itself.
    pub fn draw(self: *Grid, cmd: vit.CommandBuffer, view: camera.View, viewport_px: ui.Rect, srgb: bool) !void {
        if (viewport_px.w <= 0 or viewport_px.h <= 0) return;
        self.slot = (self.slot + 1) % frames_in_flight;
        const aspect = viewport_px.w / viewport_px.h;
        const half_height = @tan(view.fov_deg * std.math.rad_per_deg / 2);
        const right = camera.normalize(camera.cross(view.forward, view.up));
        const uniforms = Uniforms{
            .view_projection = view.viewProjection(aspect),
            .eye = .{ view.eye[0], view.eye[1], view.eye[2], 0 },
            .forward = .{ view.forward[0], view.forward[1], view.forward[2], 0 },
            .across = .{ right[0] * half_height * aspect, right[1] * half_height * aspect, right[2] * half_height * aspect, 0 },
            .upward = .{ view.up[0] * half_height, view.up[1] * half_height, view.up[2] * half_height, 0 },
            .viewport = .{ viewport_px.x, viewport_px.y, viewport_px.w, viewport_px.h },
            .options = .{ if (srgb) 1 else 0, reach_m, 0, 0 },
        };
        const buffer = self.uniforms[self.slot];
        const bytes = std.mem.asBytes(&uniforms);
        const mapped = try buffer.map(.write, .{ .size = bytes.len });
        @memcpy(mapped[0..bytes.len], bytes);
        buffer.unmap(.{ .size = bytes.len });

        cmd.setGraphicsPipeline(self.pipeline);
        cmd.setBindGroup(0, self.groups[self.slot], &.{});
        cmd.setVertexBuffer(0, self.vertices, 0);
        cmd.draw(3, 1, 0, 0);
    }
};
