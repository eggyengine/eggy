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
const math = @import("eggenvector");
const transform = @import("transform.zig");
const shaders = @import("scene_shaders");
const mesh = @import("mesh.zig");
const ModelCache = @import("model_cache.zig").ModelCache;
const texture_cache = @import("texture_cache.zig");
const TextureCache = texture_cache.TextureCache;
const frames_in_flight = @import("weeoui_vitellus").frames_in_flight;
const lighting = @import("lighting.zig");
const Deformation = @import("deformation.zig").Deformation;
const ShaderCache = @import("shader_cache.zig").ShaderCache;
const ShaderPipelines = @import("shader_pipelines.zig").ShaderPipelines;

/// The most visible meshes in one pass; overflow is an explicit rendering error.
pub const max_drawables = 4096;
/// The selection outline: its colour, and how wide it is in pixels.
const outline_color = [4]f32{ 1, 0.62, 0.15, 1 };
const outline_width_px: f32 = 2.5;

/// Where meshes' model files and textures come from.
pub const Sources = struct {
    models: *ModelCache,
    textures: *TextureCache,
    materials: *@import("material_cache.zig").MaterialCache,
    /// Project shaders: materials' surfaces and post passes.
    shaders: *@import("shader_cache.zig").ShaderCache,
    /// Seconds the game has run, for shaders.
    time_s: f32 = 0,
    /// The authored clips entities play; null (no authored clip plays) until the host sets it.
    clips: ?*@import("clip_cache.zig").ClipCache = null,
    lights: *const lighting.Frame,
    stats: *Stats,
    world_draw: ?*const @import("draw2d.zig").Draw2d = null,
    /// This frame's billboards' UI scenes; null for none.
    ui_billboards: ?*const @import("ui_scenes/billboards.zig").Frame = null,
};

/// The lights' exposure, fallback light and shadow light, and whether the post pass maps tones
/// (so lit surfaces skip their own curve).
fn environmentOf(lights: lighting.Frame) [4]f32 {
    return .{ lights.options[0], lights.options[1], lights.options[2], if (lights.post.mapsTones()) 1 else 0 };
}

/// Scene passes accumulated by the host during this frame, including editor camera views.
pub const Stats = struct { draw_calls: usize = 0, meshes: usize = 0, triangles: u64 = 0, culled: usize = 0 };

const CameraUniforms = @import("scene_uniforms.zig").Camera;

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
    shadow: @import("shadows.zig").Map,
    shadow_pipeline_layout: vit.PipelineLayout,
    shadow_pipeline: vit.GraphicsPipeline,
    /// The posed corners of animated models, one buffer each per entity.
    deformation: Deformation,
    /// What colour pipelines need beyond the built-in one: one per material surface shader.
    device: vit.Device,
    format: vit.Format,
    sample_count: u32,
    shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule,
    surfaces: ShaderPipelines = .{},
    /// The last surface shader reported as not a surface shader, so it is logged once.
    wrong_role_reported: u64 = 0,

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
    pub fn init(device: vit.Device, format: vit.Format, shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule, texture_layout: vit.BindGroupLayout, sample_count: u32, shadow_quality: @import("render_settings.zig").ShadowQuality) !MeshRenderer {
        // malloc, not page_allocator: on the web, growing memory behind Emscripten's back detaches its views of it.
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const geometry = try mesh.Geometry.build(arena.allocator());
        const vertices = try vit.Buffer.init(device, .{ .label = "mesh vertices", .size = geometry.vertices.len * @sizeOf(mesh.Vertex), .usage = .{ .vertex = true }, .initial_data = std.mem.sliceAsBytes(geometry.vertices) });
        errdefer vertices.deinit();
        const indices = try vit.Buffer.init(device, .{ .label = "mesh indices", .size = geometry.indices.len * @sizeOf(u32), .usage = .{ .index = true }, .initial_data = std.mem.sliceAsBytes(geometry.indices) });
        errdefer indices.deinit();

        // Per frame in flight: the instances and the camera, which the bind group holds.
        var shadow = try @import("shadows.zig").Map.init(device, shadow_quality, max_drawables);
        errdefer shadow.deinit();
        const group_layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .vertex = true, .fragment = true } },
            .{ .binding = 1, .kind = .{ .sampled_texture = .{ .sample_type = .depth } }, .visibility = .{ .fragment = true } },
            .{ .binding = 2, .kind = .{ .sampler = .comparison }, .visibility = .{ .fragment = true } },
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
                .{ .binding = 1, .resource = .{ .texture_view = shadow.view } },
                .{ .binding = 2, .resource = .{ .sampler = shadow.sampler } },
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
        errdefer mask_pipeline.deinit();
        const shadow_pipeline_layout = try vit.PipelineLayout.init(device, .{ .label = "shadow layout", .bind_group_layouts = &.{ shadow.layout, texture_layout } });
        errdefer shadow_pipeline_layout.deinit();
        const shadow_pipeline = try makePipeline(device, format, shadow_pipeline_layout, shaderSource, "directional shadow", shaders.mesh_vertex, "vertexMain", shaders.mesh_shadow_fragment, "fragmentShadow", .shadow, 1);
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
            .shadow = shadow,
            .shadow_pipeline_layout = shadow_pipeline_layout,
            .shadow_pipeline = shadow_pipeline,
            .deformation = Deformation.init(std.heap.c_allocator, device),
            .device = device,
            .format = format,
            .sample_count = sample_count,
            .shaderSource = shaderSource,
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
        self.surfaces.deinit();
        self.deformation.deinit();
        self.shadow_pipeline.deinit();
        self.shadow_pipeline_layout.deinit();
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
        self.shadow.deinit();
        self.indices.deinit();
        self.vertices.deinit();
    }

    /// Load the model files and textures `drawables` need from `sources`, and ready new
    /// textures for sampling. Call outside a render pass, before `draw`.
    /// Host-only: prepares every input before visibility filtering, borrowing valid
    /// component-backed paths. Uploads finish synchronously; failed assets are logged and cached.
    ///
    /// ```zig
    /// try renderer.prepare(scene_cmd, drawables, asset_sources);
    /// // Begin the compatible scene render pass before calling renderer.draw.
    /// ```
    pub fn prepare(self: *MeshRenderer, cmd: vit.CommandBuffer, drawables: []mesh.Drawable, sources: Sources) !void {
        _ = cmd;
        for (drawables) |*drawable| {
            if (drawable.materialFile()) |path| {
                if (sources.materials.get(path)) |material| drawable.applyMaterial(material) else drawable.material_failed = true;
            }
            if (drawable.material_failed) continue;
            if (drawable.modelFile()) |file| _ = sources.models.get(file, sources.textures);
            if (drawable.textureFile()) |file| _ = sources.textures.get(file);
        }
        // Animated models are posed once here, for the shadow, colour and selection passes alike.
        self.deformation.prepare(drawables, sources.models, sources.textures, sources.clips);
    }

    /// Draw up to `max_drawables` visible meshes, partitioning and sorting in place without
    /// losing other entities; visible overflow is an error. Draw inside the render pass in
    /// progress, whose viewport is `viewport_px`, through `view_projection` (a `camera.View`'s),
    /// outlining each of `selected`'s, with model files and textures from `sources` (`prepare`d for
    /// them). `srgb`: whether the target encodes sRGB itself.
    /// Host-only: `viewport_px` is `{ width, height }` in physical pixels, not a rectangle.
    /// The pass needs the configured color format and `.d32_float` depth; caller owns
    /// viewport/scissor and in-flight-slot fencing. Buffer upload errors propagate.
    ///
    /// ```zig
    /// // Inside the compatible render pass, after prepare:
    /// try renderer.draw(scene_cmd, drawables, asset_sources, clip_from_world, .{ 1280, 720 }, selected_entities, target_is_srgb);
    /// ```
    pub fn draw(self: *MeshRenderer, cmd: vit.CommandBuffer, drawables: []mesh.Drawable, sources: Sources, view_projection: math.Mat4, viewport_px: math.Vec2, eye: math.Vec3, selected: []const ecs.EntityId, srgb: bool) !void {
        const sorted = visibleFirst(drawables, sources, view_projection);
        sources.stats.culled += drawables.len - sorted.len;
        if (sorted.len > max_drawables) return error.TooManyVisibleMeshes;
        if (sorted.len == 0) return;
        for (sorted) |drawable| if (!drawable.material_failed) {
            sources.stats.meshes += 1;
        };
        self.slot = (self.slot + 1) % frames_in_flight;

        // Sort so each shape's, then each model file's, with the same texture are one instanced
        // draw; then upload them and the camera.
        std.mem.sort(mesh.Drawable, sorted, {}, drawnBefore);
        try upload(self.instances[self.slot], std.mem.sliceAsBytes(sorted));
        const camera = CameraUniforms{ .view_projection = transform.columns(view_projection), .options = .{ if (srgb) 1 else 0, 0, 0, 0 }, .outline = outline_color, .outline_size = .{ viewport_px.x, viewport_px.y, outline_width_px, 0 }, .eye = .{ eye.x, eye.y, eye.z, 0 }, .light_info = .{ @floatFromInt(sources.lights.count), sources.time_s, 0, 0 }, .lights = sources.lights.lights, .ambient = sources.lights.ambient, .environment = environmentOf(sources.lights.*), .shadow_matrix = self.shadow.matrix, .shadow_params = self.shadow.params };
        try upload(self.uniforms[self.slot], std.mem.asBytes(&camera));

        // Vitellus binds groups through the pipeline set, so the mesh pipeline goes first; surface
        // shaders' pipelines share its layout and keep the groups.
        cmd.setGraphicsPipeline(self.pipeline);
        cmd.setBindGroup(0, self.groups[self.slot], &.{});
        cmd.setVertexBuffer(1, self.instances[self.slot], 0);

        // One instanced draw per run of the same shape or model file and texture, per part,
        // each surface shader's runs together under its pipeline.
        var start: usize = 0;
        while (start < sorted.len) {
            var end = start + 1;
            while (end < sorted.len and !drawnBefore({}, sorted[start], sorted[end])) end += 1;
            const shader = sorted[start].shaderFile() orelse "";
            if (start == 0 or !std.mem.eql(u8, shader, sorted[start - 1].shaderFile() orelse ""))
                cmd.setGraphicsPipeline(if (shader.len == 0) self.pipeline else self.surfacePipeline(shader, sources.shaders) orelse self.pipeline);
            self.drawRun(cmd, sources, sorted[start], @intCast(start), @intCast(end - start));
            start = end;
        }

        // Each selected entity's mask, then its outline wherever the mask isn't.
        for (selected) |entity| for (sorted, 0..) |drawable, i| if (drawable.entity().eql(entity)) {
            for ([_]vit.GraphicsPipeline{ self.mask_pipeline, self.outline_pipeline }) |pass| {
                cmd.setGraphicsPipeline(pass);
                self.drawRun(cmd, sources, drawable, @intCast(i), 1);
            }
        };
    }

    // The colour pipeline for surface shader `key`, made the first time; null (Eggy's own
    // surface) when it doesn't load or isn't a surface shader.
    fn surfacePipeline(self: *MeshRenderer, key: []const u8, cache: *ShaderCache) ?vit.GraphicsPipeline {
        const loaded = cache.get(key) orelse return null;
        if (self.surfaces.get(key, cache.revision)) |known| return known;
        if (loaded.role != .surface) {
            const hash = std.hash.Wyhash.hash(0, key);
            if (self.wrong_role_reported != hash) std.log.err("material shader {s} is a {t} shader, not a surface shader: drawn without it", .{ key, loaded.role });
            self.wrong_role_reported = hash;
            return null;
        }
        const vs = vit.Shader.init(self.device, .{ .label = "mesh", .stage = .vertex, .source = self.shaderSource(shaders.mesh_vertex, "vertexMain") }) catch |err| {
            std.log.err("cannot make surface {s}: {t}", .{ key, err });
            return null;
        };
        defer vs.deinit();
        const pipeline = pipelineOf(self.device, self.format, self.pipeline_layout, "surface shader", vs, loaded.fragment, .drawn, self.sample_count) catch |err| {
            std.log.err("cannot make surface {s}: {t}", .{ key, err });
            return null;
        };
        return self.surfaces.put(key, pipeline);
    }

    /// Record depth outside the color pass, with separate storage for in-flight shadow draws.
    pub fn renderShadow(self: *MeshRenderer, cmd: vit.CommandBuffer, drawables: []mesh.Drawable, sources: Sources, view: @import("camera.zig").View, aspect: f32, settings: @import("render_settings.zig").Settings) !void {
        const enabled = self.shadow.fit(view, aspect, sources.lights, settings);
        if (!enabled and self.shadow.initialized) return;
        const casters = if (enabled) castersFirst(visibleFirst(drawables, sources, math.fromArray(f32, 4, 4, self.shadow.matrix))) else drawables[0..0];
        if (casters.len > max_drawables) return error.TooManyShadowMeshes;
        self.shadow.slot = (self.shadow.slot + 1) % frames_in_flight;
        const slot = self.shadow.slot;
        if (enabled) {
            try upload(self.shadow.instances[slot], std.mem.sliceAsBytes(casters));
            const uniforms = CameraUniforms{ .view_projection = self.shadow.matrix };
            try upload(self.shadow.uniforms[slot], std.mem.asBytes(&uniforms));
        }
        try cmd.barrier(&.{.{ .texture = .{ .texture = self.shadow.texture, .before = if (self.shadow.initialized) .sampled else .common, .after = .depth_stencil_write } }});
        try cmd.beginRenderPass(.{ .label = "directional shadows", .color_attachments = &.{}, .depth_stencil_attachment = .{ .view = self.shadow.view, .depth_clear = 1, .depth_store_op = .store } });
        if (enabled) {
            const size: f32 = @floatFromInt(self.shadow.resolution);
            cmd.setViewport(.{ .width = size, .height = size });
            cmd.setScissor(.{ .x = 0, .y = 0, .width = self.shadow.resolution, .height = self.shadow.resolution });
            cmd.setGraphicsPipeline(self.shadow_pipeline);
            cmd.setBindGroup(0, self.shadow.groups[slot], &.{});
            cmd.setVertexBuffer(1, self.shadow.instances[slot], 0);
            const saved_slot = self.slot;
            self.slot = slot;
            defer self.slot = saved_slot;
            for (casters, 0..) |drawable, index| self.drawRun(cmd, sources, drawable, @intCast(index), 1);
        }
        cmd.endRenderPass();
        try cmd.barrier(&.{.{ .texture = .{ .texture = self.shadow.texture, .before = .depth_stencil_write, .after = .sampled } }});
        self.shadow.initialized = true;
    }

    /// Draw `count` instances from `first` of `drawable`'s shape or model file, each part with
    /// its texture. A model file that can't be drawn draws nothing.
    fn drawRun(self: *MeshRenderer, cmd: vit.CommandBuffer, sources: Sources, drawable: mesh.Drawable, first: u32, count: u32) void {
        if (drawable.material_failed) return;
        const own = if (drawable.textureFile()) |file| sources.textures.get(file) else null;
        if (drawable.modelFile()) |file| {
            const model = sources.models.get(file, sources.textures) orelse return;
            cmd.setVertexBuffer(0, self.deformation.vertices(drawable) orelse model.vertices, 0);
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
        const range = self.ranges[@backingInt(drawable.shape)];
        cmd.drawIndexed(range.index_count, count, range.first_index, 0, first);
        sources.stats.draw_calls += 1;
        sources.stats.triangles += @as(u64, range.index_count / 3) * count;
    }
};

/// Partition by swapping rather than compacting: another viewport still needs every entity.
/// Move what doesn't cast a shadow (the editor's stand-ins) after the rest, in place; returns the rest.
fn castersFirst(drawables: []mesh.Drawable) []mesh.Drawable {
    var end = drawables.len;
    var index: usize = 0;
    while (index < end) {
        if (drawables[index].casts_shadow != 0) {
            index += 1;
        } else {
            end -= 1;
            std.mem.swap(mesh.Drawable, &drawables[index], &drawables[end]);
        }
    }
    return drawables[0..end];
}

fn visibleFirst(drawables: []mesh.Drawable, sources: Sources, matrix: math.Mat4) []mesh.Drawable {
    var end = drawables.len;
    var index: usize = 0;
    while (index < end) {
        const drawable = drawables[index];
        const bounds = if (drawable.modelFile()) |path| block: {
            const cached = sources.models.get(path, sources.textures) orelse {
                end -= 1;
                std.mem.swap(mesh.Drawable, &drawables[index], &drawables[end]);
                continue;
            };
            // A posed model is measured as posed; others by the box holding every pose they reach.
            if (drawable.deformed != 0) break :block @import("bounds.zig").Bounds{ .min = drawable.bounds_min, .max = drawable.bounds_max };
            break :block @import("bounds.zig").Bounds{ .min = cached.bounds.min, .max = cached.bounds.max };
        } else @import("bounds.zig").Bounds.unit;
        if (!drawable.material_failed and bounds.visible(transform.columns(math.mul(f32, 4, 4, 4, matrix, math.fromArray(f32, 4, 4, drawable.model))))) {
            index += 1;
        } else {
            end -= 1;
            std.mem.swap(mesh.Drawable, &drawables[index], &drawables[end]);
        }
    }
    return drawables[0..end];
}

test "visibility partition retains every entity for a second viewport" {
    const identity: [4][4]f32 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
    var drawables = [_]mesh.Drawable{
        .{ .model = identity, .color = @splat(1), .shape = .cube, .entity_id = 0, .entity_generation = 0 },
        .{ .model = identity, .color = @splat(1), .shape = .plane, .entity_id = 1, .entity_generation = 0 },
        .{ .model = identity, .color = @splat(1), .shape = .sphere, .entity_id = 2, .entity_generation = 0 },
    };
    drawables[0].model[3][0] = 100;
    const sources = Sources{ .models = undefined, .textures = undefined, .materials = undefined, .shaders = undefined, .lights = undefined, .stats = undefined };
    try std.testing.expectEqual(@as(usize, 2), visibleFirst(&drawables, sources, math.fromArray(f32, 4, 4, identity)).len);
    var other_view = identity;
    other_view[3][0] = -100;
    const other = visibleFirst(&drawables, sources, math.fromArray(f32, 4, 4, other_view));
    try std.testing.expectEqual(@as(usize, 1), other.len);
    try std.testing.expectEqual(@as(u32, 0), other[0].entity_id);
    var ids: u8 = 0;
    for (drawables) |drawable| ids |= @as(u8, 1) << @intCast(drawable.entity_id);
    try std.testing.expectEqual(@as(u8, 7), ids);
}

/// The order meshes are drawn in: those with Eggy's own surface first, then by surface shader;
/// within those, built-in shapes first, by shape, then model files, by path,
/// and those alike by texture. Two that neither comes before are drawn in one go.
fn drawnBefore(_: void, a: mesh.Drawable, b: mesh.Drawable) bool {
    if (a.material_failed != b.material_failed) return !a.material_failed;
    const by_shader = std.mem.order(u8, a.shaderFile() orelse "", b.shaderFile() orelse "");
    if (by_shader != .eq) return by_shader == .lt;
    const by_source = sourceOrder(a, b);
    if (by_source != .eq) return by_source == .lt;
    const by_texture = std.mem.order(u8, a.textureFile() orelse "", b.textureFile() orelse "");
    if (by_texture != .eq) return by_texture == .lt;
    // A posed model has its own vertices, so each is a run of its own.
    return posedKey(a) < posedKey(b);
}

fn posedKey(drawable: mesh.Drawable) u64 {
    return if (drawable.deformed == 0) 0 else (@as(u64, drawable.entity_generation) << 32 | drawable.entity_id) + 1;
}

fn sourceOrder(a: mesh.Drawable, b: mesh.Drawable) std.math.Order {
    const a_file = a.modelFile() orelse return if (b.modelFile() != null) .lt else std.math.order(@backingInt(a.shape), @backingInt(b.shape));
    const b_file = b.modelFile() orelse return .gt;
    return std.mem.order(u8, a_file, b_file);
}

/// Write `bytes` to the start of `buffer`. Nothing to write (no shadow casters in view) maps
/// nothing, since a buffer can't be mapped for zero bytes.
fn upload(buffer: vit.Buffer, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const mapped = try buffer.map(.write, .{ .size = bytes.len });
    @memcpy(mapped[0..bytes.len], bytes);
    buffer.unmap(.{ .size = bytes.len });
}

/// How a pipeline meets the depth buffer: drawn as usual; the selection's mask (depth only,
/// over everything); or over everything but the mask (the outline).
const DepthUse = enum { drawn, mask, over_all_but_mask, shadow };

/// A pipeline drawing shapes into `format` with a `.d32_float` depth buffer, from the given
/// vertex and fragment shaders, labelled `label`.
fn makePipeline(device: vit.Device, format: vit.Format, layout: vit.PipelineLayout, shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule, label: []const u8, vertex: []const u8, vertex_entry: []const u8, fragment: []const u8, fragment_entry: []const u8, depth: DepthUse, sample_count: u32) !vit.GraphicsPipeline {
    const vs = try vit.Shader.init(device, .{ .label = label, .stage = .vertex, .source = shaderSource(vertex, vertex_entry) });
    defer vs.deinit();
    const fs = try vit.Shader.init(device, .{ .label = label, .stage = .fragment, .source = shaderSource(fragment, fragment_entry) });
    defer fs.deinit();
    return pipelineOf(device, format, layout, label, vs, fs, depth, sample_count);
}

/// `makePipeline` from shaders already made.
fn pipelineOf(device: vit.Device, format: vit.Format, layout: vit.PipelineLayout, label: []const u8, vs: vit.Shader, fs: vit.Shader, depth: DepthUse, sample_count: u32) !vit.GraphicsPipeline {
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
        .{ .location = 14, .format = .float32x4, .offset = @offsetOf(mesh.Drawable, "uv_rect") },
    };
    // The selection passes read fewer attributes, but WGSL keeps every input the shader
    // declares and WebGPU rejects a pipeline missing any; SPIR-V drops the ones unused.
    const all = depth == .drawn or depth == .shadow or builtin.os.tag == .emscripten;
    const instance_count: usize = if (all) instance_attributes.len else if (depth == .mask) 5 else 4;
    return vit.GraphicsPipeline.init(device, .{
        .label = label,
        .vertex = vs,
        .fragment = fs,
        .vertex_buffers = &.{
            .{ .stride = @sizeOf(mesh.Vertex), .attributes = vertex_attributes[0..if (all) vertex_attributes.len else 1] },
            .{ .stride = @sizeOf(mesh.Drawable), .step_mode = .instance, .attributes = instance_attributes[0..instance_count] },
        },
        .color_targets = if (depth == .shadow) &.{} else &.{.{ .format = format, .write_mask = if (depth == .mask) .{ .red = false, .green = false, .blue = false, .alpha = false } else .{} }},
        .depth_stencil = switch (depth) {
            .drawn, .shadow => .{ .format = .d32_float, .depth_write = true, .depth_compare = .less },
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
