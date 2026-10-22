//! Depth-tested unlit sprite, billboard glyph and UI panel geometry for one scene viewport.
const std = @import("std");
const vit = @import("vitellus");
const ui = @import("weeoui");
const shaders = @import("scene_shaders");
const camera = @import("camera.zig");
const requests = @import("draw2d.zig");
const texture = @import("texture_cache.zig");
const slots = @import("weeoui_vitellus").frames_in_flight;
/// `premultiplied` is 1 for panels, whose texture's colours are already multiplied by alpha.
const Vertex = extern struct { position: [3]f32, uv: [2]f32, tint: [4]f32, premultiplied: f32 = 0 };
const Uniforms = extern struct { matrix: [4][4]f32, options: [4]f32 };
const Batch = struct { first: u32, group: ?vit.BindGroup };
const Item = struct { index: usize, kind: enum { sprite, text, panel }, layer: i32, distance2: f32, order: usize };

/// A rectangle in the world painted from part of a texture whose colours are premultiplied by
/// alpha, such as a billboard's UI scene. `origin` is its bottom-left corner; `uv_rect` is
/// {left, top, right, bottom}. Panels sort with sprites and text, back to front.
pub const Panel = struct {
    origin: [3]f32,
    across: [3]f32,
    upward: [3]f32,
    uv_rect: [4]f32,
    group: vit.BindGroup,
};

pub const Renderer = struct {
    gpa: std.mem.Allocator = std.heap.c_allocator,
    device: vit.Device,
    layout: vit.BindGroupLayout,
    pipeline_layout: vit.PipelineLayout,
    pipeline: vit.GraphicsPipeline,
    uniforms: [slots]vit.Buffer,
    groups: [slots]vit.BindGroup,
    buffers: [slots]?vit.Buffer = @splat(null),
    capacities: [slots]usize = @splat(0),
    slot: usize = 0,
    vertices: std.ArrayList(Vertex) = .empty,
    batches: std.ArrayList(Batch) = .empty,
    items: std.ArrayList(Item) = .empty,
    font: ?*ui.Font = null,
    font_texture: ?texture.Gpu = null,
    font_revision: ?u32 = null,

    pub fn init(device: vit.Device, format: vit.Format, samples: u32, texture_layout: vit.BindGroupLayout, shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule) !Renderer {
        const layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{.{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .vertex = true, .fragment = true } }} });
        errdefer layout.deinit();
        const pipeline_layout = try vit.PipelineLayout.init(device, .{ .bind_group_layouts = &.{ layout, texture_layout } });
        errdefer pipeline_layout.deinit();
        const vs = try vit.Shader.init(device, .{ .stage = .vertex, .source = shaderSource(shaders.world_vertex, "vertexMain") });
        defer vs.deinit();
        const fs = try vit.Shader.init(device, .{ .stage = .fragment, .source = shaderSource(shaders.world_fragment, "fragmentMain") });
        defer fs.deinit();
        const pipeline = try vit.GraphicsPipeline.init(device, .{
            .vertex = vs,
            .fragment = fs,
            .vertex_buffers = &.{.{ .stride = @sizeOf(Vertex), .attributes = &.{
                .{ .location = 0, .format = .float32x3, .offset = @offsetOf(Vertex, "position") },
                .{ .location = 1, .format = .float32x2, .offset = @offsetOf(Vertex, "uv") },
                .{ .location = 2, .format = .float32x4, .offset = @offsetOf(Vertex, "tint") },
                .{ .location = 3, .format = .float32, .offset = @offsetOf(Vertex, "premultiplied") },
            } }},
            .color_targets = &.{.{ .format = format, .blend = .{
                .color = .{ .source = .src_alpha, .destination = .one_minus_src_alpha },
                .alpha = .{ .source = .one, .destination = .one_minus_src_alpha },
            } }},
            .depth_stencil = .{ .format = .d32_float, .depth_write = false, .depth_compare = .less_equal },
            .raster = .{ .cull_mode = .none },
            .layout = pipeline_layout,
            .multisample = .{ .count = samples },
        });
        errdefer pipeline.deinit();
        var uniforms: [slots]vit.Buffer = undefined;
        var groups: [slots]vit.BindGroup = undefined;
        for (0..slots) |i| {
            errdefer for (0..i) |made| {
                groups[made].deinit();
                uniforms[made].deinit();
            };
            uniforms[i] = try vit.Buffer.init(device, .{ .size = @sizeOf(Uniforms), .usage = .{ .uniform = true }, .memory = .upload });
            errdefer uniforms[i].deinit();
            groups[i] = try vit.BindGroup.init(device, .{ .layout = layout, .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = uniforms[i] } } }} });
        }
        return .{ .device = device, .layout = layout, .pipeline_layout = pipeline_layout, .pipeline = pipeline, .uniforms = uniforms, .groups = groups };
    }

    pub fn deinit(self: *Renderer) void {
        if (self.font_texture) |paint| paint.deinit();
        if (self.font) |font| {
            font.deinit();
            self.gpa.destroy(font);
        }
        self.vertices.deinit(self.gpa);
        self.batches.deinit(self.gpa);
        self.items.deinit(self.gpa);
        for (self.groups, self.uniforms, self.buffers) |group, uniform, buffer| {
            if (buffer) |value| value.deinit();
            group.deinit();
            uniform.deinit();
        }
        self.pipeline.deinit();
        self.pipeline_layout.deinit();
        self.layout.deinit();
    }

    /// Build geometry and upload textures/buffers outside a render pass. `panels` borrow their
    /// bind groups until `draw`.
    pub fn prepare(self: *Renderer, requests_for_frame: ?*const requests.Draw2d, panels: []const Panel, textures: *texture.TextureCache, view: camera.View, aspect: f32, srgb: bool) !void {
        self.vertices.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
        self.items.clearRetainingCapacity();
        const empty = requests.Draw2d{};
        const source = requests_for_frame orelse &empty;
        for (source.sprites.items, 0..) |request, i| {
            const sprite = request.value;
            try self.items.append(self.gpa, .{ .index = i, .kind = .sprite, .layer = sprite.layer, .distance2 = distance2(view.eye, .{ sprite.position[0], sprite.position[1], sprite.depth_m }), .order = request.order });
        }
        for (source.labels.items, 0..) |label, i| {
            try self.items.append(self.gpa, .{ .index = i, .kind = .text, .layer = 0, .distance2 = distance2(view.eye, label.position_m), .order = label.order });
        }
        for (panels, 0..) |panel, i| {
            var centre: [3]f32 = undefined;
            for (&centre, panel.origin, panel.across, panel.upward) |*c, o, a, u| c.* = o + (a + u) / 2;
            try self.items.append(self.gpa, .{ .index = i, .kind = .panel, .layer = 0, .distance2 = distance2(view.eye, centre), .order = source.sprites.items.len + source.labels.items.len + i });
        }
        std.mem.sort(Item, self.items.items, {}, before);
        const right = camera.normalize(camera.cross(view.forward, view.up));
        const up = camera.normalize(camera.cross(right, view.forward));
        for (self.items.items) |item| switch (item.kind) {
            .text => try self.appendText(source.labels.items[item.index], right, up),
            .panel => {
                const panel = panels[item.index];
                try self.quad(panel.origin, panel.across, panel.upward, panel.uv_rect, @splat(1), panel.group, 1);
            },
            .sprite => {
                const sprite = source.sprites.items[item.index].value;
                const paint = textures.get(sprite.image.key()) orelse return error.SpriteTextureUnavailable;
                const angle = sprite.rotation_deg * std.math.rad_per_deg;
                const x_axis: [3]f32 = if (sprite.billboard) right else .{ 1, 0, 0 };
                const y_axis: [3]f32 = if (sprite.billboard) up else .{ 0, 1, 0 };
                var across: [3]f32 = undefined;
                var upward: [3]f32 = undefined;
                for (&across, &upward, x_axis, y_axis) |*a, *u, x, y| {
                    a.* = (x * @cos(angle) + y * @sin(angle)) * sprite.size[0];
                    u.* = (y * @cos(angle) - x * @sin(angle)) * sprite.size[1];
                }
                var origin = [3]f32{ sprite.position[0], sprite.position[1], sprite.depth_m };
                for (&origin, across, upward) |*o, a, u| o.* -= (a + u) / 2;
                try self.quad(origin, across, upward, sprite.uv_rect, sprite.tint, paint.group, 0);
            },
        };
        if (self.vertices.items.len == 0) return;
        if (self.font) |font| if (self.font_revision == null or self.font_revision.? != font.version()) {
            const pixels = try self.gpa.alloc(u8, ui.atlas_width * ui.atlas_height * 4);
            defer self.gpa.free(pixels);
            for (font.pixels, 0..) |coverage, index| pixels[index * 4 ..][0..4].* = .{ 255, 255, 255, coverage };
            const paint = try textures.make(.{ .width = ui.atlas_width, .height = ui.atlas_height, .pixels = pixels }, "world glyph atlas");
            errdefer paint.deinit();
            try textures.queue.waitIdle();
            if (self.font_texture) |old| old.deinit();
            self.font_texture = paint;
            self.font_revision = font.version();
        };
        self.slot = (self.slot + 1) % slots;
        const bytes = std.mem.sliceAsBytes(self.vertices.items);
        if (self.capacities[self.slot] < bytes.len) {
            const buffer = try vit.Buffer.init(self.device, .{ .size = bytes.len, .usage = .{ .vertex = true }, .memory = .upload });
            errdefer buffer.deinit();
            try textures.queue.waitIdle();
            if (self.buffers[self.slot]) |old| old.deinit();
            self.buffers[self.slot] = buffer;
            self.capacities[self.slot] = bytes.len;
        }
        try upload(self.buffers[self.slot].?, bytes);
        const uniforms = Uniforms{ .matrix = view.viewProjection(aspect), .options = .{ if (srgb) 1 else 0, 0, 0, 0 } };
        try upload(self.uniforms[self.slot], std.mem.asBytes(&uniforms));
    }

    /// Draw prepared geometry inside the scene pass, with its viewport and depth attachment.
    pub fn draw(self: *Renderer, cmd: vit.CommandBuffer) usize {
        if (self.vertices.items.len == 0) return 0;
        cmd.setGraphicsPipeline(self.pipeline);
        cmd.setBindGroup(0, self.groups[self.slot], &.{});
        cmd.setVertexBuffer(0, self.buffers[self.slot].?, 0);
        for (self.batches.items) |batch| {
            const group = batch.group orelse self.font_texture.?.group;
            cmd.setBindGroup(1, group, &.{});
            cmd.draw(6, 1, batch.first, 0);
        }
        return self.batches.items.len;
    }

    fn appendText(self: *Renderer, text: requests.Text, right: [3]f32, up: [3]f32) !void {
        if (self.font == null) {
            const font = try self.gpa.create(ui.Font);
            errdefer self.gpa.destroy(font);
            font.* = try ui.Font.init(self.gpa, ui.default_font);
            self.font = font;
        }
        const font = self.font.?;
        const strike = font.strike(32);
        const scale = text.height_m / 32;
        var x: f32 = 0;
        var y: f32 = 0;
        var index: usize = 0;
        while (index < text.value.len) {
            if (text.value[index] == '\n') {
                x = 0;
                y -= text.height_m * 1.25;
                index += 1;
                continue;
            }
            const glyph = font.next(strike, text.value, &index);
            if (glyph.w != 0 and glyph.h != 0) {
                var origin = text.position_m;
                var across: [3]f32 = undefined;
                var upward: [3]f32 = undefined;
                for (&origin, &across, &upward, right, up) |*o, *a, *u, r, v| {
                    o.* += r * (x + @as(f32, @floatFromInt(glyph.left)) * scale) + v * (y + (@as(f32, @floatFromInt(glyph.top)) - @as(f32, @floatFromInt(glyph.h))) * scale);
                    a.* = r * @as(f32, @floatFromInt(glyph.w)) * scale;
                    u.* = v * @as(f32, @floatFromInt(glyph.h)) * scale;
                }
                try self.quad(origin, across, upward, .{
                    @as(f32, @floatFromInt(glyph.x)) / ui.atlas_width,
                    @as(f32, @floatFromInt(glyph.y)) / ui.atlas_height,
                    @as(f32, @floatFromInt(glyph.x + glyph.w)) / ui.atlas_width,
                    @as(f32, @floatFromInt(glyph.y + glyph.h)) / ui.atlas_height,
                }, @splat(1), null, 0);
            }
            x += glyph.advance * scale;
        }
    }

    fn quad(self: *Renderer, origin: [3]f32, across: [3]f32, upward: [3]f32, uv: [4]f32, tint: [4]f32, group: ?vit.BindGroup, premultiplied: f32) !void {
        const first = std.math.cast(u32, self.vertices.items.len) orelse return error.TooManySpriteVertices;
        try self.batches.append(self.gpa, .{ .first = first, .group = group });
        for ([_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 } }) |corner| {
            var point: [3]f32 = undefined;
            for (&point, origin, across, upward) |*p, o, a, u| p.* = o + a * corner[0] + u * corner[1];
            try self.vertices.append(self.gpa, .{ .position = point, .uv = .{ uv[0] + (uv[2] - uv[0]) * corner[0], uv[3] + (uv[1] - uv[3]) * corner[1] }, .tint = tint, .premultiplied = premultiplied });
        }
    }
};

fn upload(buffer: vit.Buffer, bytes: []const u8) !void {
    const mapped = try buffer.map(.write, .{ .size = bytes.len });
    @memcpy(mapped[0..bytes.len], bytes);
    buffer.unmap(.{ .size = bytes.len });
}

fn distance2(a: [3]f32, b: [3]f32) f32 {
    var result: f32 = 0;
    for (a, b) |x, y| result += (x - y) * (x - y);
    return result;
}

fn before(_: void, a: Item, b: Item) bool {
    if (a.layer != b.layer) return a.layer < b.layer;
    if (a.distance2 != b.distance2) return a.distance2 > b.distance2;
    return a.order < b.order;
}

test "world transparencies sort by layer, then back to front, then submission order" {
    try std.testing.expect(before({}, .{ .index = 0, .kind = .sprite, .layer = -1, .distance2 = 1, .order = 2 }, .{ .index = 1, .kind = .sprite, .layer = 0, .distance2 = 100, .order = 0 }));
    try std.testing.expect(before({}, .{ .index = 0, .kind = .sprite, .layer = 0, .distance2 = 100, .order = 2 }, .{ .index = 1, .kind = .panel, .layer = 0, .distance2 = 1, .order = 0 }));
}
