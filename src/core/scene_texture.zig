//! The 3D scene rendered into an offscreen texture, for UIs that show it inside a panel (the
//! editor's Scene panel) instead of across the whole window.
const std = @import("std");
const vit = @import("vitellus");
const ui = @import("weeoui");
const shaders = @import("scene_shaders");
const viewport3d = @import("viewport3d.zig");
const mesh = @import("mesh.zig");
const camera = @import("camera.zig");
const ecs = @import("clutch");
const weeoui_vitellus = @import("weeoui_vitellus");
const Graphics = @import("graphics.zig").Graphics;

pub const SceneTexture = struct {
    settings_revision: u64,
    /// Its own preview, so its depth buffer matches the texture rather than the window.
    preview: viewport3d.Preview,
    /// Null until the first `render`.
    target: ?Target = null,
    /// The one triangle `draw` stretches over its viewport; see `blit_triangle`.
    triangle: vit.Buffer,
    sampler: vit.Sampler,
    group_layout: vit.BindGroupLayout,
    pipeline_layout: vit.PipelineLayout,
    pipeline: vit.GraphicsPipeline,

    const Target = struct {
        texture: vit.Texture,
        view: vit.TextureView,
        group: vit.BindGroup,
        extent: vit.Extent2D,
        /// Whether it has been rendered once, so it's in the sampled state rather than undefined.
        rendered: bool = false,

        fn deinit(self: Target) void {
            self.group.deinit();
            self.view.deinit();
            self.texture.deinit();
        }
    };

    /// Create host/editor offscreen-scene pipelines using this graphics device/format.
    /// The actual target is allocated lazily by `render`. Graphics must outlive the
    /// returned value; allocation/shader errors propagate. Pair with `deinit` after GPU use.
    ///
    /// ```zig
    /// var scene_texture = try SceneTexture.init(&graphics);
    /// defer scene_texture.deinit(); // Finish GPU use before this host scope ends.
    /// ```
    pub fn init(graphics: *const Graphics) !SceneTexture {
        const device = graphics.device;
        var preview = try viewport3d.Preview.init(device, graphics.color_format, .{ .width = 1, .height = 1 }, graphics.textures.layout, graphics.textures.maps.layout, graphics.render_settings);
        errdefer preview.deinit();
        // A vertex buffer rather than SV_VertexID, which needs Vulkan's shaderDrawParameters.
        const triangle = try vit.Buffer.init(device, .{ .label = "scene blit triangle", .size = @sizeOf(@TypeOf(blit_triangle)), .usage = .{ .vertex = true }, .initial_data = std.mem.asBytes(&blit_triangle) });
        errdefer triangle.deinit();
        const sampler = try vit.Sampler.init(device, .{ .address_u = .clamp_to_edge, .address_v = .clamp_to_edge });
        errdefer sampler.deinit();
        const group_layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
            .{ .binding = 1, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
        } });
        errdefer group_layout.deinit();
        const vs = try vit.Shader.init(device, .{ .label = "scene blit vertex", .stage = .vertex, .source = viewport3d.shaderSource(shaders.blit_vertex, "vertexMain") });
        defer vs.deinit();
        const fs = try vit.Shader.init(device, .{ .label = "scene blit fragment", .stage = .fragment, .source = viewport3d.shaderSource(shaders.blit_fragment, "fragmentMain") });
        defer fs.deinit();
        const pipeline_layout = try vit.PipelineLayout.init(device, .{ .label = "scene blit layout", .bind_group_layouts = &.{group_layout} });
        errdefer pipeline_layout.deinit();
        const pipeline = try vit.GraphicsPipeline.init(device, .{
            .label = "scene blit pipeline",
            .vertex = vs,
            .fragment = fs,
            .vertex_buffers = &.{.{ .stride = @sizeOf([2]f32), .attributes = &.{.{ .location = 0, .format = .float32x2, .offset = 0 }} }},
            .color_targets = &.{.{ .format = graphics.color_format }},
            .raster = .{ .cull_mode = .none },
            .layout = pipeline_layout,
        });
        return .{ .settings_revision = graphics.settings_revision, .preview = preview, .triangle = triangle, .sampler = sampler, .group_layout = group_layout, .pipeline_layout = pipeline_layout, .pipeline = pipeline };
    }

    /// Free everything. The GPU must be done with it (`Graphics.queue.waitIdle`).
    /// Host teardown: invalidates overlay views and the offscreen target; call once before
    /// destroying the graphics device.
    ///
    /// ```zig
    /// try graphics.queue.waitIdle();
    /// scene_texture.deinit();
    /// ```
    pub fn deinit(self: *SceneTexture) void {
        if (self.target) |target| target.deinit();
        self.pipeline.deinit();
        self.pipeline_layout.deinit();
        self.group_layout.deinit();
        self.sampler.deinit();
        self.triangle.deinit();
        self.preview.deinit();
    }

    /// Render the scene, with `drawables` (sorted in place) seen from `view` and each of `selected`'s
    /// outlined, and the editor's ground grid when `grid` says, into the texture at `extent_px`.
    /// Call outside a render pass. A new size recreates the texture, which first waits for the GPU
    /// to finish earlier frames.
    /// Host-only: `extent_px` is physical pixels; zero dimensions skip rendering. Uses the
    /// creating graphics' caches and device, borrows live drawable paths, and leaves the
    /// target sampled for `draw`. GPU/upload errors propagate.
    ///
    /// ```zig
    /// try scene_texture.render(&graphics, scene_cmd, .{ .width = 800, .height = 600 }, drawables, camera_view, selected_entities, true);
    /// ```
    pub fn render(self: *SceneTexture, graphics: *Graphics, cmd: vit.CommandBuffer, extent_px: vit.Extent2D, drawables: []mesh.Drawable, view: camera.View, selected: []const ecs.EntityId, grid: bool) !void {
        if (extent_px.width == 0 or extent_px.height == 0) return;
        if (self.settings_revision != graphics.settings_revision) {
            try graphics.queue.waitIdle();
            const preview = try viewport3d.Preview.init(graphics.device, graphics.color_format, extent_px, graphics.textures.layout, graphics.textures.maps.layout, graphics.render_settings);
            self.preview.deinit();
            self.preview = preview;
            self.settings_revision = graphics.settings_revision;
        }
        const target = try self.targetSized(graphics, extent_px);

        // Render, then leave the texture ready for `draw` to sample.
        try cmd.barrier(&.{.{ .texture = .{ .texture = target.texture, .before = if (target.rendered) .sampled else .common, .after = .color_attachment } }});
        const whole = ui.Rect{ .x = 0, .y = 0, .w = @floatFromInt(extent_px.width), .h = @floatFromInt(extent_px.height) };
        try self.preview.draw(cmd, target.view, whole, whole, whole, extent_px, weeoui_vitellus.isSrgb(graphics.color_format), drawables, graphics.sources(), view, selected, grid);
        try cmd.barrier(&.{.{ .texture = .{ .texture = target.texture, .before = .color_attachment, .after = .sampled } }});
        target.rendered = true;
    }

    /// Reopen the rendered target for custom drawing, outside a pass. Pair with `endOverlay`
    /// before sampling it. The returned view is borrowed until resize/deinit.
    /// Host-only transition, not a render-pass begin: returns `SceneNotRendered` until a
    /// nonempty render succeeds; barrier errors propagate. Custom passes must preserve
    /// the target contents, then end before `endOverlay`.
    ///
    /// ```zig
    /// const overlay_target = try scene_texture.beginOverlay(scene_cmd);
    /// try scene_cmd.beginRenderPass(.{ .color_attachments = &.{.{
    ///     .view = overlay_target, .load_op = .load, .store_op = .store,
    /// }} });
    /// // Record host overlay drawing here.
    /// scene_cmd.endRenderPass();
    /// try scene_texture.endOverlay(scene_cmd);
    /// ```
    pub fn beginOverlay(self: *SceneTexture, cmd: vit.CommandBuffer) !vit.TextureView {
        const target = if (self.target) |*target| target else return error.SceneNotRendered;
        if (!target.rendered) return error.SceneNotRendered;
        try cmd.barrier(&.{.{ .texture = .{ .texture = target.texture, .before = .sampled, .after = .color_attachment } }});
        return target.view;
    }

    /// Return the overlay target to the sampled state used by `draw`.
    /// Host-only: pair once with `beginOverlay` after ending the custom pass, on the same
    /// recording command buffer. Missing targets give `SceneNotRendered`; GPU errors
    /// propagate. Does not itself end a render pass.
    ///
    /// ```zig
    /// // After beginOverlay and the custom render pass:
    /// scene_cmd.endRenderPass();
    /// try scene_texture.endOverlay(scene_cmd);
    /// ```
    pub fn endOverlay(self: *SceneTexture, cmd: vit.CommandBuffer) !void {
        const target = if (self.target) |*target| target else return error.SceneNotRendered;
        try cmd.barrier(&.{.{ .texture = .{ .texture = target.texture, .before = .color_attachment, .after = .sampled } }});
    }

    // ponytail: waits for the GPU on every size change, so dragging a splitter stalls a little; keep a spare texture per frame in flight if that shows.
    fn targetSized(self: *SceneTexture, graphics: *Graphics, extent_px: vit.Extent2D) !*Target {
        if (self.target) |*target| if (target.extent.width == extent_px.width and target.extent.height == extent_px.height) return target;
        try graphics.queue.waitIdle();
        if (self.target) |target| target.deinit();
        self.target = null;

        const device = graphics.device;
        try self.preview.resize(device, extent_px);
        const texture = try vit.Texture.init(device, .{
            .label = "scene texture",
            .width = extent_px.width,
            .height = extent_px.height,
            .format = graphics.color_format,
            .usage = .{ .color_attachment = true, .sampled = true, .transfer_src = true },
        });
        errdefer texture.deinit();
        const view = try vit.TextureView.init(device, .{ .texture = texture });
        errdefer view.deinit();
        const group = try vit.BindGroup.init(device, .{ .layout = self.group_layout, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = view } },
            .{ .binding = 1, .resource = .{ .sampler = self.sampler } },
        } });
        self.target = .{ .texture = texture, .view = view, .group = group, .extent = extent_px };
        return &self.target.?;
    }

    /// Draw the last `render` into `rect_px` of the render pass in progress, whose target is
    /// `target_extent`. Draws nothing before the first `render`.
    /// Host blit: `rect_px` and `target_extent` are physical pixels; clips to the target
    /// and changes viewport/scissor/pipeline bindings. The pass format must match graphics;
    /// call only after `render`/`endOverlay` has left the scene texture sampled.
    ///
    /// ```zig
    /// // Inside the host window's compatible render pass:
    /// scene_texture.draw(window_cmd, panel_rect_pixels, window_extent_pixels);
    /// ```
    pub fn draw(self: *const SceneTexture, cmd: vit.CommandBuffer, rect_px: ui.Rect, target_extent: vit.Extent2D) void {
        const target = self.target orelse return;
        if (!target.rendered) return;
        const scissor = scissorFor(rect_px, target_extent) orelse return;
        cmd.setViewport(.{ .x = rect_px.x, .y = rect_px.y, .width = rect_px.w, .height = rect_px.h });
        cmd.setScissor(scissor);
        cmd.setGraphicsPipeline(self.pipeline);
        cmd.setBindGroup(0, target.group, &.{});
        cmd.setVertexBuffer(0, self.triangle, 0);
        cmd.draw(3, 1, 0, 0);
    }
};

/// Texture coordinates of a triangle twice the viewport's size, so its (0, 0)-(1, 1) part fills it.
const blit_triangle = [3][2]f32{ .{ 0, 0 }, .{ 2, 0 }, .{ 0, 2 } };

/// `rect_px` clamped to the render target, in whole pixels; null when nothing of it is visible.
fn scissorFor(rect_px: ui.Rect, target: vit.Extent2D) ?vit.hal.command.ScissorRect {
    const width: f32 = @floatFromInt(target.width);
    const height: f32 = @floatFromInt(target.height);
    const left = std.math.clamp(@round(rect_px.x), 0, width);
    const top = std.math.clamp(@round(rect_px.y), 0, height);
    const right = std.math.clamp(@round(rect_px.x + rect_px.w), 0, width);
    const bottom = std.math.clamp(@round(rect_px.y + rect_px.h), 0, height);
    if (right <= left or bottom <= top) return null;
    return .{ .x = @intFromFloat(left), .y = @intFromFloat(top), .width = @intFromFloat(right - left), .height = @intFromFloat(bottom - top) };
}

test "the scene's scissor stays inside the render target" {
    const target = vit.Extent2D{ .width = 200, .height = 100 };
    try std.testing.expectEqual(vit.hal.command.ScissorRect{ .x = 150, .y = 0, .width = 50, .height = 40 }, scissorFor(.{ .x = 150, .y = -10, .w = 80, .h = 50 }, target).?);
    try std.testing.expect(scissorFor(.{ .x = 210, .y = 0, .w = 20, .h = 20 }, target) == null);
}
