//! The 3D scene: a backdrop, and the world's meshes over it (`mesh_renderer.zig`).
const std = @import("std");
const vit = @import("vitellus");
const ui = @import("weeoui");
const shaders = @import("scene_shaders");
const frames_in_flight = @import("weeoui_vitellus").frames_in_flight;
const mesh = @import("mesh.zig");
const camera = @import("camera.zig");
const ecs = @import("clutch");
const mesh_renderer = @import("mesh_renderer.zig");
const MeshRenderer = mesh_renderer.MeshRenderer;
const Grid = @import("grid.zig").Grid;
const Settings = @import("render_settings.zig").Settings;
const Resolve = @import("scene_resolve.zig").Resolve;

const Vertex = extern struct {
    position: [2]f32,
    color: [3]f32,
};

const SceneUniforms = extern struct {
    /// The scene's centre and half-size, in window NDC.
    screen: [4]f32,
    /// x: 1 when the target is sRGB.
    options: [4]f32,
};

const vertex_data = backdropVertices();

pub const Preview = struct {
    settings: Settings,
    resolve: ?Resolve = null,
    /// The backdrop's two triangles.
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
    meshes: MeshRenderer,
    grid: Grid,
    world_draw: @import("world_draw.zig").Renderer,

    /// The backdrop and meshes for a target in `format` at `extent`, painting with textures
    /// bound as `texture_layout` describes (`TextureCache.layout`).
    /// Host renderer setup: `extent` is the nonzero physical-pixel depth-buffer size.
    /// The device/layout must remain alive; GPU/shader/allocation errors propagate.
    /// Owns render resources and must be deinitialized after their GPU work completes.
    ///
    /// ```zig
    /// var preview = try Preview.init(device, color_format, target_extent_pixels, textures.layout, graphics.render_settings);
    /// defer preview.deinit(); // Finish GPU use before this host scope ends.
    /// ```
    pub fn init(device: vit.Device, format: vit.Format, extent: vit.Extent2D, texture_layout: vit.BindGroupLayout, settings: Settings) !Preview {
        const sample_count = settings.anti_aliasing.samples();
        const render_extent = renderExtent(extent, settings.render_scale);
        const geometry = try vit.Buffer.init(device, .{
            .label = "scene backdrop",
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
        const vs = try vit.Shader.init(device, .{ .label = "preview vertex", .stage = .vertex, .source = shaderSource(shaders.viewport_vertex, "vertexMain") });
        defer vs.deinit();
        const fs = try vit.Shader.init(device, .{ .label = "preview fragment", .stage = .fragment, .source = shaderSource(shaders.viewport_fragment, "fragmentMain") });
        defer fs.deinit();
        const pipeline_layout = try vit.PipelineLayout.init(device, .{ .label = "preview layout", .bind_group_layouts = &.{group_layout} });
        errdefer pipeline_layout.deinit();
        const pipeline = try vit.GraphicsPipeline.init(device, .{
            .label = "preview pipeline",
            .vertex = vs,
            .fragment = fs,
            .vertex_buffers = &.{.{ .stride = @sizeOf(Vertex), .attributes = &.{
                .{ .location = 0, .format = .float32x2, .offset = @offsetOf(Vertex, "position") },
                .{ .location = 1, .format = .float32x3, .offset = @offsetOf(Vertex, "color") },
            } }},
            .color_targets = &.{.{ .format = format }},
            .depth_stencil = .{ .format = .d32_float, .depth_write = true, .depth_compare = .less },
            .raster = .{ .cull_mode = .none },
            .layout = pipeline_layout,
            .multisample = .{ .count = sample_count },
        });
        errdefer pipeline.deinit();
        const depth = try makeDepth(device, render_extent, sample_count);
        errdefer depth.deinit();
        const depth_view = try vit.TextureView.init(device, .{ .texture = depth, .aspect = .depth });
        errdefer depth_view.deinit();
        var meshes = try MeshRenderer.init(device, format, shaderSource, texture_layout, sample_count, settings.shadow_quality);
        errdefer meshes.deinit();
        var grid = try Grid.init(device, format, shaderSource, sample_count);
        errdefer grid.deinit();
        var world_draw = try @import("world_draw.zig").Renderer.init(device, format, sample_count, texture_layout, shaderSource);
        errdefer world_draw.deinit();
        var resolve: ?Resolve = null;
        errdefer if (resolve) |*made| made.deinit();
        if (settings.anti_aliasing != .off or settings.render_scale != 1)
            resolve = try Resolve.init(device, format, render_extent, sample_count, settings.anti_aliasing == .fxaa, shaderSource);
        return .{
            .settings = settings,
            .resolve = resolve,
            .geometry = geometry,
            .uniforms = uniforms,
            .group_layout = group_layout,
            .groups = groups,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .depth = depth,
            .depth_view = depth_view,
            .meshes = meshes,
            .grid = grid,
            .world_draw = world_draw,
        };
    }

    /// Replace the host preview's depth target with a nonzero physical-pixel `extent`.
    /// Use its creating device and ensure the GPU is finished with the old depth resources
    /// first. GPU allocation errors leave the previous depth target intact.
    ///
    /// ```zig
    /// try graphics.queue.waitIdle();
    /// try preview.resize(graphics.device, resized_extent_pixels);
    /// ```
    pub fn resize(self: *Preview, device: vit.Device, extent: vit.Extent2D) !void {
        const render_extent = renderExtent(extent, self.settings.render_scale);
        const depth = try makeDepth(device, render_extent, self.settings.anti_aliasing.samples());
        errdefer depth.deinit();
        const depth_view = try vit.TextureView.init(device, .{ .texture = depth, .aspect = .depth });
        errdefer depth_view.deinit();
        if (self.resolve) |*resolve| try resolve.resize(render_extent);
        self.depth_view.deinit();
        self.depth.deinit();
        self.depth = depth;
        self.depth_view = depth_view;
        self.depth_initialized = false;
    }

    /// Destroy host preview resources once after all their GPU work has finished.
    /// Does not destroy the target or borrowed asset caches; device must still be alive.
    ///
    /// ```zig
    /// try graphics.queue.waitIdle();
    /// preview.deinit();
    /// ```
    pub fn deinit(self: *Preview) void {
        if (self.resolve) |*resolve| resolve.deinit();
        self.grid.deinit();
        self.world_draw.deinit();
        self.meshes.deinit();
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

    /// Draw the backdrop and `drawables` (sorted in place), seen from `view` with `selected`'s
    /// outlined, into `scene` of `target`, a window `window` big at `extent` pixels, cut to
    /// `clip`, with model files and textures from `sources`, and the editor's ground grid when
    /// `grid` says. Call outside a render pass.
    /// Host-only: `scene`, `clip` and `window` share logical UI coordinates; `extent` is
    /// the physical-pixel target/depth size. `srgb` says the target encodes sRGB itself.
    /// The target must already be in color-attachment state and match the configured
    /// format. Borrows live drawable paths, loads assets, changes bindings and records a
    /// complete pass; the caller fences in-flight buffers before reuse. GPU errors
    /// propagate; empty/invalid clipped rectangles record nothing.
    ///
    /// ```zig
    /// try preview.draw(scene_cmd, target_view, scene_rect, clip_rect, window_rect, target_extent_pixels, target_is_srgb, drawables, asset_sources, camera_view, selected_entity, true);
    /// ```
    pub fn draw(self: *Preview, cmd: vit.CommandBuffer, target: vit.TextureView, scene: ui.Rect, clip: ui.Rect, window: ui.Rect, extent: vit.Extent2D, srgb: bool, drawables: []mesh.Drawable, sources: mesh_renderer.Sources, view: camera.View, selected: ?ecs.EntityId, grid: bool) !void {
        const scissor = previewScissor(scene, clip, window, extent) orelse return;
        if (self.resolve) |*resolve| {
            try resolve.begin(cmd);
            try self.drawPass(cmd, target, scene, clip, window, renderExtent(extent, self.settings.render_scale), srgb, drawables, sources, view, selected, grid);
            try resolve.draw(cmd, target, extent, scissor);
        } else try self.drawPass(cmd, target, scene, clip, window, extent, srgb, drawables, sources, view, selected, grid);
    }

    fn drawPass(self: *Preview, cmd: vit.CommandBuffer, target: vit.TextureView, scene: ui.Rect, clip: ui.Rect, window: ui.Rect, extent: vit.Extent2D, srgb: bool, drawables: []mesh.Drawable, sources: mesh_renderer.Sources, view: camera.View, selected: ?ecs.EntityId, grid: bool) !void {
        const scissor = previewScissor(scene, clip, window, extent) orelse return;
        try self.meshes.prepare(cmd, drawables, sources);
        try self.meshes.renderShadow(cmd, drawables, sources, view, scene.w / scene.h, self.settings);
        try self.world_draw.prepare(sources.world_draw, sources.textures, view, scene.w / scene.h, srgb);
        const transform = SceneUniforms{
            .screen = .{
                2 * (scene.x + scene.w / 2) / window.w - 1,
                1 - 2 * (scene.y + scene.h / 2) / window.h,
                scene.w / window.w,
                scene.h / window.h,
            },
            .options = .{ if (srgb) 1 else 0, 0, 0, 0 },
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
            .color_attachments = &.{if (self.resolve) |*resolve| resolve.attachment() else .{ .view = target, .load_op = .load, .store_op = .store }},
            .depth_stencil_attachment = .{ .view = self.depth_view, .depth_clear = 1, .depth_store_op = .discard },
        });
        errdefer cmd.endRenderPass();
        cmd.setViewport(.{ .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height) });
        cmd.setScissor(scissor);
        cmd.setGraphicsPipeline(self.pipeline);
        cmd.setBindGroup(0, self.groups[self.slot], &.{});
        cmd.setVertexBuffer(0, self.geometry, 0);
        cmd.draw(@intCast(vertex_data.len), 1, 0, 0);

        // The meshes, in a viewport covering just the scene.
        const px = @as(f32, @floatFromInt(extent.width)) / window.w;
        const py = @as(f32, @floatFromInt(extent.height)) / window.h;
        cmd.setViewport(.{ .x = (scene.x - window.x) * px, .y = (scene.y - window.y) * py, .width = scene.w * px, .height = scene.h * py });
        try self.meshes.draw(cmd, drawables, sources, view.viewProjection(scene.w / scene.h), .{ scene.w * px, scene.h * py }, view.eye, selected, srgb);
        if (grid) try self.grid.draw(cmd, view, .{ .x = (scene.x - window.x) * px, .y = (scene.y - window.y) * py, .w = scene.w * px, .h = scene.h * py }, srgb);
        const quads = self.world_draw.draw(cmd);
        sources.stats.draw_calls += quads;
        sources.stats.triangles += quads * 2;
        cmd.endRenderPass();
    }
};

/// The build compiles the Slang shaders to WGSL for the web and SPIR-V elsewhere.
/// Host shader adapter: wraps those compiled `code` bytes without compiling source here.
/// `entry_point` selects the WGSL entry on the web; keep both inputs alive through shader
/// creation. Returns a borrowed shader-module description, not an owned GPU shader.
///
/// ```zig
/// const source = shaderSource(compiled_vertex_bytes, "vertexMain");
/// ```
pub fn shaderSource(code: []const u8, entry_point: []const u8) vit.ShaderModule {
    if (@import("builtin").os.tag == .emscripten)
        return vit.BinaryShaderModule.init(.{ .backend = .webgpu, .format = .wgsl, .bytes = code, .entry_point = entry_point });
    return @import("vitellus_spirv").SPIRVShaderModule.init(.{ .code = code });
}

fn makeDepth(device: vit.Device, extent: vit.Extent2D, samples: u32) !vit.Texture {
    return vit.Texture.init(device, .{
        .label = "preview depth",
        .width = extent.width,
        .height = extent.height,
        .format = .d32_float,
        .sample_count = samples,
        .usage = .{ .depth_stencil_attachment = true },
    });
}

fn renderExtent(extent: vit.Extent2D, scale: f32) vit.Extent2D {
    return .{
        .width = @max(1, @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(extent.width)) * scale)))),
        .height = @max(1, @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(extent.height)) * scale)))),
    };
}

test "render scaling preserves a nonempty target and rounds fractional pixels up" {
    try std.testing.expectEqual(vit.Extent2D{ .width = 1, .height = 1 }, renderExtent(.{ .width = 1, .height = 1 }, 0.25));
    try std.testing.expectEqual(vit.Extent2D{ .width = 451, .height = 338 }, renderExtent(.{ .width = 901, .height = 675 }, 0.5));
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

/// A gradient across the scene, darker at the bottom, behind everything (at the far plane).
fn backdropVertices() [6]Vertex {
    const corners = [_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    const colors = [_][3]f32{
        .{ 0.016, 0.035, 0.085 }, .{ 0.016, 0.035, 0.085 },
        .{ 0.085, 0.13, 0.21 },   .{ 0.085, 0.13, 0.21 },
    };
    var vertices: [6]Vertex = undefined;
    for ([_]usize{ 0, 1, 2, 0, 2, 3 }, &vertices) |corner, *vertex| vertex.* = .{ .position = corners[corner], .color = colors[corner] };
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
    try preview.draw(undefined, undefined, empty, empty, empty, .{ .width = 200, .height = 120 }, false, &.{}, undefined, .default, null, false);
}
