//! The scene's HDR target, post-processed into the presentation target: the project's own
//! passes, then bloom, tone mapping, colour grading and FXAA (`post_process.zig` holds the
//! settings, `shaders/scene_post.slang` Eggy's passes).
const std = @import("std");
const vit = @import("vitellus");
const shaders = @import("scene_shaders");
const frames_in_flight = @import("weeoui_vitellus").frames_in_flight;
const post_process = @import("post_process.zig");
const ShaderCache = @import("shader_cache.zig").ShaderCache;
const ShaderPipelines = @import("shader_pipelines.zig").ShaderPipelines;

/// Scene light is kept unclipped until the grade maps it into the presentation target.
pub const hdr_format: vit.Format = .rgba16_float;
/// How many times bloom halves the scene; the smallest level is 1/64 of it.
const bloom_levels = 6;
const triangle = [3][2]f32{ .{ 0, 0 }, .{ 2, 0 }, .{ 0, 2 } };
/// Settings buffers per frame: Eggy's passes' one, then one per project pass.
const buffers_per_frame = 1 + post_process.max_passes;

const Uniforms = extern struct {
    bloom: [4]f32,
    grade: [4]f32,
    scene_uv: [4]f32,
    options: [4]f32,
};

/// A project pass's settings, as `post_pass.slang`'s `EggyPass` reads them.
const PassUniforms = extern struct {
    values: [4]f32,
    frame: [4]f32,
};

/// Where the scene sits in the target, and how the grade writes the presentation target.
pub const Output = struct {
    destination: vit.TextureView,
    /// The destination's size in pixels.
    extent: vit.Extent2D,
    scissor: vit.hal.command.ScissorRect,
    /// The scene's rectangle as a fraction of the target: x, y, width, height.
    scene_uv: [4]f32,
    /// The destination encodes sRGB itself; otherwise the grade does.
    srgb: bool,
};

/// What `draw` grades: the settings, and where the project's passes' shaders come from.
pub const Look = struct {
    post: post_process.Frame,
    shaders: *ShaderCache,
    time_s: f32,
};

pub const ScenePost = struct {
    device: vit.Device,
    samples: u32,
    fxaa: bool,
    target: Target,
    triangle: vit.Buffer,
    sampler: vit.Sampler,
    texture_layout: vit.BindGroupLayout,
    uniform_layout: vit.BindGroupLayout,
    /// `buffers_per_frame` per frame in flight, so a frame never rewrites what the GPU reads.
    uniforms: [frames_in_flight * buffers_per_frame]vit.Buffer,
    uniform_groups: [frames_in_flight * buffers_per_frame]vit.BindGroup,
    slot: usize = 0,
    pipeline_layout: vit.PipelineLayout,
    vertex: vit.Shader,
    prefilter: vit.GraphicsPipeline,
    down: vit.GraphicsPipeline,
    up: vit.GraphicsPipeline,
    grade: vit.GraphicsPipeline,
    /// The project's passes' pipelines.
    passes: ShaderPipelines = .{},
    /// The last pass shader reported as not a post shader, so it is logged once.
    wrong_role_reported: u64 = 0,

    const Level = struct {
        texture: vit.Texture,
        view: vit.TextureView,
        extent: vit.Extent2D,
        /// Reads the level above it, to halve into this one; null for the first, which reads
        /// whichever image the project's passes left the scene in.
        down_group: ?vit.BindGroup,
        /// Reads the level below it, to add onto this one; null for the smallest.
        up_group: ?vit.BindGroup,
    };

    /// One of the two images the project's passes take turns reading and writing.
    const Image = struct {
        texture: vit.Texture,
        view: vit.TextureView,
        /// Reads it, for a project pass or bloom's first level.
        reads: vit.BindGroup,
        /// Reads it and the first bloom level, for the grade.
        grades: vit.BindGroup,
        /// Whether it has left its first, undefined state.
        initialized: bool = false,

        fn deinit(self: Image) void {
            self.grades.deinit();
            self.reads.deinit();
            self.view.deinit();
            self.texture.deinit();
        }
    };

    const Target = struct {
        /// The scene, then the spare image the first project pass writes.
        images: [2]Image,
        extent: vit.Extent2D,
        multisample: ?vit.Texture = null,
        multisample_view: ?vit.TextureView = null,
        bloom: [bloom_levels]Level,
        bloom_initialized: bool = false,

        fn deinit(self: Target) void {
            for (self.images) |image| image.deinit();
            for (self.bloom) |level| {
                if (level.up_group) |group| group.deinit();
                if (level.down_group) |group| group.deinit();
                level.view.deinit();
                level.texture.deinit();
            }
            if (self.multisample_view) |view| view.deinit();
            if (self.multisample) |texture| texture.deinit();
        }
    };

    /// Post-processing for a scene rendered at `extent` with `samples` per pixel, graded into
    /// targets in `format`. The device must outlive it; GPU and shader errors propagate.
    pub fn init(device: vit.Device, format: vit.Format, extent: vit.Extent2D, samples: u32, fxaa: bool, shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule) !ScenePost {
        const vertices = try vit.Buffer.init(device, .{ .label = "scene post triangle", .size = @sizeOf(@TypeOf(triangle)), .usage = .{ .vertex = true }, .initial_data = std.mem.asBytes(&triangle) });
        errdefer vertices.deinit();
        const sampler = try vit.Sampler.init(device, .{ .address_u = .clamp_to_edge, .address_v = .clamp_to_edge });
        errdefer sampler.deinit();
        const texture_layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
            .{ .binding = 1, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
            .{ .binding = 2, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
        } });
        errdefer texture_layout.deinit();
        const uniform_layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .fragment = true } },
        } });
        errdefer uniform_layout.deinit();

        // Settings buffers for every pass of every frame in flight.
        var uniforms: [frames_in_flight * buffers_per_frame]vit.Buffer = undefined;
        var uniform_groups: [frames_in_flight * buffers_per_frame]vit.BindGroup = undefined;
        for (&uniforms, &uniform_groups, 0..) |*buffer, *group, i| {
            errdefer for (uniforms[0..i], uniform_groups[0..i]) |b, g| {
                g.deinit();
                b.deinit();
            };
            buffer.* = try vit.Buffer.init(device, .{ .label = "scene post settings", .size = 256, .usage = .{ .uniform = true }, .memory = .upload });
            errdefer buffer.deinit();
            group.* = try vit.BindGroup.init(device, .{ .layout = uniform_layout, .entries = &.{
                .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = buffer.* } } },
            } });
        }
        errdefer for (uniforms, uniform_groups) |b, g| {
            g.deinit();
            b.deinit();
        };

        // A pipeline per pass: bloom's three into HDR levels, the grade into the destination.
        const pipeline_layout = try vit.PipelineLayout.init(device, .{ .label = "scene post", .bind_group_layouts = &.{ texture_layout, uniform_layout } });
        errdefer pipeline_layout.deinit();
        const vs = try vit.Shader.init(device, .{ .label = "scene post vertex", .stage = .vertex, .source = shaderSource(shaders.post_vertex, "vertexMain") });
        errdefer vs.deinit();
        const additive = vit.hal.pipeline.BlendState{ .color = .{ .source = .one, .destination = .one }, .alpha = .{ .source = .one, .destination = .one } };
        const prefilter = try makePipeline(device, pipeline_layout, vs, shaderSource(shaders.bloom_prefilter, "bloomPrefilter"), hdr_format, null);
        errdefer prefilter.deinit();
        const down = try makePipeline(device, pipeline_layout, vs, shaderSource(shaders.bloom_down, "bloomDown"), hdr_format, null);
        errdefer down.deinit();
        const up = try makePipeline(device, pipeline_layout, vs, shaderSource(shaders.bloom_up, "bloomUp"), hdr_format, additive);
        errdefer up.deinit();
        const grade = try makePipeline(device, pipeline_layout, vs, shaderSource(shaders.grade_fragment, "gradeMain"), format, null);
        errdefer grade.deinit();

        var self = ScenePost{ .device = device, .samples = samples, .fxaa = fxaa, .target = undefined, .triangle = vertices, .sampler = sampler, .texture_layout = texture_layout, .uniform_layout = uniform_layout, .uniforms = uniforms, .uniform_groups = uniform_groups, .pipeline_layout = pipeline_layout, .vertex = vs, .prefilter = prefilter, .down = down, .up = up, .grade = grade };
        self.target = try self.makeTarget(extent);
        return self;
    }

    pub fn deinit(self: *ScenePost) void {
        self.target.deinit();
        self.passes.deinit();
        self.grade.deinit();
        self.up.deinit();
        self.down.deinit();
        self.prefilter.deinit();
        self.vertex.deinit();
        self.pipeline_layout.deinit();
        for (self.uniforms, self.uniform_groups) |b, g| {
            g.deinit();
            b.deinit();
        }
        self.uniform_layout.deinit();
        self.texture_layout.deinit();
        self.sampler.deinit();
        self.triangle.deinit();
    }

    /// Replace targets only after the caller has waited for earlier GPU use. On failure the
    /// previous targets stay.
    pub fn resize(self: *ScenePost, extent: vit.Extent2D) !void {
        const target = try self.makeTarget(extent);
        self.target.deinit();
        self.target = target;
    }

    fn makeTarget(self: *ScenePost, extent: vit.Extent2D) !Target {
        const device = self.device;
        var multisample: ?vit.Texture = null;
        errdefer if (multisample) |made| made.deinit();
        var multisample_view: ?vit.TextureView = null;
        errdefer if (multisample_view) |made| made.deinit();
        if (self.samples > 1) {
            multisample = try vit.Texture.init(device, .{ .label = "multisample HDR scene", .width = extent.width, .height = extent.height, .sample_count = self.samples, .format = hdr_format, .usage = .{ .color_attachment = true } });
            multisample_view = try vit.TextureView.init(device, .{ .texture = multisample.? });
        }

        // Bloom's levels, each half the one before, each reading the one above it.
        var bloom: [bloom_levels]Level = undefined;
        var made: usize = 0;
        errdefer for (bloom[0..made]) |level| {
            if (level.down_group) |group| group.deinit();
            level.view.deinit();
            level.texture.deinit();
        };
        var level_extent = extent;
        for (&bloom) |*level| {
            level_extent = .{ .width = @max(1, level_extent.width / 2), .height = @max(1, level_extent.height / 2) };
            const texture = try vit.Texture.init(device, .{ .label = "bloom level", .width = level_extent.width, .height = level_extent.height, .format = hdr_format, .usage = .{ .color_attachment = true, .sampled = true } });
            errdefer texture.deinit();
            const view = try vit.TextureView.init(device, .{ .texture = texture });
            errdefer view.deinit();
            const down_group = if (made == 0) null else try self.textureGroup(bloom[made - 1].view, bloom[made - 1].view);
            level.* = .{ .texture = texture, .view = view, .extent = level_extent, .down_group = down_group, .up_group = null };
            made += 1;
        }
        var linked: usize = 0;
        errdefer for (bloom[0..linked]) |level| level.up_group.?.deinit();
        for (bloom[0 .. bloom_levels - 1], bloom[1..]) |*level, below| {
            level.up_group = try self.textureGroup(below.view, below.view);
            linked += 1;
        }

        // The scene and the spare image, each readable by a pass and by the grade.
        var images: [2]Image = undefined;
        var imaged: usize = 0;
        errdefer for (images[0..imaged]) |image| image.deinit();
        for (&images, [_][]const u8{ "HDR scene", "HDR spare" }) |*image, label| {
            const texture = try vit.Texture.init(device, .{ .label = label, .width = extent.width, .height = extent.height, .format = hdr_format, .usage = .{ .color_attachment = true, .sampled = true } });
            errdefer texture.deinit();
            const view = try vit.TextureView.init(device, .{ .texture = texture });
            errdefer view.deinit();
            const reads = try self.textureGroup(view, view);
            errdefer reads.deinit();
            image.* = .{ .texture = texture, .view = view, .reads = reads, .grades = try self.textureGroup(view, bloom[0].view) };
            imaged += 1;
        }
        return .{ .images = images, .extent = extent, .multisample = multisample, .multisample_view = multisample_view, .bloom = bloom };
    }

    fn textureGroup(self: *const ScenePost, source: vit.TextureView, glow: vit.TextureView) !vit.BindGroup {
        return vit.BindGroup.init(self.device, .{ .layout = self.texture_layout, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = source } },
            .{ .binding = 1, .resource = .{ .sampler = self.sampler } },
            .{ .binding = 2, .resource = .{ .texture_view = glow } },
        } });
    }

    /// Ready the HDR target for the scene pass. Call outside a render pass, before `attachment`.
    pub fn begin(self: *ScenePost, cmd: vit.CommandBuffer) !void {
        const scene = &self.target.images[0];
        try cmd.barrier(&.{.{ .texture = .{ .texture = scene.texture, .before = if (scene.initialized) .sampled else .common, .after = .color_attachment } }});
        if (self.target.multisample) |texture| try cmd.barrier(&.{.{ .texture = .{ .texture = texture, .before = if (scene.initialized) .color_attachment else .common, .after = .color_attachment } }});
    }

    /// The scene pass's colour attachment: the HDR target, cleared, multisampled and resolved
    /// into it when antialiasing asks.
    pub fn attachment(self: *const ScenePost) vit.hal.command.ColorAttachment {
        const scene = self.target.images[0].view;
        return .{
            .view = self.target.multisample_view orelse scene,
            .resolve_target = if (self.samples > 1) scene else null,
            .load_op = .clear,
            .store_op = if (self.samples > 1) .discard else .store,
        };
    }

    /// After the scene pass: the project's passes and bloom as `look` asks, then grade the scene
    /// into `output`'s destination, within its scissor. Call outside a render pass; the
    /// destination must be in the colour-attachment state and the format `init` was given.
    pub fn draw(self: *ScenePost, cmd: vit.CommandBuffer, look: Look, output: Output) !void {
        const target = &self.target;
        try cmd.barrier(&.{.{ .texture = .{ .texture = target.images[0].texture, .before = .color_attachment, .after = .sampled } }});
        target.images[0].initialized = true;

        // This frame's settings, in this frame's own buffers.
        self.slot = (self.slot + 1) % frames_in_flight;
        try self.write(0, std.mem.asBytes(&Uniforms{
            .bloom = .{ look.post.bloom[0], look.post.bloom[1], 0, 0 },
            .grade = .{ look.post.grade[0], look.post.grade[1], look.post.grade[2], @floatFromInt(look.post.tone_mapping) },
            .scene_uv = output.scene_uv,
            .options = .{ if (self.fxaa) 1 else 0, if (output.srgb) 0 else 1, 0, 0 },
        }));

        // The project's passes, each reading the image the last one wrote.
        var current: usize = 0;
        for (0..post_process.max_passes) |index| {
            const key = look.post.passShader(index) orelse continue;
            const pipeline = self.passPipeline(key, look.shaders) orelse continue;
            try self.write(1 + index, std.mem.asBytes(&PassUniforms{ .values = look.post.pass_values[index], .frame = .{ look.time_s, 0, 0, 0 } }));
            const written = &target.images[1 - current];
            try cmd.barrier(&.{.{ .texture = .{ .texture = written.texture, .before = if (written.initialized) .sampled else .common, .after = .color_attachment } }});
            try cmd.beginRenderPass(.{ .label = "project post pass", .color_attachments = &.{.{ .view = written.view, .load_op = .clear, .store_op = .store }} });
            cmd.setViewport(.{ .width = @floatFromInt(target.extent.width), .height = @floatFromInt(target.extent.height) });
            cmd.setScissor(.{ .width = target.extent.width, .height = target.extent.height });
            self.fullScreen(cmd, pipeline, target.images[current].reads, 1 + index);
            cmd.endRenderPass();
            try cmd.barrier(&.{.{ .texture = .{ .texture = written.texture, .before = .color_attachment, .after = .sampled } }});
            written.initialized = true;
            current = 1 - current;
        }

        if (look.post.bloom[0] > 0) {
            try self.drawBloom(cmd, target.images[current].reads);
        } else if (!target.bloom_initialized) {
            // The grade still binds the first level, which must be sampleable though unused.
            for (target.bloom) |level| try cmd.barrier(&.{.{ .texture = .{ .texture = level.texture, .before = .common, .after = .sampled } }});
            target.bloom_initialized = true;
        }

        try cmd.beginRenderPass(.{ .label = "scene grade", .color_attachments = &.{.{ .view = output.destination, .load_op = .load, .store_op = .store }} });
        cmd.setViewport(.{ .width = @floatFromInt(output.extent.width), .height = @floatFromInt(output.extent.height) });
        cmd.setScissor(output.scissor);
        self.fullScreen(cmd, self.grade, target.images[current].grades, 0);
        cmd.endRenderPass();
    }

    // Write `bytes` into this frame's settings buffer `index`.
    fn write(self: *ScenePost, index: usize, bytes: []const u8) !void {
        const buffer = self.uniforms[self.slot * buffers_per_frame + index];
        const mapped = try buffer.map(.write, .{ .size = bytes.len });
        @memcpy(mapped[0..bytes.len], bytes);
        buffer.unmap(.{ .size = bytes.len });
    }

    // The pipeline for project post shader `key`, made the first time; null (skipping the
    // pass) when it doesn't load or isn't a post shader.
    fn passPipeline(self: *ScenePost, key: []const u8, cache: *ShaderCache) ?vit.GraphicsPipeline {
        const loaded = cache.get(key) orelse return null;
        if (self.passes.get(key, 0, cache.revision)) |known| return known;
        if (loaded.role != .post) {
            const hash = std.hash.Wyhash.hash(0, key);
            if (self.wrong_role_reported != hash) std.log.err("post pass shader {s} is a {t} shader, not a post shader: the pass is skipped", .{ key, loaded.role });
            self.wrong_role_reported = hash;
            return null;
        }
        const pipeline = fullScreenPipeline(self.device, self.pipeline_layout, self.vertex, loaded.fragment, hdr_format, null) catch |err| {
            std.log.err("cannot make post pass {s}: {t}", .{ key, err });
            return null;
        };
        return self.passes.put(key, 0, pipeline);
    }

    // Halve `scene`'s bright light down the levels, then add each back onto the one above.
    // Every level ends sampled, ready for the grade and the next frame.
    fn drawBloom(self: *ScenePost, cmd: vit.CommandBuffer, scene: vit.BindGroup) !void {
        const target = &self.target;
        for (target.bloom, 0..) |level, i| {
            try cmd.barrier(&.{.{ .texture = .{ .texture = level.texture, .before = if (target.bloom_initialized) .sampled else .common, .after = .color_attachment } }});
            try self.levelPass(cmd, level, .clear, if (i == 0) self.prefilter else self.down, level.down_group orelse scene);
        }
        var i: usize = bloom_levels - 1;
        while (i > 0) {
            i -= 1;
            const level = target.bloom[i];
            try cmd.barrier(&.{.{ .texture = .{ .texture = level.texture, .before = .sampled, .after = .color_attachment } }});
            try self.levelPass(cmd, level, .load, self.up, level.up_group.?);
        }
        target.bloom_initialized = true;
    }

    fn levelPass(self: *ScenePost, cmd: vit.CommandBuffer, level: Level, load_op: vit.hal.command.LoadOp, pipeline: vit.GraphicsPipeline, group: vit.BindGroup) !void {
        try cmd.beginRenderPass(.{ .label = "bloom", .color_attachments = &.{.{ .view = level.view, .load_op = load_op, .store_op = .store }} });
        cmd.setViewport(.{ .width = @floatFromInt(level.extent.width), .height = @floatFromInt(level.extent.height) });
        cmd.setScissor(.{ .width = level.extent.width, .height = level.extent.height });
        self.fullScreen(cmd, pipeline, group, 0);
        cmd.endRenderPass();
        try cmd.barrier(&.{.{ .texture = .{ .texture = level.texture, .before = .color_attachment, .after = .sampled } }});
    }

    fn fullScreen(self: *const ScenePost, cmd: vit.CommandBuffer, pipeline: vit.GraphicsPipeline, textures: vit.BindGroup, settings: usize) void {
        cmd.setGraphicsPipeline(pipeline);
        cmd.setBindGroup(0, textures, &.{});
        cmd.setBindGroup(1, self.uniform_groups[self.slot * buffers_per_frame + settings], &.{});
        cmd.setVertexBuffer(0, self.triangle, 0);
        cmd.draw(3, 1, 0, 0);
    }
};

fn makePipeline(device: vit.Device, layout: vit.PipelineLayout, vs: vit.Shader, fragment: vit.ShaderModule, format: vit.Format, blend: ?vit.hal.pipeline.BlendState) !vit.GraphicsPipeline {
    const fs = try vit.Shader.init(device, .{ .label = "scene post fragment", .stage = .fragment, .source = fragment });
    defer fs.deinit();
    return fullScreenPipeline(device, layout, vs, fs, format, blend);
}

/// A full-screen triangle's pipeline: `vs` stretching it over the target, `fs` shading it.
fn fullScreenPipeline(device: vit.Device, layout: vit.PipelineLayout, vs: vit.Shader, fs: vit.Shader, format: vit.Format, blend: ?vit.hal.pipeline.BlendState) !vit.GraphicsPipeline {
    return vit.GraphicsPipeline.init(device, .{
        .label = "scene post",
        .vertex = vs,
        .fragment = fs,
        .vertex_buffers = &.{.{ .stride = @sizeOf([2]f32), .attributes = &.{.{ .location = 0, .format = .float32x2, .offset = 0 }} }},
        .color_targets = &.{.{ .format = format, .blend = blend }},
        .raster = .{ .cull_mode = .none },
        .layout = layout,
    });
}
