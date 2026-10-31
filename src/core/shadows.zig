//! Shadow maps: the directional light's, fitted texel-stable round the camera, and point and
//! spot lights' (`Local`), sharing one texture in a grid.
const std = @import("std");
const vit = @import("vitellus");
const math = @import("eggenvector");
const camera = @import("camera.zig");
const transform = @import("transform.zig");
const lighting = @import("lighting.zig");
const render = @import("render_settings.zig");
const Uniforms = @import("scene_uniforms.zig").Camera;
const mesh = @import("mesh.zig");
const slots = @import("weeoui_vitellus").frames_in_flight;

pub const Map = struct {
    texture: vit.Texture,
    view: vit.TextureView,
    sampler: vit.Sampler,
    layout: vit.BindGroupLayout,
    uniforms: [slots]vit.Buffer,
    instances: [slots]vit.Buffer,
    groups: [slots]vit.BindGroup,
    resolution: u32,
    initialized: bool = false,
    slot: usize = 0,
    matrix: [4][4]f32 = @splat(@splat(0)),
    params: [4]f32 = @splat(0),

    pub fn init(device: vit.Device, quality: render.ShadowQuality, max_drawables: usize) !Map {
        const resolution = quality.resolution();
        const texture = try vit.Texture.init(device, .{ .label = "directional shadow depth", .width = resolution, .height = resolution, .format = .d32_float, .usage = .{ .depth_stencil_attachment = true, .sampled = true } });
        errdefer texture.deinit();
        const view = try vit.TextureView.init(device, .{ .texture = texture, .aspect = .depth });
        errdefer view.deinit();
        const sampler = try vit.Sampler.init(device, .{ .address_u = .clamp_to_edge, .address_v = .clamp_to_edge, .compare = .less_equal, .mag_filter = .nearest, .min_filter = .nearest, .mipmap_filter = .nearest });
        errdefer sampler.deinit();
        // A dynamic offset picks each local map's camera from one buffer; the directional map
        // passes 0.
        const layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform, .dynamic_offset = true } }, .visibility = .{ .vertex = true, .fragment = true } },
        } });
        errdefer layout.deinit();
        var uniforms: [slots]vit.Buffer = undefined;
        var instances: [slots]vit.Buffer = undefined;
        var groups: [slots]vit.BindGroup = undefined;
        for (0..slots) |i| {
            errdefer for (0..i) |made| {
                groups[made].deinit();
                instances[made].deinit();
                uniforms[made].deinit();
            };
            uniforms[i] = try vit.Buffer.init(device, .{ .size = @sizeOf(Uniforms), .usage = .{ .uniform = true }, .memory = .upload });
            errdefer uniforms[i].deinit();
            instances[i] = try vit.Buffer.init(device, .{ .size = max_drawables * @sizeOf(mesh.Drawable), .usage = .{ .vertex = true }, .memory = .upload });
            errdefer instances[i].deinit();
            groups[i] = try vit.BindGroup.init(device, .{ .layout = layout, .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = uniforms[i], .size = @sizeOf(Uniforms) } } }} });
        }
        return .{ .texture = texture, .view = view, .sampler = sampler, .layout = layout, .uniforms = uniforms, .instances = instances, .groups = groups, .resolution = resolution };
    }

    pub fn deinit(self: *Map) void {
        for (self.groups, self.instances, self.uniforms) |group, instance, uniform| {
            group.deinit();
            instance.deinit();
            uniform.deinit();
        }
        self.layout.deinit();
        self.sampler.deinit();
        self.view.deinit();
        self.texture.deinit();
    }

    /// Fit the camera's reachable volume, with conservative caster depth and texel snapping.
    /// One directional light is selected explicitly by `Lighting.setShadowCaster`.
    pub fn fit(self: *Map, view: camera.View, aspect: f32, lights: *const lighting.Frame, settings: render.Settings) bool {
        self.params = @splat(0);
        const index = lights.options[2];
        if (settings.shadow_quality == .off or index < 0 or index >= @as(f32, @floatFromInt(lights.count))) return false;
        const light = lights.lights[@intFromFloat(index)];
        const direction = math.Vec3.fromArray(light.direction_range[0..3].*);
        self.matrix = transform.columns(fitCamera(view, aspect, direction, settings.shadow_distance_m, self.resolution).viewProjection(1));
        self.params = .{ settings.shadow_bias, 1 / @as(f32, @floatFromInt(self.resolution)), index, 1 };
        return true;
    }
};

/// How many local shadow maps fit across their shared texture, and down it.
pub const local_maps_across = 4;
/// How far apart each local map's camera sits in their uniform buffer: a dynamic offset must be
/// a multiple of 256 bytes.
const local_stride = std.mem.alignForward(usize, @sizeOf(Uniforms), 256);
/// The point lights' cube sides, in the order the shader picks them (`localShadowMap`).
const cube_sides = [6]math.Vec3{ .init(1, 0, 0), .init(-1, 0, 0), .up, .down, .unit_z, .init(0, 0, -1) };
/// Nearest a local light's shadow reaches, in metres.
const local_near_m: f32 = 0.05;

/// Point and spot lights' shadow maps, each a square of one shared depth texture, in the order
/// `lighting.gather` gave them out.
pub const Local = struct {
    texture: vit.Texture,
    view: vit.TextureView,
    uniforms: [slots]vit.Buffer,
    instances: [slots]vit.Buffer,
    groups: [slots]vit.BindGroup,
    /// The whole texture's size; each map is a `local_maps_across`th of it.
    resolution: u32,
    initialized: bool = false,
    slot: usize = 0,
    matrices: [lighting.max_local_shadow_maps][4][4]f32 = @splat(@splat(@splat(0))),
    count: u32 = 0,

    /// Made with `map`'s layout, so they draw through the same pipeline.
    pub fn init(device: vit.Device, quality: render.ShadowQuality, layout: vit.BindGroupLayout, max_drawables: usize) !Local {
        const resolution = quality.resolution();
        const texture = try vit.Texture.init(device, .{ .label = "local shadow depth", .width = resolution, .height = resolution, .format = .d32_float, .usage = .{ .depth_stencil_attachment = true, .sampled = true } });
        errdefer texture.deinit();
        const view = try vit.TextureView.init(device, .{ .texture = texture, .aspect = .depth });
        errdefer view.deinit();
        var uniforms: [slots]vit.Buffer = undefined;
        var instances: [slots]vit.Buffer = undefined;
        var groups: [slots]vit.BindGroup = undefined;
        for (0..slots) |i| {
            errdefer for (0..i) |made| {
                groups[made].deinit();
                instances[made].deinit();
                uniforms[made].deinit();
            };
            uniforms[i] = try vit.Buffer.init(device, .{ .label = "local shadow cameras", .size = local_stride * lighting.max_local_shadow_maps, .usage = .{ .uniform = true }, .memory = .upload });
            errdefer uniforms[i].deinit();
            instances[i] = try vit.Buffer.init(device, .{ .label = "local shadow casters", .size = max_drawables * @sizeOf(mesh.Drawable), .usage = .{ .vertex = true }, .memory = .upload });
            errdefer instances[i].deinit();
            groups[i] = try vit.BindGroup.init(device, .{ .layout = layout, .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = uniforms[i], .size = @sizeOf(Uniforms) } } }} });
        }
        return .{ .texture = texture, .view = view, .uniforms = uniforms, .instances = instances, .groups = groups, .resolution = resolution };
    }

    pub fn deinit(self: *Local) void {
        for (self.groups, self.instances, self.uniforms) |group, instance, uniform| {
            group.deinit();
            instance.deinit();
            uniform.deinit();
        }
        self.view.deinit();
        self.texture.deinit();
    }

    /// Point each map's camera from its light; returns how many maps there are.
    pub fn fit(self: *Local, lights: *const lighting.Frame) u32 {
        self.count = 0;
        for (lights.lights[0..lights.count]) |light| {
            if (light.cone_shadow[2] < 0.5 or light.position_kind[3] < 0.5) continue;
            const first: usize = @intFromFloat(light.cone_shadow[3]);
            const views = localViews(light);
            const sides: usize = if (light.position_kind[3] < 1.5) 6 else 1;
            for (views[0..sides], first..) |view, map| self.matrices[map] = transform.columns(view.viewProjection(1));
            self.count = @max(self.count, @as(u32, @intCast(first + sides)));
        }
        return self.count;
    }

    /// Map `index`'s camera's offset in its uniform buffer.
    pub fn offset(index: usize) u32 {
        return @intCast(index * local_stride);
    }

    /// Write each map's camera for this frame into `slot`'s buffer.
    pub fn upload(self: *Local, slot: usize) !void {
        if (self.count == 0) return;
        const size = local_stride * self.count;
        const mapped = try self.uniforms[slot].map(.write, .{ .size = size });
        for (self.matrices[0..self.count], 0..) |matrix, index| {
            const camera_uniforms = Uniforms{ .view_projection = matrix };
            @memcpy(mapped[offset(index)..][0..@sizeOf(Uniforms)], std.mem.asBytes(&camera_uniforms));
        }
        self.uniforms[slot].unmap(.{ .size = size });
    }

    /// Where map `index` is drawn in the shared texture, in pixels.
    pub fn rect(self: Local, index: usize) vit.hal.command.ScissorRect {
        const size = self.resolution / local_maps_across;
        return .{ .x = @intCast(index % local_maps_across * size), .y = @intCast(index / local_maps_across * size), .width = size, .height = size };
    }
};

/// The cameras a point (six, one for each cube side, in `cube_sides`' order) or spot (one, the
/// first) light's shadows are seen from.
pub fn localViews(light: lighting.GpuLight) [6]camera.View {
    const eye = math.Vec3.fromArray(light.position_kind[0..3].*);
    const range = @max(light.direction_range[3], local_near_m * 2);
    var views: [6]camera.View = undefined;
    if (light.position_kind[3] < 1.5) {
        // A little wider than a cube side, so filtering at a side's edge stays inside it.
        for (&views, cube_sides) |*view, side| view.* = .{ .eye = eye, .forward = side, .up = if (@abs(side.y) > 0.5) .unit_z else .up, .fov_deg = 95, .near = local_near_m, .far = range };
        return views;
    }
    const forward = math.Vec3.fromArray(light.direction_range[0..3].*);
    const up: math.Vec3 = if (@abs(forward.y) > 0.95) .unit_z else .up;
    const right = forward.cross(up).normalize();
    const cone_deg = std.math.acos(std.math.clamp(light.cone_shadow[1], -1, 1)) * std.math.deg_per_rad;
    views[0] = .{ .eye = eye, .forward = forward, .up = right.cross(forward), .fov_deg = @min(170, cone_deg * 2 + 10), .near = local_near_m, .far = range };
    return views;
}

pub fn fitCamera(view: camera.View, aspect: f32, direction: math.Vec3, distance_m: f32, resolution: u32) camera.View {
    const distance = @min(view.far, distance_m);
    const half_height = if (view.projection == .orthographic) view.orthographic_height_m / 2 else distance * @tan(view.fov_deg * std.math.rad_per_deg / 2);
    const radius = @max(1, @sqrt(distance * distance / 4 + half_height * half_height * (1 + aspect * aspect)));
    var center = view.eye.add(view.forward.scale(distance / 2));
    const up_hint: math.Vec3 = if (@abs(direction.y) > 0.95) .unit_z else .up;
    const right = direction.cross(up_hint).normalize();
    const up = right.cross(direction).normalize();
    const texel_m = 2 * radius / @as(f32, @floatFromInt(resolution));
    for ([_]math.Vec3{ right, up }) |axis| {
        const coordinate = center.dot(axis);
        center = center.add(axis.scale(@round(coordinate / texel_m) * texel_m - coordinate));
    }
    const eye = center.sub(direction.scale(radius * 2));
    return .{ .eye = eye, .forward = direction, .up = up, .near = 0.01, .far = radius * 4, .projection = .orthographic, .orthographic_height_m = radius * 2 };
}

test "a point light's cube sides each look the way the shader picks them for" {
    const light = lighting.GpuLight{ .position_kind = .{ 1, 2, 3, 1 }, .direction_range = .{ 0, 0, -1, 10 } };
    const views = localViews(light);
    for (views, cube_sides) |view, side| {
        // A point a little along the side, from the light, lands in the middle of its map.
        const point = view.eye.add(side.scale(2));
        const columns = transform.columns(view.viewProjection(1));
        var clip: [4]f32 = @splat(0);
        for (columns, [4]f32{ point.x, point.y, point.z, 1 }) |column, coordinate| {
            for (&clip, column) |*value, entry| value.* += entry * coordinate;
        }
        try std.testing.expect(clip[3] > 0);
        try std.testing.expectApproxEqAbs(@as(f32, 0), clip[0] / clip[3], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0), clip[1] / clip[3], 1e-4);
    }
}

test "local maps tile the shared texture row by row" {
    const local = Local{ .texture = undefined, .view = undefined, .uniforms = undefined, .instances = undefined, .groups = undefined, .resolution = 2048 };
    try std.testing.expectEqual(vit.hal.command.ScissorRect{ .x = 512, .y = 512, .width = 512, .height = 512 }, local.rect(5));
    try std.testing.expectEqual(@as(u32, 0), Local.offset(0) % 256);
    try std.testing.expectEqual(@as(u32, 0), Local.offset(3) % 256);
}

test "shadow fitting remains finite for vertical lights and preserves texel stability" {
    const first = fitCamera(camera.View.default, 16.0 / 9.0, .down, 60, 2048);
    const matrix = transform.columns(first.viewProjection(1));
    for (matrix) |column| for (column) |value| try std.testing.expect(std.math.isFinite(value));
    var moved = camera.View.default;
    moved.eye.x += 0.00001;
    const second = fitCamera(moved, 16.0 / 9.0, .down, 60, 2048);
    try std.testing.expectApproxEqAbs(first.eye.x, second.eye.x, 0.000001);
}
