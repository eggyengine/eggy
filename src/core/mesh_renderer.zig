//! Draws `mesh.Drawable`s: every shape's geometry sits in one vertex and index buffer, and each
//! shape is drawn once, instanced, for every entity shown as it with the same texture; each
//! model file likewise, from its own buffers in the `ModelCache`, a draw per part, each part
//! painted with the `Mesh`'s texture and maps or else its own. The sky goes behind them, then
//! opaque surfaces (back faces left out unless double-sided), then blended ones, farthest first,
//! without writing depth. A selected entity is outlined,
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
const ModelPart = @import("model_cache.zig").Gpu.Part;
const texture_cache = @import("texture_cache.zig");
const TextureCache = texture_cache.TextureCache;
const frames_in_flight = @import("weeoui_vitellus").frames_in_flight;
const lighting = @import("lighting.zig");
const Deformation = @import("deformation.zig").Deformation;
const ShaderCache = @import("shader_cache.zig").ShaderCache;
const ShaderPipelines = @import("shader_pipelines.zig").ShaderPipelines;
const shadows = @import("shadows.zig");
const camera_zig = @import("camera.zig");
const render_settings = @import("render_settings.zig");
const Sky = @import("sky.zig").Sky;

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

/// How a colour pipeline meets what is already drawn: blended over it or not, and which faces
/// it leaves out (a mirrored entity's turn the other way; double-sided ones none).
const Variant = struct {
    blend: bool,
    cull: vit.hal.pipeline.CullMode,

    const count = 6;

    fn index(self: Variant) u32 {
        return @as(u32, @intFromBool(self.blend)) * 3 + @as(u32, @backingInt(self.cull));
    }

    fn of(i: usize) Variant {
        return .{ .blend = i >= 3, .cull = @fromBackingInt(@intCast(i % 3)) };
    }
};

/// What a pass draws: opaque or blended surfaces in colour; every surface but blended ones
/// into a shadow map; or everything through one pipeline (the selection's).
const Pass = union(enum) {
    colour: enum { opaque_surfaces, blended_surfaces },
    shadow,
    all: vit.GraphicsPipeline,
};

/// A blended drawable: which of the sorted ones, and how far into the view its middle is.
const Blended = struct { index: u32, depth: f32 };

/// The sky's triangle, over the whole view, in clip space.
const sky_triangle = [3][2]f32{ .{ -1, -1 }, .{ 3, -1 }, .{ -1, 3 } };

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
    /// Eggy's own surface, by `Variant.index`.
    pipelines: [Variant.count]vit.GraphicsPipeline,
    outline_pipeline: vit.GraphicsPipeline,
    mask_pipeline: vit.GraphicsPipeline,
    sky_pipeline: vit.GraphicsPipeline,
    sky_vertices: vit.Buffer,
    shadow: shadows.Map,
    local_shadow: shadows.Local,
    shadow_pipeline_layout: vit.PipelineLayout,
    shadow_pipeline: vit.GraphicsPipeline,
    sky: Sky = .{},
    /// This frame's blended drawables, sorted farthest first.
    blended: [max_drawables]Blended = undefined,
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
    /// painting with textures bound as `texture_layout` describes (`TextureCache.layout`, also
    /// the sky's) and maps as `maps_layout` does (`TextureCache.maps.layout`).
    /// Host-only setup: `shaderSource` supplies backend shader modules. The device and
    /// compatible texture layout must outlive rendering; GPU/shader errors propagate.
    /// Release the returned renderer with `deinit` after queued draws finish.
    ///
    /// ```zig
    /// var renderer = try MeshRenderer.init(device, color_format, shader_source_adapter, textures.layout, textures.maps.layout, samples, .medium);
    /// defer renderer.deinit(); // Finish any GPU use before leaving this host scope.
    /// ```
    pub fn init(device: vit.Device, format: vit.Format, shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule, texture_layout: vit.BindGroupLayout, maps_layout: vit.BindGroupLayout, sample_count: u32, shadow_quality: render_settings.ShadowQuality) !MeshRenderer {
        // malloc, not page_allocator: on the web, growing memory behind Emscripten's back detaches its views of it.
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const geometry = try mesh.Geometry.build(arena.allocator());
        const vertices = try vit.Buffer.init(device, .{ .label = "mesh vertices", .size = geometry.vertices.len * @sizeOf(mesh.Vertex), .usage = .{ .vertex = true }, .initial_data = std.mem.sliceAsBytes(geometry.vertices) });
        errdefer vertices.deinit();
        const indices = try vit.Buffer.init(device, .{ .label = "mesh indices", .size = geometry.indices.len * @sizeOf(u32), .usage = .{ .index = true }, .initial_data = std.mem.sliceAsBytes(geometry.indices) });
        errdefer indices.deinit();

        // Per frame in flight: the instances and the camera, which the bind group holds.
        var shadow = try shadows.Map.init(device, shadow_quality, max_drawables);
        errdefer shadow.deinit();
        var local_shadow = try shadows.Local.init(device, shadow_quality, shadow.layout, max_drawables);
        errdefer local_shadow.deinit();
        const group_layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .vertex = true, .fragment = true } },
            .{ .binding = 1, .kind = .{ .sampled_texture = .{ .sample_type = .depth } }, .visibility = .{ .fragment = true } },
            .{ .binding = 2, .kind = .{ .sampler = .comparison }, .visibility = .{ .fragment = true } },
            .{ .binding = 3, .kind = .{ .sampled_texture = .{ .sample_type = .depth } }, .visibility = .{ .fragment = true } },
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
                .{ .binding = 3, .resource = .{ .texture_view = local_shadow.view } },
            } });
        }
        errdefer for (instances, uniforms, groups) |instance, uniform, group| {
            group.deinit();
            uniform.deinit();
            instance.deinit();
        };

        // Sets: the camera, lights and shadow maps; the colour texture; the other maps; the sky.
        const pipeline_layout = try vit.PipelineLayout.init(device, .{ .label = "mesh layout", .bind_group_layouts = &.{ group_layout, texture_layout, maps_layout, texture_layout } });
        errdefer pipeline_layout.deinit();
        var pipelines: [Variant.count]vit.GraphicsPipeline = undefined;
        {
            const vs = try vit.Shader.init(device, .{ .label = "mesh", .stage = .vertex, .source = shaderSource(shaders.mesh_vertex, "vertexMain") });
            defer vs.deinit();
            const fs = try vit.Shader.init(device, .{ .label = "mesh", .stage = .fragment, .source = shaderSource(shaders.mesh_fragment, "fragmentMain") });
            defer fs.deinit();
            for (&pipelines, 0..) |*made, i| {
                errdefer for (pipelines[0..i]) |earlier| earlier.deinit();
                made.* = try pipelineOf(device, format, pipeline_layout, "mesh", vs, fs, .{ .colour = .of(i) }, sample_count);
            }
        }
        errdefer for (pipelines) |made| made.deinit();
        const outline_pipeline = try makePipeline(device, format, pipeline_layout, shaderSource, "outline", shaders.outline_vertex, "vertexOutline", shaders.outline_fragment, "fragmentOutline", .over_all_but_mask, sample_count);
        errdefer outline_pipeline.deinit();
        const mask_pipeline = try makePipeline(device, format, pipeline_layout, shaderSource, "selection mask", shaders.mask_vertex, "vertexMask", shaders.outline_fragment, "fragmentOutline", .mask, sample_count);
        errdefer mask_pipeline.deinit();
        const sky_pipeline = try makePipeline(device, format, pipeline_layout, shaderSource, "sky", shaders.sky_vertex, "vertexSky", shaders.sky_fragment, "fragmentSky", .sky, sample_count);
        errdefer sky_pipeline.deinit();
        const sky_vertices = try vit.Buffer.init(device, .{ .label = "sky triangle", .size = @sizeOf(@TypeOf(sky_triangle)), .usage = .{ .vertex = true }, .initial_data = std.mem.asBytes(&sky_triangle) });
        errdefer sky_vertices.deinit();
        const shadow_pipeline_layout = try vit.PipelineLayout.init(device, .{ .label = "shadow layout", .bind_group_layouts = &.{ shadow.layout, texture_layout, maps_layout } });
        errdefer shadow_pipeline_layout.deinit();
        const shadow_pipeline = try makePipeline(device, format, shadow_pipeline_layout, shaderSource, "shadow", shaders.mesh_vertex, "vertexMain", shaders.mesh_shadow_fragment, "fragmentShadow", .shadow, 1);
        return .{
            .vertices = vertices,
            .indices = indices,
            .ranges = geometry.ranges,
            .instances = instances,
            .uniforms = uniforms,
            .groups = groups,
            .group_layout = group_layout,
            .pipeline_layout = pipeline_layout,
            .pipelines = pipelines,
            .outline_pipeline = outline_pipeline,
            .mask_pipeline = mask_pipeline,
            .sky_pipeline = sky_pipeline,
            .sky_vertices = sky_vertices,
            .shadow = shadow,
            .local_shadow = local_shadow,
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
        self.sky_vertices.deinit();
        self.sky_pipeline.deinit();
        self.mask_pipeline.deinit();
        self.outline_pipeline.deinit();
        for (self.pipelines) |made| made.deinit();
        self.pipeline_layout.deinit();
        for (self.instances, self.uniforms, self.groups) |instance, uniform, group| {
            group.deinit();
            uniform.deinit();
            instance.deinit();
        }
        self.group_layout.deinit();
        self.local_shadow.deinit();
        self.shadow.deinit();
        self.indices.deinit();
        self.vertices.deinit();
    }

    /// Load the model files, textures and sky `drawables` and the lights need from `sources`,
    /// and ready new textures for sampling. Call outside a render pass, before `draw`.
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
            if (drawable.material) |material| for (material.maps()) |map| if (map.len != 0) {
                _ = sources.textures.get(map.key());
            };
        }
        const lights = sources.lights;
        self.sky.update(sources.textures, if (lights.sky_file) |file| file[0..lights.sky_file_len] else null);
        // Animated models are posed once here, for the shadow, colour and selection passes alike.
        self.deformation.prepare(drawables, sources.models, sources.textures, sources.clips);
    }

    /// Draw the sky, if the lights have one, and up to `max_drawables` visible meshes,
    /// partitioning and sorting in place without losing other entities; visible overflow is an
    /// error. Draw inside the render pass in progress, whose viewport is `viewport_px`, as `view`
    /// sees `aspect` wide for each unit tall, outlining each of `selected`'s, with model files
    /// and textures from `sources` (`prepare`d for them). `srgb`: whether the target encodes
    /// sRGB itself.
    /// Host-only: `viewport_px` is `{ width, height }` in physical pixels, not a rectangle.
    /// The pass needs the configured color format and `.d32_float` depth; caller owns
    /// viewport/scissor and in-flight-slot fencing. Buffer upload errors propagate.
    ///
    /// ```zig
    /// // Inside the compatible render pass, after prepare:
    /// try renderer.draw(scene_cmd, drawables, asset_sources, view, 16.0 / 9.0, .init(1280, 720), selected_entities, target_is_srgb);
    /// ```
    pub fn draw(self: *MeshRenderer, cmd: vit.CommandBuffer, drawables: []mesh.Drawable, sources: Sources, view: camera_zig.View, aspect: f32, viewport_px: math.Vec2, selected: []const ecs.EntityId, srgb: bool) !void {
        const view_projection = view.viewProjection(aspect);
        const sorted = visibleFirst(drawables, sources, view_projection);
        sources.stats.culled += drawables.len - sorted.len;
        if (sorted.len > max_drawables) return error.TooManyVisibleMeshes;
        const sky = self.sky.texture;
        if (sorted.len == 0 and sky == null) return;
        for (sorted) |drawable| if (!drawable.material_failed) {
            sources.stats.meshes += 1;
        };
        self.slot = (self.slot + 1) % frames_in_flight;

        // Sort so each shape's, then each model file's, with the same texture are one instanced
        // draw; then upload them and the camera.
        std.mem.sort(mesh.Drawable, sorted, {}, drawnBefore);
        try upload(self.instances[self.slot], std.mem.sliceAsBytes(sorted));
        try upload(self.uniforms[self.slot], std.mem.asBytes(&self.cameraUniforms(sources, view, aspect, viewport_px, srgb)));

        // Vitellus binds groups through the pipeline set, so a colour pipeline goes first; the
        // rest share its layout and keep the groups. WebGPU wants every set bound before a draw.
        cmd.setGraphicsPipeline(self.pipelines[0]);
        cmd.setBindGroup(0, self.groups[self.slot], &.{});
        cmd.setBindGroup(1, sources.textures.white.group, &.{});
        if (sources.textures.mapsGroup(@splat(null), 0.01)) |neutral| cmd.setBindGroup(2, neutral, &.{});
        cmd.setBindGroup(3, (sky orelse sources.textures.white).group, &.{});
        if (sky != null) {
            cmd.setGraphicsPipeline(self.sky_pipeline);
            cmd.setVertexBuffer(0, self.sky_vertices, 0);
            cmd.draw(sky_triangle.len, 1, 0, 0);
            sources.stats.draw_calls += 1;
        }
        if (sorted.len == 0) return;
        cmd.setVertexBuffer(1, self.instances[self.slot], 0);

        // One instanced draw per run of the same shape or model file and texture, per part.
        var start: usize = 0;
        while (start < sorted.len) {
            var end = start + 1;
            while (end < sorted.len and !drawnBefore({}, sorted[start], sorted[end])) end += 1;
            self.drawRun(cmd, sources, sorted[start], @intCast(start), @intCast(end - start), .{ .colour = .opaque_surfaces });
            start = end;
        }

        // Blended surfaces over them, each on its own and farthest first, so what is nearer
        // mixes over what is behind.
        const blended = self.blendedFarthestFirst(sorted, sources, view_projection);
        for (blended) |entry| self.drawRun(cmd, sources, sorted[entry.index], entry.index, 1, .{ .colour = .blended_surfaces });

        // Each selected entity's mask, then its outline wherever the mask isn't.
        for (selected) |entity| for (sorted, 0..) |drawable, i| if (drawable.entity().eql(entity)) {
            for ([_]vit.GraphicsPipeline{ self.mask_pipeline, self.outline_pipeline }) |pipeline| {
                self.drawRun(cmd, sources, drawable, @intCast(i), 1, .{ .all = pipeline });
            }
        };
    }

    fn cameraUniforms(self: *const MeshRenderer, sources: Sources, view: camera_zig.View, aspect: f32, viewport_px: math.Vec2, srgb: bool) CameraUniforms {
        const lights = sources.lights;
        var uniforms = CameraUniforms{
            .view_projection = transform.columns(view.viewProjection(aspect)),
            .options = .{ if (srgb) 1 else 0, 0, 0, 0 },
            .outline = outline_color,
            .outline_size = .{ viewport_px.x, viewport_px.y, outline_width_px, 0 },
            .eye = .{ view.eye.x, view.eye.y, view.eye.z, 0 },
            .light_info = .{ @floatFromInt(lights.count), sources.time_s, 0, 0 },
            .lights = lights.lights,
            .ambient = lights.ambient,
            .environment = environmentOf(lights.*),
            .shadow_matrix = self.shadow.matrix,
            .shadow_params = self.shadow.params,
            .local_shadow_params = .{ 1 / @as(f32, @floatFromInt(self.local_shadow.resolution)), shadows.local_maps_across, 0, 0 },
        };
        // Without maps drawn this frame, every local light reads as unshadowed.
        for (self.local_shadow.matrices[0..self.local_shadow.count], 0..) |matrix, map| uniforms.local_shadow_matrices[map] = matrix;
        if (self.sky.texture != null) {
            uniforms.sky_rays = skyRays(view, aspect);
            uniforms.sky = .{ lights.sky[0], lights.sky[1], self.sky.mip_count, 0 };
            uniforms.sky_light = self.sky.light;
        }
        return uniforms;
    }

    /// `sorted`'s drawables with anything blended, farthest first.
    fn blendedFarthestFirst(self: *MeshRenderer, sorted: []const mesh.Drawable, sources: Sources, view_projection: math.Mat4) []const Blended {
        const columns = transform.columns(view_projection);
        var count: usize = 0;
        for (sorted, 0..) |drawable, index| {
            if (!hasBlended(drawable, sources)) continue;
            // Depth through the view, of the drawable's middle: its origin, which is where it
            // is placed.
            const centre = drawable.model[3];
            var clip: [4]f32 = @splat(0);
            for (columns, centre) |column, coordinate| {
                for (&clip, column) |*value, entry| value.* += entry * coordinate;
            }
            self.blended[count] = .{ .index = @intCast(index), .depth = clip[2] / @max(@abs(clip[3]), 1e-6) };
            count += 1;
        }
        std.mem.sort(Blended, self.blended[0..count], {}, fartherFirst);
        return self.blended[0..count];
    }
    // The colour pipeline for surface shader `key`, made the first time; null (Eggy's own
    // surface) when it doesn't load or isn't a surface shader.
    fn surfacePipeline(self: *MeshRenderer, key: []const u8, variant: Variant, cache: *ShaderCache) ?vit.GraphicsPipeline {
        const loaded = cache.get(key) orelse return null;
        if (self.surfaces.get(key, variant.index(), cache.revision)) |known| return known;
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
        const pipeline = pipelineOf(self.device, self.format, self.pipeline_layout, "surface shader", vs, loaded.fragment, .{ .colour = variant }, self.sample_count) catch |err| {
            std.log.err("cannot make surface {s}: {t}", .{ key, err });
            return null;
        };
        return self.surfaces.put(key, variant.index(), pipeline);
    }

    /// The colour pipeline for `drawable`'s surface shader (Eggy's own without one, or when it
    /// can't be used) as `variant`.
    fn colourPipeline(self: *MeshRenderer, drawable: mesh.Drawable, variant: Variant, sources: Sources) vit.GraphicsPipeline {
        const own = self.pipelines[variant.index()];
        const key = drawable.shaderFile() orelse return own;
        return self.surfacePipeline(key, variant, sources.shaders) orelse own;
    }

    /// Record the shadow maps outside the color pass: the directional light's, then point and
    /// spot lights', each with storage of its own for in-flight shadow draws.
    pub fn renderShadow(self: *MeshRenderer, cmd: vit.CommandBuffer, drawables: []mesh.Drawable, sources: Sources, view: camera_zig.View, aspect: f32, settings: render_settings.Settings) !void {
        try self.renderDirectionalShadow(cmd, drawables, sources, view, aspect, settings);
        try self.renderLocalShadows(cmd, drawables, sources, settings);
    }

    fn renderDirectionalShadow(self: *MeshRenderer, cmd: vit.CommandBuffer, drawables: []mesh.Drawable, sources: Sources, view: camera_zig.View, aspect: f32, settings: render_settings.Settings) !void {
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
            cmd.setBindGroup(0, self.shadow.groups[slot], &.{0});
            cmd.setVertexBuffer(1, self.shadow.instances[slot], 0);
            for (casters, 0..) |drawable, index| self.drawRun(cmd, sources, drawable, @intCast(index), 1, .shadow);
        }
        cmd.endRenderPass();
        try cmd.barrier(&.{.{ .texture = .{ .texture = self.shadow.texture, .before = .depth_stencil_write, .after = .sampled } }});
        self.shadow.initialized = true;
    }

    // Each point and spot light's maps, in the squares of their shared texture.
    fn renderLocalShadows(self: *MeshRenderer, cmd: vit.CommandBuffer, drawables: []mesh.Drawable, sources: Sources, settings: render_settings.Settings) !void {
        const local = &self.local_shadow;
        const count = if (settings.shadow_quality == .off) 0 else local.fit(sources.lights);
        local.count = count;
        if (count == 0 and local.initialized) return;
        const casters = castersFirst(drawables);
        if (casters.len > max_drawables) return error.TooManyShadowMeshes;
        local.slot = (local.slot + 1) % frames_in_flight;
        const slot = local.slot;
        if (count > 0) {
            try upload(local.instances[slot], std.mem.sliceAsBytes(casters));
            try local.upload(slot);
        }
        try cmd.barrier(&.{.{ .texture = .{ .texture = local.texture, .before = if (local.initialized) .sampled else .common, .after = .depth_stencil_write } }});
        try cmd.beginRenderPass(.{ .label = "local shadows", .color_attachments = &.{}, .depth_stencil_attachment = .{ .view = local.view, .depth_clear = 1, .depth_store_op = .store } });
        if (count > 0) {
            cmd.setGraphicsPipeline(self.shadow_pipeline);
            cmd.setVertexBuffer(1, local.instances[slot], 0);
            for (local.matrices[0..count], 0..) |matrix, map| {
                const square = local.rect(map);
                cmd.setViewport(.{ .x = @floatFromInt(square.x), .y = @floatFromInt(square.y), .width = @floatFromInt(square.width), .height = @floatFromInt(square.height) });
                cmd.setScissor(square);
                cmd.setBindGroup(0, local.groups[slot], &.{shadows.Local.offset(map)});
                const seen_from = math.fromArray(f32, 4, 4, matrix);
                for (casters, 0..) |drawable, index| if (visibleThrough(drawable, sources, seen_from)) {
                    self.drawRun(cmd, sources, drawable, @intCast(index), 1, .shadow);
                };
            }
        }
        cmd.endRenderPass();
        try cmd.barrier(&.{.{ .texture = .{ .texture = local.texture, .before = .depth_stencil_write, .after = .sampled } }});
        local.initialized = true;
    }

    /// Draw `count` instances from `first` of `drawable`'s shape or model file, each part (that
    /// `pass` draws) with its textures and maps. A model file that can't be drawn draws nothing.
    fn drawRun(self: *MeshRenderer, cmd: vit.CommandBuffer, sources: Sources, drawable: mesh.Drawable, first: u32, count: u32, pass: Pass) void {
        if (drawable.material_failed) return;
        const own = if (drawable.textureFile()) |file| sources.textures.get(file) else null;
        if (drawable.modelFile()) |file| {
            const model = sources.models.get(file, sources.textures) orelse return;
            cmd.setVertexBuffer(0, self.deformation.vertices(drawable) orelse model.vertices, 0);
            cmd.setIndexBuffer(model.indices, .uint32, 0);
            for (model.parts) |part| {
                const look = lookOf(drawable, part);
                if (!self.usePipeline(cmd, drawable, look, pass, sources)) continue;
                const paint = own orelse part.texture orelse sources.textures.white;
                cmd.setBindGroup(1, paint.group, &.{});
                if (mapsOf(drawable, part, sources)) |group| cmd.setBindGroup(2, group, &.{});
                cmd.drawIndexed(part.index_count, count, part.first_index, 0, first);
                sources.stats.draw_calls += 1;
                sources.stats.triangles += @as(u64, part.index_count / 3) * count;
            }
            return;
        }
        if (!self.usePipeline(cmd, drawable, lookOf(drawable, null), pass, sources)) return;
        cmd.setVertexBuffer(0, self.vertices, 0);
        cmd.setIndexBuffer(self.indices, .uint32, 0);
        cmd.setBindGroup(1, (own orelse sources.textures.white).group, &.{});
        if (mapsOf(drawable, null, sources)) |group| cmd.setBindGroup(2, group, &.{});
        const range = self.ranges[@backingInt(drawable.shape)];
        cmd.drawIndexed(range.index_count, count, range.first_index, 0, first);
        sources.stats.draw_calls += 1;
        sources.stats.triangles += @as(u64, range.index_count / 3) * count;
    }

    /// Set the pipeline `pass` draws a surface that looks as `look` with; false when the pass
    /// leaves it out.
    fn usePipeline(self: *MeshRenderer, cmd: vit.CommandBuffer, drawable: mesh.Drawable, look: Look, pass: Pass, sources: Sources) bool {
        switch (pass) {
            .colour => |surfaces| {
                if (look.blend != (surfaces == .blended_surfaces)) return false;
                cmd.setGraphicsPipeline(self.colourPipeline(drawable, .{ .blend = look.blend, .cull = cullOf(drawable, look) }, sources));
            },
            // A blended surface lets light through, so it throws no shadow.
            .shadow => if (look.blend) return false,
            .all => |pipeline| cmd.setGraphicsPipeline(pipeline),
        }
        return true;
    }
};

/// How a surface shows: blended or not, and whether its back faces do.
const Look = struct { blend: bool, double_sided: bool };

/// An authored material decides for the whole drawable; without one a model's part decides for
/// itself, and anything else (a shape, a sprite) as the drawable says.
fn lookOf(drawable: mesh.Drawable, part: ?ModelPart) Look {
    if (drawable.material == null) if (part) |own| return .{ .blend = own.alpha_mode == .blend, .double_sided = own.double_sided };
    return .{ .blend = drawable.alpha_blend != 0, .double_sided = drawable.double_sided != 0 };
}

/// Which faces to leave out: none for a double-sided surface, else the back, which a mirroring
/// transform turns to the front.
fn cullOf(drawable: mesh.Drawable, look: Look) vit.hal.pipeline.CullMode {
    if (look.double_sided) return .none;
    const m = drawable.model;
    const determinant = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[1][0] * (m[0][1] * m[2][2] - m[0][2] * m[2][1]) + m[2][0] * (m[0][1] * m[1][2] - m[0][2] * m[1][1]);
    return if (determinant < 0) .front else .back;
}

/// The maps group for `drawable`'s surface: each of its material's maps, else `part`'s own.
fn mapsOf(drawable: mesh.Drawable, part: ?ModelPart, sources: Sources) ?vit.BindGroup {
    var set: [4]?texture_cache.Gpu = if (part) |own| own.maps else @splat(null);
    if (drawable.material) |material| for (&set, material.maps()) |*map, authored| if (authored.len != 0) {
        if (sources.textures.get(authored.key())) |loaded| map.* = loaded;
    };
    return sources.textures.mapsGroup(set, if (part) |own| own.alpha_cutoff else 0.01);
}

/// Whether anything of `drawable` is blended.
fn hasBlended(drawable: mesh.Drawable, sources: Sources) bool {
    if (drawable.material_failed) return false;
    if (drawable.material != null or drawable.modelFile() == null) return drawable.alpha_blend != 0;
    const model = sources.models.get(drawable.modelFile().?, sources.textures) orelse return false;
    for (model.parts) |part| if (part.alpha_mode == .blend) return true;
    return false;
}

fn fartherFirst(_: void, a: Blended, b: Blended) bool {
    return a.depth > b.depth;
}

/// The rays through the middle of `view` and towards its right and top edges, for the sky.
fn skyRays(view: camera_zig.View, aspect: f32) [3][4]f32 {
    const right = view.forward.cross(view.up).normalize();
    const up = right.cross(view.forward);
    const tan_half: f32 = if (view.projection == .perspective) @tan(view.fov_deg * std.math.rad_per_deg / 2) else 0;
    const across = right.scale(tan_half * aspect);
    const upward = up.scale(tan_half);
    return .{
        .{ view.forward.x, view.forward.y, view.forward.z, 1 },
        .{ across.x, across.y, across.z, 0 },
        .{ upward.x, upward.y, upward.z, 0 },
    };
}

test "a perspective view's sky rays reach its edges; an orthographic one looks straight on" {
    const view = camera_zig.View.lookingAt(.zero, .init(0, 0, -1), .{ .fov_deg = 90 });
    const rays = skyRays(view, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 2), rays[1][0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), rays[2][1], 1e-5);
    var flat = view;
    flat.projection = .orthographic;
    try std.testing.expectEqual(@as(f32, 0), skyRays(flat, 2)[1][0]);
}

test "mirrored entities cull their front faces, double-sided ones none" {
    const identity: [4][4]f32 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
    var drawable = mesh.Drawable{ .model = identity, .color = @splat(1), .shape = .cube, .entity_id = 0, .entity_generation = 0 };
    try std.testing.expectEqual(vit.hal.pipeline.CullMode.back, cullOf(drawable, lookOf(drawable, null)));
    drawable.model[0][0] = -1;
    try std.testing.expectEqual(vit.hal.pipeline.CullMode.front, cullOf(drawable, lookOf(drawable, null)));
    drawable.double_sided = 1;
    try std.testing.expectEqual(vit.hal.pipeline.CullMode.none, cullOf(drawable, lookOf(drawable, null)));
}

test "a model's parts keep their own look unless a material is authored" {
    const part = ModelPart{ .first_index = 0, .index_count = 3, .texture = null, .alpha_mode = .blend, .double_sided = true };
    var drawable = mesh.Drawable{ .model = undefined, .color = @splat(1), .shape = .cube, .entity_id = 0, .entity_generation = 0 };
    try std.testing.expectEqual(Look{ .blend = true, .double_sided = true }, lookOf(drawable, part));
    const material = @import("material.zig").Material{};
    drawable.applyMaterial(&material);
    try std.testing.expectEqual(Look{ .blend = false, .double_sided = false }, lookOf(drawable, part));
}

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
        if (visibleThrough(drawables[index], sources, matrix)) {
            index += 1;
        } else {
            end -= 1;
            std.mem.swap(mesh.Drawable, &drawables[index], &drawables[end]);
        }
    }
    return drawables[0..end];
}

/// Whether any of `drawable` is inside what `matrix` (clip from world) sees, and it can be
/// drawn.
fn visibleThrough(drawable: mesh.Drawable, sources: Sources, matrix: math.Mat4) bool {
    if (drawable.material_failed) return false;
    const bounds = if (drawable.modelFile()) |path| block: {
        const cached = sources.models.get(path, sources.textures) orelse return false;
        // A posed model is measured as posed; others by the box holding every pose they reach.
        if (drawable.deformed != 0) break :block @import("bounds.zig").Bounds{ .min = drawable.bounds_min, .max = drawable.bounds_max };
        break :block @import("bounds.zig").Bounds{ .min = cached.bounds.min, .max = cached.bounds.max };
    } else @import("bounds.zig").Bounds.unit;
    return bounds.visible(transform.columns(math.mul(f32, 4, 4, 4, matrix, math.fromArray(f32, 4, 4, drawable.model))));
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

/// The order meshes are drawn in: by how they look (blended, double-sided, mirrored), as one
/// instanced run is drawn through one pipeline; then those with Eggy's own surface first, then
/// by surface shader; within those, built-in shapes first, by shape, then model files, by path,
/// and those alike by texture. Two that neither comes before are drawn in one go.
fn drawnBefore(_: void, a: mesh.Drawable, b: mesh.Drawable) bool {
    if (a.material_failed != b.material_failed) return !a.material_failed;
    const by_look = std.math.order(lookKey(a), lookKey(b));
    if (by_look != .eq) return by_look == .lt;
    const by_shader = std.mem.order(u8, a.shaderFile() orelse "", b.shaderFile() orelse "");
    if (by_shader != .eq) return by_shader == .lt;
    const by_source = sourceOrder(a, b);
    if (by_source != .eq) return by_source == .lt;
    const by_texture = std.mem.order(u8, a.textureFile() orelse "", b.textureFile() orelse "");
    if (by_texture != .eq) return by_texture == .lt;
    // A posed model has its own vertices, so each is a run of its own.
    return posedKey(a) < posedKey(b);
}

fn lookKey(drawable: mesh.Drawable) u32 {
    const mirrored = cullOf(drawable, .{ .blend = false, .double_sided = false }) == .front;
    return drawable.alpha_blend * 4 + drawable.double_sided * 2 + @intFromBool(mirrored);
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

/// What a pipeline draws: a surface in colour; the selection's mask (depth only, over
/// everything); the outline, over everything but the mask; a shadow map (depth only); or the
/// sky, behind everything.
const Use = union(enum) { colour: Variant, mask, over_all_but_mask, shadow, sky };

/// A pipeline drawing shapes into `format` with a `.d32_float` depth buffer, from the given
/// vertex and fragment shaders, labelled `label`.
fn makePipeline(device: vit.Device, format: vit.Format, layout: vit.PipelineLayout, shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule, label: []const u8, vertex: []const u8, vertex_entry: []const u8, fragment: []const u8, fragment_entry: []const u8, use: Use, sample_count: u32) !vit.GraphicsPipeline {
    const vs = try vit.Shader.init(device, .{ .label = label, .stage = .vertex, .source = shaderSource(vertex, vertex_entry) });
    defer vs.deinit();
    const fs = try vit.Shader.init(device, .{ .label = label, .stage = .fragment, .source = shaderSource(fragment, fragment_entry) });
    defer fs.deinit();
    return pipelineOf(device, format, layout, label, vs, fs, use, sample_count);
}

/// Over what is behind, by the surface's alpha.
const alpha_blend: vit.hal.pipeline.BlendState = .{ .color = .{ .source = .src_alpha, .destination = .one_minus_src_alpha }, .alpha = .{ .source = .one, .destination = .one_minus_src_alpha } };

/// `makePipeline` from shaders already made.
fn pipelineOf(device: vit.Device, format: vit.Format, layout: vit.PipelineLayout, label: []const u8, vs: vit.Shader, fs: vit.Shader, use: Use, sample_count: u32) !vit.GraphicsPipeline {
    if (use == .sky) return vit.GraphicsPipeline.init(device, .{
        .label = label,
        .vertex = vs,
        .fragment = fs,
        .vertex_buffers = &.{.{ .stride = @sizeOf([2]f32), .attributes = &.{.{ .location = 0, .format = .float32x2, .offset = 0 }} }},
        .color_targets = &.{.{ .format = format }},
        .depth_stencil = .{ .format = .d32_float, .depth_write = false, .depth_compare = .always },
        .raster = .{ .cull_mode = .none },
        .layout = layout,
        .multisample = .{ .count = sample_count },
    });
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
    const all = use == .colour or use == .shadow or builtin.os.tag == .emscripten;
    const instance_count: usize = if (all) instance_attributes.len else if (use == .mask) 5 else 4;
    return vit.GraphicsPipeline.init(device, .{
        .label = label,
        .vertex = vs,
        .fragment = fs,
        .vertex_buffers = &.{
            .{ .stride = @sizeOf(mesh.Vertex), .attributes = vertex_attributes[0..if (all) vertex_attributes.len else 1] },
            .{ .stride = @sizeOf(mesh.Drawable), .step_mode = .instance, .attributes = instance_attributes[0..instance_count] },
        },
        .color_targets = switch (use) {
            .shadow => &.{},
            .mask => &.{.{ .format = format, .write_mask = .{ .red = false, .green = false, .blue = false, .alpha = false } }},
            .colour => |variant| &.{.{ .format = format, .blend = if (variant.blend) alpha_blend else null }},
            else => &.{.{ .format = format }},
        },
        // A blended surface is seen through, so it leaves depth for what is drawn behind it after.
        .depth_stencil = switch (use) {
            .colour => |variant| .{ .format = .d32_float, .depth_write = !variant.blend, .depth_compare = .less },
            .shadow => .{ .format = .d32_float, .depth_write = true, .depth_compare = .less },
            .mask => .{ .format = .d32_float, .depth_write = true, .depth_compare = .always },
            .over_all_but_mask, .sky => .{ .format = .d32_float, .depth_write = false, .depth_compare = .less },
        },
        // Counter-clockwise faces are the front, as every shape and imported model winds them
        // (`mesh.zig` tests the shapes'); the selection and shadows keep both sides.
        .raster = .{ .cull_mode = switch (use) {
            .colour => |variant| variant.cull,
            else => .none,
        } },
        .layout = layout,
        .multisample = .{ .count = sample_count },
    });
}

test "shapes are drawn before model files, and each kind and texture together" {
    const identity: [4][4]f32 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
    var drawables = [_]mesh.Drawable{
        .{ .model = identity, .color = undefined, .shape = .cube, .entity_id = 0, .entity_generation = 0, .model_file = "b.glb", .model_file_len = 5 },
        .{ .model = identity, .color = undefined, .shape = .sphere, .entity_id = 1, .entity_generation = 0 },
        .{ .model = identity, .color = undefined, .shape = .cube, .entity_id = 2, .entity_generation = 0, .model_file = "a.glb", .model_file_len = 5 },
        .{ .model = identity, .color = undefined, .shape = .cube, .entity_id = 3, .entity_generation = 0, .texture_file = "wood.png", .texture_file_len = 8 },
        .{ .model = identity, .color = undefined, .shape = .cube, .entity_id = 4, .entity_generation = 0 },
    };
    std.mem.sort(mesh.Drawable, &drawables, {}, drawnBefore);
    var order: [5]u32 = undefined;
    for (&order, drawables) |*id, drawable| id.* = drawable.entity_id;
    // Plain cubes before painted ones, so each texture is one draw.
    try std.testing.expectEqualSlices(u32, &.{ 4, 3, 1, 2, 0 }, &order);
}

test "blended and mirrored meshes are drawn in runs of their own" {
    const identity: [4][4]f32 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
    var mirrored = identity;
    mirrored[0][0] = -1;
    const plain = mesh.Drawable{ .model = identity, .color = @splat(1), .shape = .cube, .entity_id = 0, .entity_generation = 0 };
    var blended = plain;
    blended.alpha_blend = 1;
    var flipped = plain;
    flipped.model = mirrored;
    try std.testing.expect(drawnBefore({}, plain, blended));
    try std.testing.expect(drawnBefore({}, plain, flipped));
    try std.testing.expect(!drawnBefore({}, plain, plain));
}
