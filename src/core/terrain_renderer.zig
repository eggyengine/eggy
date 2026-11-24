//! Draws `Terrain`s for `MeshRenderer`: each height grid it shows as a one-channel float texture,
//! uploaded again when the game sets the grid anew, and one flat patch of corners drawn once per
//! `terrain.Patch` the view needs, lifted and shaded on the GPU (`vertexTerrain` and
//! `fragmentTerrain` in `mesh.slang`), into the colour pass and the shadow maps alike.
const std = @import("std");
const vit = @import("vitellus");
const math = @import("eggenvector");
const shaders = @import("scene_shaders");
const mesh = @import("mesh.zig");
const terrain = @import("terrain.zig");
const Heightfields = @import("heightfields.zig").Heightfields;
const frames_in_flight = @import("weeoui_vitellus").frames_in_flight;
const log = std.log.scoped(.terrain);

/// The most patches one pass draws, over every terrain; further ones are left out.
const max_patches = terrain.max_patches * 2;
/// The most terrains one pass draws.
const max_terrains = 64;

/// What a pass draws into: colour, or one of the shadow passes, each with its own instance
/// buffers so one never overwrites what another's frames still read.
pub const Pass = enum { colour, directional_shadow, local_shadow };

/// One terrain's patches in the pass's instance buffer.
const Run = struct { heights: vit.BindGroup, first: u32, count: u32, mirrored: bool };

/// A height grid's texture, as uploaded from `version`.
const Heights = struct {
    texture: vit.Texture,
    view: vit.TextureView,
    group: vit.BindGroup,
    version: u32,

    pub fn deinit(self: Heights) void {
        self.group.deinit();
        self.view.deinit();
        self.texture.deinit();
    }
};

/// What a `draw` drew, for the frame's stats.
pub const Drawn = struct { draw_calls: usize = 0, triangles: u64 = 0 };

pub const TerrainRenderer = struct {
    gpa: std.mem.Allocator,
    device: vit.Device,
    /// The patch's corners (x column, y 1 on a skirt's lower edge, z row) and its triangles.
    corners: vit.Buffer,
    indices: vit.Buffer,
    index_count: u32,
    heights_layout: vit.BindGroupLayout,
    colour_layout: vit.PipelineLayout,
    /// Leaving out back faces, and front ones for a mirrored terrain.
    colour_pipelines: [2]vit.GraphicsPipeline,
    shadow_layout: vit.PipelineLayout,
    shadow_pipeline: vit.GraphicsPipeline,
    instances: [std.enums.values(Pass).len][frames_in_flight]vit.Buffer,
    /// By grid name, which the map owns.
    grids: std.StringHashMapUnmanaged(Heights) = .empty,
    /// This pass's patches (`max_patches`, on the heap: too big for the stack the renderer is
    /// made on) and runs, rebuilt by each `draw`.
    patches: []terrain.Patch,
    runs: [max_terrains]Run = undefined,

    /// Pipelines drawing into `format` through `camera_layout` (set 0 of the colour pass),
    /// `maps_layout` and `texture_layout` (sets 2 and 3, the maps and the sky), and into shadow
    /// maps through `shadow_camera_layout`.
    pub fn init(gpa: std.mem.Allocator, device: vit.Device, format: vit.Format, shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule, camera_layout: vit.BindGroupLayout, maps_layout: vit.BindGroupLayout, texture_layout: vit.BindGroupLayout, shadow_camera_layout: vit.BindGroupLayout, sample_count: u32) !TerrainRenderer {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const patch = try patchGeometry(arena.allocator());
        const corners = try vit.Buffer.init(device, .{ .label = "terrain patch", .size = patch.corners.len * @sizeOf([3]f32), .usage = .{ .vertex = true }, .initial_data = std.mem.sliceAsBytes(patch.corners) });
        errdefer corners.deinit();
        const indices = try vit.Buffer.init(device, .{ .label = "terrain patch indices", .size = patch.indices.len * @sizeOf(u32), .usage = .{ .index = true }, .initial_data = std.mem.sliceAsBytes(patch.indices) });
        errdefer indices.deinit();

        // The grid's heights, read by both stages, where the colour texture usually is.
        const heights_layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .sampled_texture = .{ .sample_type = .float_unfilterable } }, .visibility = .{ .vertex = true, .fragment = true } },
        } });
        errdefer heights_layout.deinit();
        const colour_layout = try vit.PipelineLayout.init(device, .{ .label = "terrain layout", .bind_group_layouts = &.{ camera_layout, heights_layout, maps_layout, texture_layout } });
        errdefer colour_layout.deinit();
        const shadow_layout = try vit.PipelineLayout.init(device, .{ .label = "terrain shadow layout", .bind_group_layouts = &.{ shadow_camera_layout, heights_layout } });
        errdefer shadow_layout.deinit();

        const vs = try vit.Shader.init(device, .{ .label = "terrain", .stage = .vertex, .source = shaderSource(shaders.terrain_vertex, "vertexTerrain") });
        defer vs.deinit();
        const fs = try vit.Shader.init(device, .{ .label = "terrain", .stage = .fragment, .source = shaderSource(shaders.terrain_fragment, "fragmentTerrain") });
        defer fs.deinit();
        var colour_pipelines: [2]vit.GraphicsPipeline = undefined;
        for (&colour_pipelines, [_]vit.hal.pipeline.CullMode{ .back, .front }, 0..) |*made, cull, i| {
            errdefer for (colour_pipelines[0..i]) |earlier| earlier.deinit();
            made.* = try pipelineOf(device, colour_layout, vs, fs, &.{.{ .format = format }}, .{ .format = .d32_float, .depth_write = true, .depth_compare = .less }, cull, sample_count);
        }
        errdefer for (colour_pipelines) |made| made.deinit();
        // Depth only, both sides, as the meshes' shadows are.
        const shadow_pipeline = try pipelineOf(device, shadow_layout, vs, null, &.{}, .{ .format = .d32_float, .depth_write = true, .depth_compare = .less }, .none, 1);
        errdefer shadow_pipeline.deinit();

        const patches = try gpa.alloc(terrain.Patch, max_patches);
        errdefer gpa.free(patches);
        var instances: [std.enums.values(Pass).len][frames_in_flight]vit.Buffer = undefined;
        var made_count: usize = 0;
        errdefer for (0..made_count) |i| instances[i / frames_in_flight][i % frames_in_flight].deinit();
        for (&instances) |*per_pass| for (per_pass) |*buffer| {
            buffer.* = try vit.Buffer.init(device, .{ .label = "terrain patches", .size = max_patches * @sizeOf(terrain.Patch), .usage = .{ .vertex = true }, .memory = .upload });
            made_count += 1;
        };
        return .{
            .gpa = gpa,
            .device = device,
            .corners = corners,
            .indices = indices,
            .index_count = @intCast(patch.indices.len),
            .heights_layout = heights_layout,
            .colour_layout = colour_layout,
            .colour_pipelines = colour_pipelines,
            .shadow_layout = shadow_layout,
            .shadow_pipeline = shadow_pipeline,
            .instances = instances,
            .patches = patches,
        };
    }

    /// Free everything. The GPU must be done with it.
    pub fn deinit(self: *TerrainRenderer) void {
        var it = self.grids.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
            self.gpa.free(entry.key_ptr.*);
        }
        self.grids.deinit(self.gpa);
        self.gpa.free(self.patches);
        for (self.instances) |per_pass| for (per_pass) |buffer| buffer.deinit();
        self.shadow_pipeline.deinit();
        self.shadow_layout.deinit();
        for (self.colour_pipelines) |made| made.deinit();
        self.colour_layout.deinit();
        self.heights_layout.deinit();
        self.indices.deinit();
        self.corners.deinit();
    }

    /// Upload the grids `drawables`' terrains show that are new or set anew since, through
    /// `uploads`, retiring old ones to `graveyard`. Call outside a render pass, before `draw`.
    pub fn prepare(self: *TerrainRenderer, drawables: []const mesh.Drawable, grids: *const Heightfields, uploads: *vit.Uploader, graveyard: *vit.Graveyard) void {
        for (drawables) |drawable| {
            const shown = drawable.terrain orelse continue;
            const name = shown.heights.text();
            const grid = grids.get(name) orelse continue;
            if (self.grids.get(name)) |known| if (known.version == grid.version) continue;
            const made = upload(self.device, self.heights_layout, grid.*, name, uploads, graveyard) catch |err| {
                log.err("cannot upload height grid {s}: {t}", .{ name, err });
                continue;
            };
            self.put(name, made, graveyard) catch |err| {
                log.err("cannot keep height grid {s}: {t}", .{ name, err });
                graveyard.retire(made);
            };
        }
    }

    fn put(self: *TerrainRenderer, name: []const u8, made: Heights, graveyard: *vit.Graveyard) !void {
        const found = try self.grids.getOrPut(self.gpa, name);
        if (found.found_existing) {
            graveyard.retire(found.value_ptr.*);
        } else {
            found.key_ptr.* = self.gpa.dupe(u8, name) catch |err| {
                self.grids.removeByPtr(found.key_ptr);
                return err;
            };
        }
        found.value_ptr.* = made;
    }

    /// Draw `drawables`' terrains (`prepare`d) for `pass` from `slot`'s instance buffer, as seen
    /// from `eye`: in colour with `clip_from_world` leaving out patches it doesn't see, binding
    /// `camera`, `maps` and `sky` (sets 0, 2 and 3); in a shadow pass every patch, once per
    /// shadow camera through `shadowCamera(context, i)` for `i` below `cameras`, which binds set 0
    /// and the viewport. Leaves its own pipeline and groups bound.
    pub fn draw(self: *TerrainRenderer, cmd: vit.CommandBuffer, drawables: []const mesh.Drawable, grids: *const Heightfields, pass: Pass, slot: usize, eye: math.Vec3, target: Target) !Drawn {
        var patch_count: usize = 0;
        var run_count: usize = 0;
        for (drawables) |drawable| {
            const shown = drawable.terrain orelse continue;
            if (run_count == max_terrains) break;
            const name = shown.heights.text();
            const grid = grids.get(name) orelse continue;
            const gpu = self.grids.get(name) orelse continue;
            // A grid set this frame after `prepare` waits for the next one.
            if (gpu.version != grid.version) continue;
            const world = math.fromArray(f32, 4, 4, drawable.model);
            const clip = switch (target) {
                .colour => |colour| colour.clip_from_world,
                .shadow => null,
            };
            const picked = terrain.patches(self.patches[patch_count..], shown.*, grid.*, world, eye, clip);
            if (picked.len == 0) continue;
            self.runs[run_count] = .{ .heights = gpu.group, .first = @intCast(patch_count), .count = @intCast(picked.len), .mirrored = mirrored(drawable.model) };
            run_count += 1;
            patch_count += picked.len;
        }
        if (run_count == 0) return .{};
        const buffer = self.instances[@backingInt(pass)][slot];
        const bytes = std.mem.sliceAsBytes(self.patches[0..patch_count]);
        const mapped = try buffer.map(.write, .{ .size = bytes.len });
        @memcpy(mapped[0..bytes.len], bytes);
        buffer.unmap(.{ .size = bytes.len });

        cmd.setVertexBuffer(0, self.corners, 0);
        cmd.setVertexBuffer(1, buffer, 0);
        cmd.setIndexBuffer(self.indices, .uint32, 0);
        var drawn: Drawn = .{};
        switch (target) {
            .colour => |colour| for (self.runs[0..run_count]) |run| {
                cmd.setGraphicsPipeline(self.colour_pipelines[@intFromBool(run.mirrored)]);
                cmd.setBindGroup(0, colour.camera, &.{});
                cmd.setBindGroup(1, run.heights, &.{});
                if (colour.maps) |maps| cmd.setBindGroup(2, maps, &.{});
                cmd.setBindGroup(3, colour.sky, &.{});
                cmd.drawIndexed(self.index_count, run.count, 0, 0, run.first);
                drawn.draw_calls += 1;
                drawn.triangles += @as(u64, self.index_count / 3) * run.count;
            },
            .shadow => |shadow| for (0..shadow.cameras) |camera| {
                cmd.setGraphicsPipeline(self.shadow_pipeline);
                shadow.bind(shadow.context, cmd, camera);
                for (self.runs[0..run_count]) |run| {
                    cmd.setBindGroup(1, run.heights, &.{});
                    cmd.drawIndexed(self.index_count, run.count, 0, 0, run.first);
                    drawn.draw_calls += 1;
                    drawn.triangles += @as(u64, self.index_count / 3) * run.count;
                }
            },
        }
        return drawn;
    }

    /// Where `draw` draws: the colour pass with its groups, or a shadow pass's cameras.
    pub const Target = union(enum) {
        /// `maps` is null only where no neutral maps group could be made.
        colour: struct { clip_from_world: math.Mat4, camera: vit.BindGroup, maps: ?vit.BindGroup, sky: vit.BindGroup },
        shadow: struct {
            cameras: usize,
            context: *const anyopaque,
            /// Binds set 0 and sets the viewport for camera `index`.
            bind: *const fn (context: *const anyopaque, cmd: vit.CommandBuffer, index: usize) void,
        },
    };
};

/// Whether `model` (by column) turns the terrain inside out, so its front faces wind the other way.
fn mirrored(m: [4][4]f32) bool {
    const determinant = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[1][0] * (m[0][1] * m[2][2] - m[0][2] * m[2][1]) + m[2][0] * (m[0][1] * m[1][2] - m[0][2] * m[1][1]);
    return determinant < 0;
}

/// `grid` as a texture, one float a corner, its rows padded as uploads need.
fn upload(device: vit.Device, layout: vit.BindGroupLayout, grid: Heightfields.Grid, name: []const u8, uploads: *vit.Uploader, graveyard: *vit.Graveyard) !Heights {
    const rows = grid.rows();
    const row_bytes = std.mem.alignForward(u32, grid.columns * @sizeOf(f32), 256);
    const bytes = try std.heap.c_allocator.alloc(u8, @as(usize, row_bytes) * rows);
    defer std.heap.c_allocator.free(bytes);
    for (0..rows) |row| @memcpy(bytes[row * row_bytes ..][0 .. grid.columns * @sizeOf(f32)], std.mem.sliceAsBytes(grid.heights[row * grid.columns ..][0..grid.columns]));
    const texture = try vit.Texture.init(device, .{ .label = name, .width = grid.columns, .height = rows, .format = .r32_float, .usage = .{ .sampled = true, .transfer_dst = true } });
    // Retired, not destroyed: a pending upload may already copy into it.
    errdefer graveyard.retire(texture);
    try uploads.writeTexture(.{ .texture = texture, .data = bytes, .levels = &.{.{ .bytes_per_row = row_bytes, .width = grid.columns, .height = rows }} });
    const view = try vit.TextureView.init(device, .{ .texture = texture });
    errdefer view.deinit();
    const group = try vit.BindGroup.init(device, .{ .layout = layout, .entries = &.{.{ .binding = 0, .resource = .{ .texture_view = view } }} });
    return .{ .texture = texture, .view = view, .group = group, .version = grid.version };
}

/// One patch's corners and triangles: `terrain.patch_cells` cells a side, each split from its
/// first corner to the one across, counter-clockwise from above; then a skirt down from each
/// edge, facing out.
fn patchGeometry(arena: std.mem.Allocator) !struct { corners: []const [3]f32, indices: []const u32 } {
    const cells = terrain.patch_cells;
    const side = cells + 1;
    var corners: std.ArrayList([3]f32) = .empty;
    var indices: std.ArrayList(u32) = .empty;
    for (0..side) |row| for (0..side) |column| try corners.append(arena, .{ @floatFromInt(column), 0, @floatFromInt(row) });
    for (0..cells) |row| for (0..cells) |column| {
        const here: u32 = @intCast(row * side + column);
        const right = here + 1;
        const below = here + side;
        const across = below + 1;
        try indices.appendSlice(arena, &.{ here, across, right, here, below, across });
    };
    // Each edge, walked so the patch is on its left seen from above: its skirt faces out.
    const edges = [_]struct { start: [2]u32, step: [2]i32 }{
        .{ .start = .{ 0, 0 }, .step = .{ 1, 0 } }, // first row, facing -z
        .{ .start = .{ cells, 0 }, .step = .{ 0, 1 } }, // last column, facing +x
        .{ .start = .{ cells, cells }, .step = .{ -1, 0 } }, // last row, facing +z
        .{ .start = .{ 0, cells }, .step = .{ 0, -1 } }, // first column, facing -x
    };
    for (edges) |edge| {
        for (0..cells) |i| {
            const at = [2]i32{ @as(i32, @intCast(edge.start[0])) + edge.step[0] * @as(i32, @intCast(i)), @as(i32, @intCast(edge.start[1])) + edge.step[1] * @as(i32, @intCast(i)) };
            const next = [2]i32{ at[0] + edge.step[0], at[1] + edge.step[1] };
            const top_a: u32 = @intCast(at[1] * side + at[0]);
            const top_b: u32 = @intCast(next[1] * side + next[0]);
            const low_a: u32 = @intCast(corners.items.len);
            try corners.append(arena, .{ @floatFromInt(at[0]), 1, @floatFromInt(at[1]) });
            try corners.append(arena, .{ @floatFromInt(next[0]), 1, @floatFromInt(next[1]) });
            const low_b = low_a + 1;
            try indices.appendSlice(arena, &.{ top_a, top_b, low_b, top_a, low_b, low_a });
        }
    }
    return .{ .corners = corners.items, .indices = indices.items };
}

fn pipelineOf(device: vit.Device, layout: vit.PipelineLayout, vs: vit.Shader, fs: ?vit.Shader, targets: []const vit.hal.pipeline.ColorTargetState, depth: vit.hal.pipeline.DepthStencilState, cull: vit.hal.pipeline.CullMode, sample_count: u32) !vit.GraphicsPipeline {
    const patch_attributes = [_]vit.hal.pipeline.VertexAttribute{.{ .location = 0, .format = .float32x3, .offset = 0 }};
    var instance_attributes: [10]vit.hal.pipeline.VertexAttribute = undefined;
    for (&instance_attributes, 0..) |*attribute, i| attribute.* = .{ .location = @intCast(i + 1), .format = .float32x4, .offset = @intCast(i * 16) };
    return vit.GraphicsPipeline.init(device, .{
        .label = "terrain",
        .vertex = vs,
        .fragment = fs,
        .vertex_buffers = &.{
            .{ .stride = @sizeOf([3]f32), .attributes = &patch_attributes },
            .{ .stride = @sizeOf(terrain.Patch), .step_mode = .instance, .attributes = &instance_attributes },
        },
        .color_targets = targets,
        .depth_stencil = depth,
        .raster = .{ .cull_mode = cull },
        .layout = layout,
        .multisample = .{ .count = sample_count },
    });
}
