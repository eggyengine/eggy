//! Draws `mesh.Drawable`s: every shape's geometry sits in one vertex and index buffer, and each
//! shape is drawn once, instanced, for every entity shown as it with the same texture; each
//! model file likewise, from its own buffers in the `ModelCache`, a draw per part, each part
//! painted with the `Mesh`'s texture or else its own. A selected entity is outlined,
//! through anything in front of it too: after the meshes, its mask goes into the depth buffer at
//! the nearest depth (without colour), then its hull, pushed outwards on screen, just behind
//! that, so the hull shows everywhere but the mask: its rim.
const std = @import("std");
const builtin = @import("builtin");
const vit = @import("vitellus");
const ecs = @import("clutch");
const shaders = @import("scene_shaders");
const mesh = @import("mesh.zig");
const ModelCache = @import("model_cache.zig").ModelCache;
const texture_cache = @import("texture_cache.zig");
const TextureCache = texture_cache.TextureCache;
const frames_in_flight = @import("weeoui_vitellus").frames_in_flight;
const lighting = @import("lighting.zig");

/// The most meshes drawn in one frame; any more are left out.
pub const max_drawables = 4096;
/// The selection outline: its colour, and how wide it is in pixels.
const outline_color = [4]f32{ 1, 0.62, 0.15, 1 };
const outline_width_px: f32 = 2.5;

/// Where meshes' model files and textures come from.
pub const Sources = struct {
    models: *ModelCache,
    textures: *TextureCache,
    materials: *@import("material_cache.zig").MaterialCache,
    lights: *const lighting.Frame,
    stats: *Stats,
    world_draw: ?*const @import("draw2d.zig").Draw2d = null,
};

/// Scene passes accumulated by the host during this frame, including editor camera views.
pub const Stats = struct { draw_calls: usize = 0, meshes: usize = 0, triangles: u64 = 0 };

const CameraUniforms = extern struct {
    view_projection: [4][4]f32,
    light: [4]f32,
    options: [4]f32,
    outline: [4]f32,
    outline_size: [4]f32,
    eye: [4]f32,
    light_info: [4]f32,
    lights: [lighting.max_lights]lighting.GpuLight,
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

    /// Build the shapes and a pipeline drawing into `format`, with a `.d32_float` depth buffer,
    /// painting with textures bound as `texture_layout` describes (`TextureCache.layout`).
    /// Host-only setup: `shaderSource` supplies backend shader modules. The device and
    /// compatible texture layout must outlive rendering; GPU/shader errors propagate.
    /// Release the returned renderer with `deinit` after queued draws finish.
    ///
    /// ```zig
    /// var renderer = try MeshRenderer.init(device, color_format, shader_source_adapter, textures.layout, graphics.render_settings.anti_aliasing.samples());
    /// defer renderer.deinit(); // Finish any GPU use before leaving this host scope.
    /// ```
    pub fn init(device: vit.Device, format: vit.Format, shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule, texture_layout: vit.BindGroupLayout, sample_count: u32) !MeshRenderer {
        // malloc, not page_allocator: on the web, growing memory behind Emscripten's back detaches its views of it.
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
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
            uniforms[i] = try vit.Buffer.init(device, .{ .label = "mesh camera", .size = @sizeOf(CameraUniforms), .usage = .{ .uniform = true }, .memory = .upload });
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

        const pipeline_layout = try vit.PipelineLayout.init(device, .{ .label = "mesh layout", .bind_group_layouts = &.{ group_layout, texture_layout } });
        errdefer pipeline_layout.deinit();
        const pipeline = try makePipeline(device, format, pipeline_layout, shaderSource, "mesh", shaders.mesh_vertex, "vertexMain", shaders.mesh_fragment, "fragmentMain", .drawn, sample_count);
        errdefer pipeline.deinit();
        const outline_pipeline = try makePipeline(device, format, pipeline_layout, shaderSource, "outline", shaders.outline_vertex, "vertexOutline", shaders.outline_fragment, "fragmentOutline", .over_all_but_mask, sample_count);
        errdefer outline_pipeline.deinit();
        const mask_pipeline = try makePipeline(device, format, pipeline_layout, shaderSource, "selection mask", shaders.mask_vertex, "vertexMask", shaders.outline_fragment, "fragmentOutline", .mask, sample_count);
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
    /// Host teardown: call once before destroying the creating device.
    ///
    /// ```zig
    /// try graphics.queue.waitIdle();
    /// renderer.deinit();
    /// ```
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

    /// Load the model files and textures `drawables` need from `sources`, and ready new
    /// textures for sampling. Call outside a render pass, before `draw`.
    /// Host-only: considers at most `max_drawables`, borrowing valid component-backed
    /// paths. Uploads finish synchronously; failed assets are logged and cached.
    ///
    /// ```zig
    /// try renderer.prepare(scene_cmd, drawables, asset_sources);
    /// // Begin the compatible scene render pass before calling renderer.draw.
    /// ```
    pub fn prepare(self: *MeshRenderer, cmd: vit.CommandBuffer, drawables: []mesh.Drawable, sources: Sources) !void {
        _ = self;
        _ = cmd;
        for (drawables[0..@min(drawables.len, max_drawables)]) |*drawable| {
            if (drawable.materialFile()) |path| {
                if (sources.materials.get(path)) |material| drawable.applyMaterial(material) else drawable.material_failed = true;
            }
            if (drawable.material_failed) continue;
            if (drawable.modelFile()) |file| _ = sources.models.get(file, sources.textures);
            if (drawable.textureFile()) |file| _ = sources.textures.get(file);
        }
    }

    /// Draw `drawables` (at most `max_drawables`; they are sorted in place) in the render pass in
    /// progress, whose viewport is `viewport_px`, through `view_projection` (a `camera.View`'s),
    /// outlining `selected`'s, with model files and textures from `sources` (`prepare`d for
    /// them). `srgb`: whether the target encodes sRGB itself.
    /// Host-only: `viewport_px` is `{ width, height }` in physical pixels, not a rectangle.
    /// The pass needs the configured color format and `.d32_float` depth; caller owns
    /// viewport/scissor and in-flight-slot fencing. Buffer upload errors propagate.
    ///
    /// ```zig
    /// // Inside the compatible render pass, after prepare:
    /// try renderer.draw(scene_cmd, drawables, asset_sources, clip_from_world, .{ 1280, 720 }, selected_entity, target_is_srgb);
    /// ```
    pub fn draw(self: *MeshRenderer, cmd: vit.CommandBuffer, drawables: []mesh.Drawable, sources: Sources, view_projection: [4][4]f32, viewport_px: [2]f32, eye: [3]f32, selected: ?ecs.EntityId, srgb: bool) !void {
        const sorted = drawables[0..@min(drawables.len, max_drawables)];
        if (sorted.len == 0) return;
        for (sorted) |drawable| if (!drawable.material_failed) {
            sources.stats.meshes += 1;
        };
        self.slot = (self.slot + 1) % frames_in_flight;

        // Sort so each shape's, then each model file's, with the same texture are one instanced
        // draw; then upload them and the camera.
        std.mem.sort(mesh.Drawable, sorted, {}, drawnBefore);
        try upload(self.instances[self.slot], std.mem.sliceAsBytes(sorted));
        const camera = CameraUniforms{ .view_projection = view_projection, .light = .{ 0.4, 1, 0.6, 0 }, .options = .{ if (srgb) 1 else 0, 0, 0, 0 }, .outline = outline_color, .outline_size = .{ viewport_px[0], viewport_px[1], outline_width_px, 0 }, .eye = .{ eye[0], eye[1], eye[2], 0 }, .light_info = .{ @floatFromInt(sources.lights.count), 0, 0, 0 }, .lights = sources.lights.lights };
        try upload(self.uniforms[self.slot], std.mem.asBytes(&camera));

        cmd.setBindGroup(0, self.groups[self.slot], &.{});
        cmd.setVertexBuffer(1, self.instances[self.slot], 0);

        // One instanced draw per run of the same shape or model file and texture, per part.
        cmd.setGraphicsPipeline(self.pipeline);
        var start: usize = 0;
        while (start < sorted.len) {
            var end = start + 1;
            while (end < sorted.len and !drawnBefore({}, sorted[start], sorted[end])) end += 1;
            self.drawRun(cmd, sources, sorted[start], @intCast(start), @intCast(end - start));
            start = end;
        }

        // The selected entity's mask, then its outline wherever the mask isn't.
        if (selected) |entity| for (sorted, 0..) |drawable, i| if (drawable.entity().eql(entity)) {
            for ([_]vit.GraphicsPipeline{ self.mask_pipeline, self.outline_pipeline }) |pass| {
                cmd.setGraphicsPipeline(pass);
                self.drawRun(cmd, sources, drawable, @intCast(i), 1);
            }
        };
    }

    /// Draw `count` instances from `first` of `drawable`'s shape or model file, each part with
    /// its texture. A model file that can't be drawn draws nothing.
    fn drawRun(self: *MeshRenderer, cmd: vit.CommandBuffer, sources: Sources, drawable: mesh.Drawable, first: u32, count: u32) void {
        if (drawable.material_failed) return;
        const own = if (drawable.textureFile()) |file| sources.textures.get(file) else null;
        if (drawable.modelFile()) |file| {
            const model = sources.models.get(file, sources.textures) orelse return;
            cmd.setVertexBuffer(0, model.vertices, 0);
            cmd.setIndexBuffer(model.indices, .uint32, 0);
            for (model.parts) |part| {
                const paint = own orelse part.texture orelse sources.textures.white;
                cmd.setBindGroup(1, paint.group, &.{});
                cmd.drawIndexed(part.index_count, count, part.first_index, 0, first);
                sources.stats.draw_calls += 1;
                sources.stats.triangles += @as(u64, part.index_count / 3) * count;
            }
            return;
        }
        cmd.setVertexBuffer(0, self.vertices, 0);
        cmd.setIndexBuffer(self.indices, .uint32, 0);
        cmd.setBindGroup(1, (own orelse sources.textures.white).group, &.{});
        const range = self.ranges[@intFromEnum(drawable.shape)];
        cmd.drawIndexed(range.index_count, count, range.first_index, 0, first);
        sources.stats.draw_calls += 1;
        sources.stats.triangles += @as(u64, range.index_count / 3) * count;
    }
};

/// The order meshes are drawn in: built-in shapes first, by shape, then model files, by path,
/// and those alike by texture. Two that neither comes before are drawn in one go.
fn drawnBefore(_: void, a: mesh.Drawable, b: mesh.Drawable) bool {
    if (a.material_failed != b.material_failed) return !a.material_failed;
    const by_source = sourceOrder(a, b);
    if (by_source != .eq) return by_source == .lt;
    return std.mem.order(u8, a.textureFile() orelse "", b.textureFile() orelse "") == .lt;
}

fn sourceOrder(a: mesh.Drawable, b: mesh.Drawable) std.math.Order {
    const a_file = a.modelFile() orelse return if (b.modelFile() != null) .lt else std.math.order(@intFromEnum(a.shape), @intFromEnum(b.shape));
    const b_file = b.modelFile() orelse return .gt;
    return std.mem.order(u8, a_file, b_file);
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
fn makePipeline(device: vit.Device, format: vit.Format, layout: vit.PipelineLayout, shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule, label: []const u8, vertex: []const u8, vertex_entry: []const u8, fragment: []const u8, fragment_entry: []const u8, depth: DepthUse, sample_count: u32) !vit.GraphicsPipeline {
    const vs = try vit.Shader.init(device, .{ .label = label, .stage = .vertex, .source = shaderSource(vertex, vertex_entry) });
    defer vs.deinit();
    const fs = try vit.Shader.init(device, .{ .label = label, .stage = .fragment, .source = shaderSource(fragment, fragment_entry) });
    defer fs.deinit();
    const vertex_attributes = [_]vit.hal.pipeline.VertexAttribute{
        .{ .location = 0, .format = .float32x3, .offset = @offsetOf(mesh.Vertex, "position") },
        .{ .location = 1, .format = .float32x3, .offset = @offsetOf(mesh.Vertex, "normal") },
        .{ .location = 7, .format = .float32x2, .offset = @offsetOf(mesh.Vertex, "uv") },
        .{ .location = 11, .format = .float32x4, .offset = @offsetOf(mesh.Vertex, "color") },
        .{ .location = 12, .format = .float32x2, .offset = @offsetOf(mesh.Vertex, "metallic_roughness") },
        .{ .location = 13, .format = .float32x3, .offset = @offsetOf(mesh.Vertex, "emissive_color") },
    };
    const instance_attributes = [_]vit.hal.pipeline.VertexAttribute{
        .{ .location = 2, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "model") },
        .{ .location = 3, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "model") + 16 },
        .{ .location = 4, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "model") + 32 },
        .{ .location = 5, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "model") + 48 },
        .{ .location = 6, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "color") },
        .{ .location = 8, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "surface_color") },
        .{ .location = 9, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "material_params") },
        .{ .location = 10, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "emissive_cutoff") },
    };
    // The selection passes read fewer attributes, but WGSL keeps every input the shader
    // declares and WebGPU rejects a pipeline missing any; SPIR-V drops the ones unused.
    const all = depth == .drawn or builtin.os.tag == .emscripten;
    const instance_count: usize = if (all) instance_attributes.len else if (depth == .mask) 5 else 4;
    return vit.GraphicsPipeline.init(device, .{
        .label = label,
        .vertex = vs,
        .fragment = fs,
        .vertex_buffers = &.{
            .{ .stride = @sizeOf(mesh.Vertex), .attributes = vertex_attributes[0..if (all) vertex_attributes.len else 1] },
            .{ .stride = @sizeOf(mesh.Drawable), .step_mode = .instance, .attributes = instance_attributes[0..instance_count] },
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
        .multisample = .{ .count = sample_count },
    });
}

test "shapes are drawn before model files, and each kind and texture together" {
    var drawables = [_]mesh.Drawable{
        .{ .model = undefined, .color = undefined, .shape = .cube, .entity_id = 0, .entity_generation = 0, .model_file = "b.glb", .model_file_len = 5 },
        .{ .model = undefined, .color = undefined, .shape = .sphere, .entity_id = 1, .entity_generation = 0 },
        .{ .model = undefined, .color = undefined, .shape = .cube, .entity_id = 2, .entity_generation = 0, .model_file = "a.glb", .model_file_len = 5 },
        .{ .model = undefined, .color = undefined, .shape = .cube, .entity_id = 3, .entity_generation = 0, .texture_file = "wood.png", .texture_file_len = 8 },
        .{ .model = undefined, .color = undefined, .shape = .cube, .entity_id = 4, .entity_generation = 0 },
    };
    std.mem.sort(mesh.Drawable, &drawables, {}, drawnBefore);
    var order: [5]u32 = undefined;
    for (&order, drawables) |*id, drawable| id.* = drawable.entity_id;
    // Plain cubes before painted ones, so each texture is one draw.
    try std.testing.expectEqualSlices(u32, &.{ 4, 3, 1, 2, 0 }, &order);
}
