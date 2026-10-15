//! Draws `mesh.Drawable`s: every shape's geometry sits in one vertex and index buffer, and each
//! shape is drawn once, instanced, for every entity shown as it; each model file likewise, from
//! its own buffers in the `ModelCache`. A selected entity is outlined,
//! through anything in front of it too: after the meshes, its mask goes into the depth buffer at
//! the nearest depth (without colour), then its hull, pushed outwards on screen, just behind
//! that, so the hull shows everywhere but the mask: its rim.
const std = @import("std");
const vit = @import("vitellus");
const ecs = @import("clutch");
const shaders = @import("scene_shaders");
const mesh = @import("mesh.zig");
const ModelCache = @import("model_cache.zig").ModelCache;
const frames_in_flight = @import("weeoui_vitellus").frames_in_flight;

/// The most meshes drawn in one frame; any more are left out.
pub const max_drawables = 4096;
/// The selection outline: its colour, and how wide it is in pixels.
const outline_color = [4]f32{ 1, 0.62, 0.15, 1 };
const outline_width_px: f32 = 2.5;

const CameraUniforms = extern struct {
    view_projection: [4][4]f32,
    light: [4]f32,
    options: [4]f32,
    outline: [4]f32,
    outline_size: [4]f32,
};

pub const MeshRenderer = struct {
    vertices: vit.Buffer,
    indices: vit.Buffer,
    ranges: [std.enums.values(mesh.Shape).len]mesh.Geometry.Range,
    /// One of each per frame in flight, so `draw` never rewrites what the GPU is still reading.
    instances: [frames_in_flight]vit.Buffer,
    uniforms: [frames_in_flight]vit.Buffer,
    groups: [frames_in_flight]vit.BindGroup,
    slot: usize = 0,
    group_layout: vit.BindGroupLayout,
    pipeline_layout: vit.PipelineLayout,
    pipeline: vit.GraphicsPipeline,
    outline_pipeline: vit.GraphicsPipeline,
    mask_pipeline: vit.GraphicsPipeline,

    /// Build the shapes and a pipeline drawing into `format`, with a `.d32_float` depth buffer.
    pub fn init(device: vit.Device, format: vit.Format, shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule) !MeshRenderer {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const geometry = try mesh.Geometry.build(arena.allocator());
        const vertices = try vit.Buffer.init(device, .{ .label = "mesh vertices", .size = geometry.vertices.len * @sizeOf(mesh.Vertex), .usage = .{ .vertex = true }, .initial_data = std.mem.sliceAsBytes(geometry.vertices) });
        errdefer vertices.deinit();
        const indices = try vit.Buffer.init(device, .{ .label = "mesh indices", .size = geometry.indices.len * @sizeOf(u32), .usage = .{ .index = true }, .initial_data = std.mem.sliceAsBytes(geometry.indices) });
        errdefer indices.deinit();

        // Per frame in flight: the instances and the camera, which the bind group holds.
        const group_layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .vertex = true, .fragment = true } },
        } });
        errdefer group_layout.deinit();
        var instances: [frames_in_flight]vit.Buffer = undefined;
        var uniforms: [frames_in_flight]vit.Buffer = undefined;
        var groups: [frames_in_flight]vit.BindGroup = undefined;
        for (0..frames_in_flight) |i| {
            errdefer for (0..i) |made| {
                groups[made].deinit();
                uniforms[made].deinit();
                instances[made].deinit();
            };
            instances[i] = try vit.Buffer.init(device, .{ .label = "mesh instances", .size = max_drawables * @sizeOf(mesh.Drawable), .usage = .{ .vertex = true }, .memory = .upload });
            errdefer instances[i].deinit();
            uniforms[i] = try vit.Buffer.init(device, .{ .label = "mesh camera", .size = 256, .usage = .{ .uniform = true }, .memory = .upload });
            errdefer uniforms[i].deinit();
            groups[i] = try vit.BindGroup.init(device, .{ .layout = group_layout, .entries = &.{
                .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = uniforms[i] } } },
            } });
        }
        errdefer for (instances, uniforms, groups) |instance, uniform, group| {
            group.deinit();
            uniform.deinit();
            instance.deinit();
        };

        const pipeline_layout = try vit.PipelineLayout.init(device, .{ .label = "mesh layout", .bind_group_layouts = &.{group_layout} });
        errdefer pipeline_layout.deinit();
        const pipeline = try makePipeline(device, format, pipeline_layout, shaderSource, "mesh", shaders.mesh_vertex, "vertexMain", shaders.mesh_fragment, "fragmentMain", .drawn);
        errdefer pipeline.deinit();
        const outline_pipeline = try makePipeline(device, format, pipeline_layout, shaderSource, "outline", shaders.outline_vertex, "vertexOutline", shaders.outline_fragment, "fragmentOutline", .over_all_but_mask);
        errdefer outline_pipeline.deinit();
        const mask_pipeline = try makePipeline(device, format, pipeline_layout, shaderSource, "selection mask", shaders.mask_vertex, "vertexMask", shaders.outline_fragment, "fragmentOutline", .mask);
        return .{
            .vertices = vertices,
            .indices = indices,
            .ranges = geometry.ranges,
            .instances = instances,
            .uniforms = uniforms,
            .groups = groups,
            .group_layout = group_layout,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .outline_pipeline = outline_pipeline,
            .mask_pipeline = mask_pipeline,
        };
    }

    /// Free everything. The GPU must be done with it.
    pub fn deinit(self: *MeshRenderer) void {
        self.mask_pipeline.deinit();
        self.outline_pipeline.deinit();
        self.pipeline.deinit();
        self.pipeline_layout.deinit();
        for (self.instances, self.uniforms, self.groups) |instance, uniform, group| {
            group.deinit();
            uniform.deinit();
            instance.deinit();
        }
        self.group_layout.deinit();
        self.indices.deinit();
        self.vertices.deinit();
    }

    /// Draw `drawables` (at most `max_drawables`; they are sorted in place) in the render pass in
    /// progress, whose viewport is `viewport_px`, through `view_projection` (a `camera.View`'s),
    /// outlining `selected`'s, with model files' triangles from `models`. `srgb`: whether the
    /// target encodes sRGB itself.
    pub fn draw(self: *MeshRenderer, cmd: vit.CommandBuffer, drawables: []mesh.Drawable, models: *ModelCache, view_projection: [4][4]f32, viewport_px: [2]f32, selected: ?ecs.EntityId, srgb: bool) !void {
        const sorted = drawables[0..@min(drawables.len, max_drawables)];
        if (sorted.len == 0) return;
        self.slot = (self.slot + 1) % frames_in_flight;

        // Sort so each shape's, then each model file's, are one instanced draw; then upload them
        // and the camera.
        std.mem.sort(mesh.Drawable, sorted, {}, drawnBefore);
        try upload(self.instances[self.slot], std.mem.sliceAsBytes(sorted));
        const camera = CameraUniforms{ .view_projection = view_projection, .light = .{ 0.4, 1, 0.6, 0 }, .options = .{ if (srgb) 1 else 0, 0, 0, 0 }, .outline = outline_color, .outline_size = .{ viewport_px[0], viewport_px[1], outline_width_px, 0 } };
        try upload(self.uniforms[self.slot], std.mem.asBytes(&camera));

        cmd.setBindGroup(0, self.groups[self.slot], &.{});
        cmd.setVertexBuffer(1, self.instances[self.slot], 0);

        // One instanced draw per run of the same shape or model file.
        cmd.setGraphicsPipeline(self.pipeline);
        var start: usize = 0;
        while (start < sorted.len) {
            var end = start + 1;
            while (end < sorted.len and !drawnBefore({}, sorted[start], sorted[end])) end += 1;
            if (self.bind(cmd, models, sorted[start])) |range| cmd.drawIndexed(range.index_count, @intCast(end - start), range.first_index, 0, @intCast(start));
            start = end;
        }

        // The selected entity's mask, then its outline wherever the mask isn't.
        if (selected) |entity| for (sorted, 0..) |drawable, i| if (drawable.entity().eql(entity)) {
            const range = self.bind(cmd, models, drawable) orelse break;
            for ([_]vit.GraphicsPipeline{ self.mask_pipeline, self.outline_pipeline }) |pass| {
                cmd.setGraphicsPipeline(pass);
                cmd.drawIndexed(range.index_count, 1, range.first_index, 0, @intCast(i));
            }
        };
    }

    /// Bind the vertex and index buffers `drawable` is drawn from, and say which of its indices;
    /// null for a model file that can't be drawn.
    fn bind(self: *MeshRenderer, cmd: vit.CommandBuffer, models: *ModelCache, drawable: mesh.Drawable) ?mesh.Geometry.Range {
        if (drawable.modelFile()) |file| {
            const model = models.get(file) orelse return null;
            cmd.setVertexBuffer(0, model.vertices, 0);
            cmd.setIndexBuffer(model.indices, .uint32, 0);
            return .{ .first_index = 0, .index_count = model.index_count };
        }
        cmd.setVertexBuffer(0, self.vertices, 0);
        cmd.setIndexBuffer(self.indices, .uint32, 0);
        return self.ranges[@intFromEnum(drawable.shape)];
    }
};

/// The order meshes are drawn in: built-in shapes first, by shape, then model files, by path.
/// Two that neither comes before are drawn in one go.
fn drawnBefore(_: void, a: mesh.Drawable, b: mesh.Drawable) bool {
    const a_file = a.modelFile() orelse return if (b.modelFile() != null) true else @intFromEnum(a.shape) < @intFromEnum(b.shape);
    const b_file = b.modelFile() orelse return false;
    return std.mem.lessThan(u8, a_file, b_file);
}

fn upload(buffer: vit.Buffer, bytes: []const u8) !void {
    const mapped = try buffer.map(.write, .{ .size = bytes.len });
    @memcpy(mapped[0..bytes.len], bytes);
    buffer.unmap(.{ .size = bytes.len });
}

/// How a pipeline meets the depth buffer: drawn as usual; the selection's mask (depth only,
/// over everything); or over everything but the mask (the outline).
const DepthUse = enum { drawn, mask, over_all_but_mask };

/// A pipeline drawing shapes into `format` with a `.d32_float` depth buffer, from the given
/// vertex and fragment shaders, labelled `label`.
fn makePipeline(device: vit.Device, format: vit.Format, layout: vit.PipelineLayout, shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule, label: []const u8, vertex: []const u8, vertex_entry: []const u8, fragment: []const u8, fragment_entry: []const u8, depth: DepthUse) !vit.GraphicsPipeline {
    const vs = try vit.Shader.init(device, .{ .label = label, .stage = .vertex, .source = shaderSource(vertex, vertex_entry) });
    defer vs.deinit();
    const fs = try vit.Shader.init(device, .{ .label = label, .stage = .fragment, .source = shaderSource(fragment, fragment_entry) });
    defer fs.deinit();
    return vit.GraphicsPipeline.init(device, .{
        .label = label,
        .vertex = vs,
        .fragment = fs,
        .vertex_buffers = &.{
            .{ .stride = @sizeOf(mesh.Vertex), .attributes = &.{
                .{ .location = 0, .format = .float32x3, .offset = @offsetOf(mesh.Vertex, "position") },
                .{ .location = 1, .format = .float32x3, .offset = @offsetOf(mesh.Vertex, "normal") },
            } },
            .{ .stride = @sizeOf(mesh.Drawable), .step_mode = .instance, .attributes = &.{
                .{ .location = 2, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "model") },
                .{ .location = 3, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "model") + 16 },
                .{ .location = 4, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "model") + 32 },
                .{ .location = 5, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "model") + 48 },
                .{ .location = 6, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "color") },
            } },
        },
        .color_targets = &.{.{ .format = format, .write_mask = if (depth == .mask) .{ .red = false, .green = false, .blue = false, .alpha = false } else .{} }},
        .depth_stencil = switch (depth) {
            .drawn => .{ .format = .d32_float, .depth_write = true, .depth_compare = .less },
            .mask => .{ .format = .d32_float, .depth_write = true, .depth_compare = .always },
            .over_all_but_mask => .{ .format = .d32_float, .depth_write = false, .depth_compare = .less },
        },
        // ponytail: no culling, as the shapes' winding isn't checked against Vitellus's front face; cull back faces once it is.
        .raster = .{ .cull_mode = .none },
        .layout = layout,
    });
}

test "shapes are drawn before model files, and each kind together" {
    var drawables = [_]mesh.Drawable{
        .{ .model = undefined, .color = undefined, .shape = .cube, .entity_id = 0, .entity_generation = 0, .model_file = "b.glb", .model_file_len = 5 },
        .{ .model = undefined, .color = undefined, .shape = .sphere, .entity_id = 1, .entity_generation = 0 },
        .{ .model = undefined, .color = undefined, .shape = .cube, .entity_id = 2, .entity_generation = 0, .model_file = "a.glb", .model_file_len = 5 },
        .{ .model = undefined, .color = undefined, .shape = .cube, .entity_id = 3, .entity_generation = 0 },
    };
    std.mem.sort(mesh.Drawable, &drawables, {}, drawnBefore);
    var order: [4]u32 = undefined;
    for (&order, drawables) |*id, drawable| id.* = drawable.entity_id;
    try std.testing.expectEqualSlices(u32, &.{ 3, 1, 2, 0 }, &order);
}
