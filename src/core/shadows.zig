//! Directional shadow-map ownership and texel-stable camera fitting.
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
        const layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .vertex = true, .fragment = true } },
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
            groups[i] = try vit.BindGroup.init(device, .{ .layout = layout, .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = uniforms[i] } } }} });
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

test "shadow fitting remains finite for vertical lights and preserves texel stability" {
    const first = fitCamera(camera.View.default, 16.0 / 9.0, .down, 60, 2048);
    const matrix = transform.columns(first.viewProjection(1));
    for (matrix) |column| for (column) |value| try std.testing.expect(std.math.isFinite(value));
    var moved = camera.View.default;
    moved.eye.x += 0.00001;
    const second = fitCamera(moved, 16.0 / 9.0, .down, 60, 2048);
    try std.testing.expectApproxEqAbs(first.eye.x, second.eye.x, 0.000001);
}
