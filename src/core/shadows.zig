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

/// How many cascades the directional light's map is split into, each a quarter of its texture,
/// nearest the camera first.
pub const cascades = 4;
/// How many cascades fit across the directional map's texture, and down it.
const cascades_across = 2;
/// The share of each cascade's reach, at its far end, that fades into the next one.
pub const cascade_blend = 0.1;
/// How far the cascades lean towards splitting the shadow distance evenly by ratio (detail
/// near the camera) rather than by distance.
const cascade_split_ratio: f32 = 0.8;

/// The directional light's shadow map: `cascades` maps of one texture, each covering a stretch of
/// the view farther out than the last, so shadows near the camera stay sharp.
pub const Map = struct {
    texture: vit.Texture,
    view: vit.TextureView,
    sampler: vit.Sampler,
    layout: vit.BindGroupLayout,
    /// Each cascade's camera, `cameraOffset` apart.
    uniforms: [slots]vit.Buffer,
    instances: [slots]vit.Buffer,
    groups: [slots]vit.BindGroup,
    resolution: u32,
    initialized: bool = false,
    slot: usize = 0,
    matrices: [cascades][4][4]f32 = @splat(@splat(@splat(0))),
    /// How far along the view each cascade reaches, in metres.
    splits_m: [cascades]f32 = @splat(0),
    /// One shadow texel's width in each cascade, in metres.
    texels_m: [cascades]f32 = @splat(0),
    params: [4]f32 = @splat(0),

    pub fn init(device: vit.Device, quality: render.ShadowQuality, max_drawables: usize) !Map {
        const resolution = quality.resolution();
        const texture = try vit.Texture.init(device, .{ .label = "directional shadow depth", .width = resolution, .height = resolution, .format = .d32_float, .usage = .{ .depth_stencil_attachment = true, .sampled = true } });
        errdefer texture.deinit();
        const view = try vit.TextureView.init(device, .{ .texture = texture, .aspect = .depth });
        errdefer view.deinit();
        // Linear filtering compares the four nearest texels and blends them, softening each tap.
        const sampler = try vit.Sampler.init(device, .{ .address_u = .clamp_to_edge, .address_v = .clamp_to_edge, .compare = .less_equal, .mag_filter = .linear, .min_filter = .linear, .mipmap_filter = .nearest });
        errdefer sampler.deinit();
        // A dynamic offset picks each map's camera from one buffer.
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
            uniforms[i] = try vit.Buffer.init(device, .{ .label = "cascade cameras", .size = camera_stride * cascades, .usage = .{ .uniform = true }, .memory = .upload });
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

    /// Fit each cascade round its stretch of the camera's view, texel-stable. One directional
    /// light is selected explicitly by `Lighting.setShadowCaster`.
    pub fn fit(self: *Map, view: camera.View, aspect: f32, lights: *const lighting.Frame, settings: render.Settings) bool {
        self.params = @splat(0);
        const index = lights.options[2];
        if (settings.shadow_quality == .off or index < 0 or index >= @as(f32, @floatFromInt(lights.count))) return false;
        const light = lights.lights[@intFromFloat(index)];
        const direction = math.Vec3.fromArray(light.direction_range[0..3].*);
        const tile = self.resolution / cascades_across;
        const reach = @min(view.far, settings.shadow_distance_m);
        self.splits_m = cascadeSplits(view.near, reach);
        var start = view.near;
        var previous: f32 = 0;
        for (self.splits_m, 0..) |split, cascade| {
            const fitted = fitCamera(view, aspect, direction, start, split, reach, tile);
            self.matrices[cascade] = transform.columns(fitted.viewProjection(1));
            self.texels_m[cascade] = fitted.orthographic_height_m / @as(f32, @floatFromInt(tile));
            // The next cascade starts where the shader begins fading this one into it.
            start = split - (split - previous) * cascade_blend;
            previous = split;
        }
        self.params = .{ settings.shadow_bias, 1 / @as(f32, @floatFromInt(self.resolution)), index, 1 };
        return true;
    }

    /// Write each cascade's camera for this frame into `slot`'s buffer.
    pub fn upload(self: *Map, slot: usize) !void {
        try uploadCameras(self.uniforms[slot], &self.matrices);
    }

    /// Where cascade `index` is drawn in the texture, in pixels.
    pub fn rect(self: Map, index: usize) vit.hal.command.ScissorRect {
        return tileRect(self.resolution, cascades_across, index);
    }
};

/// Where each cascade ends along a view from `near_m` to `reach_m`: between even ratios (as
/// perspective shrinks texels) and even distances.
pub fn cascadeSplits(near_m: f32, reach_m: f32) [cascades]f32 {
    const near = @max(near_m, 0.01);
    const far = @max(reach_m, near * 2);
    var splits: [cascades]f32 = undefined;
    for (&splits, 1..) |*split, i| {
        const share = @as(f32, @floatFromInt(i)) / cascades;
        const by_ratio = near * std.math.pow(f32, far / near, share);
        const by_distance = near + (far - near) * share;
        split.* = by_ratio * cascade_split_ratio + by_distance * (1 - cascade_split_ratio);
    }
    splits[cascades - 1] = far;
    return splits;
}

/// How far apart each map's camera sits in a shadow uniform buffer: a dynamic offset must be a
/// multiple of 256 bytes.
const camera_stride = std.mem.alignForward(usize, @sizeOf(Uniforms), 256);

/// Map `index`'s camera's offset in its uniform buffer.
pub fn cameraOffset(index: usize) u32 {
    return @intCast(index * camera_stride);
}

// Each of `matrices` as a camera, `camera_stride` apart in `buffer`.
fn uploadCameras(buffer: vit.Buffer, matrices: []const [4][4]f32) !void {
    if (matrices.len == 0) return;
    const size = camera_stride * matrices.len;
    const mapped = try buffer.map(.write, .{ .size = size });
    for (matrices, 0..) |matrix, index| {
        const camera_uniforms = Uniforms{ .view_projection = matrix };
        @memcpy(mapped[cameraOffset(index)..][0..@sizeOf(Uniforms)], std.mem.asBytes(&camera_uniforms));
    }
    buffer.unmap(.{ .size = size });
}

// Square `index` of a texture `resolution` wide split into `across` by `across`, row by row.
fn tileRect(resolution: u32, across: u32, index: usize) vit.hal.command.ScissorRect {
    const size = resolution / across;
    return .{ .x = @intCast(index % across * size), .y = @intCast(index / across * size), .width = size, .height = size };
}

/// How many local shadow maps fit across their shared texture, and down it.
pub const local_maps_across = 4;
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
            uniforms[i] = try vit.Buffer.init(device, .{ .label = "local shadow cameras", .size = camera_stride * lighting.max_local_shadow_maps, .usage = .{ .uniform = true }, .memory = .upload });
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

    /// Write each map's camera for this frame into `slot`'s buffer.
    pub fn upload(self: *Local, slot: usize) !void {
        try uploadCameras(self.uniforms[slot], self.matrices[0..self.count]);
    }

    /// Where map `index` is drawn in the shared texture, in pixels.
    pub fn rect(self: Local, index: usize) vit.hal.command.ScissorRect {
        return tileRect(self.resolution, local_maps_across, index);
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

/// An orthographic camera looking along `direction` round the stretch of `view` from `near_m`
/// to `far_m`, its texels fixed in the world as the view moves and turns, seeing casters up to
/// `reach_m` behind that stretch.
pub fn fitCamera(view: camera.View, aspect: f32, direction: math.Vec3, near_m: f32, far_m: f32, reach_m: f32, resolution: u32) camera.View {
    const near = @min(near_m, far_m);
    const far = @min(view.far, far_m);
    // The smallest sphere round the stretch, which depends only on the lens, so it holds still
    // as the view turns. A corner lies `depth * spread` off the view's axis.
    var middle: f32 = undefined;
    var radius: f32 = undefined;
    if (view.projection == .orthographic) {
        const half_height = view.orthographic_height_m / 2;
        middle = (near + far) / 2;
        radius = @sqrt((far - near) * (far - near) / 4 + half_height * half_height * (1 + aspect * aspect));
    } else {
        const tan_half = @tan(view.fov_deg * std.math.rad_per_deg / 2);
        const spread2 = tan_half * tan_half * (1 + aspect * aspect);
        middle = @min(far, (far + near) * (1 + spread2) / 2);
        radius = @sqrt((far - middle) * (far - middle) + far * far * spread2);
    }
    radius = @max(radius, 0.5);
    var center = view.eye.add(view.forward.scale(middle));
    const up_hint: math.Vec3 = if (@abs(direction.y) > 0.95) .unit_z else .up;
    const right = direction.cross(up_hint).normalize();
    const up = right.cross(direction).normalize();
    const texel_m = 2 * radius / @as(f32, @floatFromInt(resolution));
    for ([_]math.Vec3{ right, up }) |axis| {
        const coordinate = center.dot(axis);
        center = center.add(axis.scale(@round(coordinate / texel_m) * texel_m - coordinate));
    }
    const behind = radius + @max(reach_m, radius);
    const eye = center.sub(direction.scale(behind));
    return .{ .eye = eye, .forward = direction, .up = up, .near = 0.01, .far = behind + radius, .projection = .orthographic, .orthographic_height_m = radius * 2 };
}

test "cascades reach further each, end at the shadow distance and keep their size as the view turns" {
    const splits = cascadeSplits(0.1, 60);
    for (splits[1..], splits[0 .. cascades - 1]) |later, earlier| try std.testing.expect(later > earlier);
    try std.testing.expectEqual(@as(f32, 60), splits[cascades - 1]);
    try std.testing.expect(splits[0] < 6);

    var turned = camera.View.default;
    turned.forward = math.Vec3.init(1, -0.2, 0.3).normalize();
    const straight = fitCamera(camera.View.default, 16.0 / 9.0, .down, 0.1, splits[0], 60, 1024);
    const sideways = fitCamera(turned, 16.0 / 9.0, .down, 0.1, splits[0], 60, 1024);
    try std.testing.expectApproxEqAbs(straight.orthographic_height_m, sideways.orthographic_height_m, 1e-4);
    // Casters as far back as the shadow distance stay in front of the light's camera.
    try std.testing.expect(straight.far - straight.orthographic_height_m >= 60);
}
