//! Validated scene lights and ambient exposure gathered into a renderer-owned frame.
const std = @import("std");
const ecs = @import("clutch");
const math = @import("eggenvector");
const transform = @import("transform.zig");
const post_process = @import("post_process.zig");
const AssetRef = @import("refs.zig").AssetRef;
pub const support: @import("support.zig").Support = .available;
pub const max_lights = 16;
/// The shadow maps point and spot lights share: a spot light takes one, a point light six (one
/// for each side of a cube round it).
pub const max_local_shadow_maps = 16;

pub const Light = union(enum) {
    directional: struct { color: [3]f32 = @splat(1), illuminance_lux: f32 = 1000 },
    point: struct { color: [3]f32 = @splat(1), intensity_cd: f32 = 100, range_m: f32 = 10 },
    spot: struct { color: [3]f32 = @splat(1), intensity_cd: f32 = 100, range_m: f32 = 10, inner_angle_deg: f32 = 20, outer_angle_deg: f32 = 30 },
};

/// Ambient illumination and photographic exposure shared by all views of the current world.
pub const Environment = struct {
    /// Marks it in the editor (nf-md-earth).
    pub const icon = "\u{f01e7}";
    pub const category = "Lighting";
    /// Without a `sky`, light reaching every surface evenly from all round.
    ambient_color: [3]f32 = @splat(1),
    ambient_intensity: f32 = 0.03,
    /// A panorama (twice as wide as it is tall, the horizon across its middle; an `.hdr` or
    /// `.exr` keeps light past white) shown behind the scene, which lights it in place of `ambient_color`: dimly from every side, and in
    /// reflections, sharper the smoother the surface.
    sky: AssetRef(.image) = .{},
    /// How bright the sky is: shown, and the light it gives (scaled by `ambient_intensity`
    /// times 33, so the default matches a plain sky's).
    sky_intensity: f32 = 1,
    exposure_ev: f32 = 0,
    /// Preserve the editor/runtime's helpful light until a scene authors its own lights.
    default_light: bool = true,
    /// The scene's post-processing; a camera's own `PostProcess` replaces it.
    post: post_process.PostProcess = .{},

    pub fn validate(self: Environment) error{InvalidEnvironment}!void {
        self.post.validate() catch return error.InvalidEnvironment;
        for (self.ambient_color) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidEnvironment;
        if (!std.math.isFinite(self.sky_intensity) or self.sky_intensity < 0) return error.InvalidEnvironment;
        if (!std.math.isFinite(self.ambient_intensity) or self.ambient_intensity < 0 or
            !std.math.isFinite(self.exposure_ev) or @abs(self.exposure_ev) > 32) return error.InvalidEnvironment;
    }
};

/// Editable light component. Directional and spot lights shine along local -Z.
pub const SceneLight = struct {
    /// Marks it in the editor (nf-md-lightbulb_on_outline).
    pub const icon = "\u{f06e9}";
    pub const category = "Lighting";
    pub const dependencies = .{transform.Transform};
    kind: enum { directional, point, spot } = .directional,
    color: [3]f32 = @splat(1),
    illuminance_lux: f32 = 1000,
    intensity_cd: f32 = 100,
    range_m: f32 = 10,
    inner_angle_deg: f32 = 20,
    outer_angle_deg: f32 = 30,
    /// One directional light per world casts shadows; point and spot lights share
    /// `max_local_shadow_maps` (six each for point lights, one for spot lights).
    casts_shadows: bool = false,

    /// How many of the shared local shadow maps it takes.
    pub fn shadowMaps(self: SceneLight) u32 {
        if (!self.casts_shadows) return 0;
        return switch (self.kind) {
            .directional => 0,
            .point => 6,
            .spot => 1,
        };
    }

    pub fn validate(self: SceneLight) error{InvalidLight}!void {
        for (self.color) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidLight;
        for ([_]f32{ self.illuminance_lux, self.intensity_cd, self.range_m }) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidLight;
        }
        if (self.kind != .directional and self.range_m == 0) return error.InvalidLight;
        if (!std.math.isFinite(self.inner_angle_deg) or !std.math.isFinite(self.outer_angle_deg) or
            self.inner_angle_deg < 0 or self.inner_angle_deg >= self.outer_angle_deg or self.outer_angle_deg >= 90)
            return error.InvalidLight;
    }
};

pub const GpuLight = extern struct {
    position_kind: [4]f32 = @splat(0),
    direction_range: [4]f32 = @splat(0),
    color_intensity: [4]f32 = @splat(0),
    cone_shadow: [4]f32 = @splat(0),
};

/// Source identity across the game-library boundary, independent of ECS type numbering.
pub const LightEntity = extern struct {
    id: u32 = 0,
    generation: u32 = 0,
};

/// Plain C data, populated where the game's ECS type numbering lives.
pub const Frame = extern struct {
    lights: [max_lights]GpuLight = @splat(.{}),
    /// Parallel source identities for host visibility filtering; never uploaded as uniforms.
    entities: [max_lights]LightEntity = @splat(.{}),
    count: u32 = 0,
    /// Lights left out because their values don't validate (see `SceneLight.validate`).
    invalid: u32 = 0,
    ambient: [4]f32 = .{ 1, 1, 1, 0.03 },
    /// x: exposure multiplier, y: default-light enabled, z: shadow-light index (-1 for none).
    options: [4]f32 = .{ 1, 1, -1, 0 },
    /// How many local shadow maps the lights take (`GpuLight.cone_shadow` w: a light's first).
    local_shadow_maps: u32 = 0,
    /// The sky's image's identity key, if any; it borrows the world's `Environment`, so it
    /// lasts until the world next changes.
    sky_file: ?[*]const u8 = null,
    sky_file_len: u32 = 0,
    /// x: the sky's brightness as shown, y: as light (both 0 without a sky).
    sky: [4]f32 = @splat(0),
    /// The post-processing the active camera sees (`post_process.forActiveCamera`).
    post: post_process.Frame = .{},
};

/// Borrowed component access; obtain it from `app.lighting()`.
pub const Lighting = struct {
    world: *ecs.World,

    pub fn setLight(self: Lighting, entity: ecs.EntityId, light: Light) !void {
        if (!self.world.isAlive(entity)) return error.InvalidEntity;
        var component: SceneLight = switch (light) {
            .directional => |value| .{ .kind = .directional, .color = value.color, .illuminance_lux = value.illuminance_lux },
            .point => |value| .{ .kind = .point, .color = value.color, .intensity_cd = value.intensity_cd, .range_m = value.range_m },
            .spot => |value| .{ .kind = .spot, .color = value.color, .intensity_cd = value.intensity_cd, .range_m = value.range_m, .inner_angle_deg = value.inner_angle_deg, .outer_angle_deg = value.outer_angle_deg },
        };
        if (self.world.get(entity, SceneLight)) |previous| component.casts_shadows = previous.casts_shadows;
        try component.validate();
        if (self.world.get(entity, transform.Transform) == null) try self.world.addComponent(entity, transform.Transform{});
        try self.world.addComponent(entity, component);
        self.world.markChanged(entity, SceneLight);
    }

    pub fn removeLight(self: Lighting, entity: ecs.EntityId) !void {
        if (!self.world.isAlive(entity)) return error.InvalidEntity;
        self.world.remove(entity, SceneLight);
    }

    /// Return a light's current authored settings, or null when this live entity has no light.
    pub fn getLight(self: Lighting, entity: ecs.EntityId) !?SceneLight {
        if (!self.world.isAlive(entity)) return error.InvalidEntity;
        return if (self.world.get(entity, SceneLight)) |value| value.* else null;
    }

    /// Make one directional light the shadow caster (none for no directional shadows), without
    /// changing existing lights on failure. Point and spot lights cast shadows through their
    /// own `casts_shadows`.
    pub fn setShadowCaster(self: Lighting, entity: ?ecs.EntityId) !void {
        if (entity) |id| {
            if (!self.world.isAlive(id)) return error.InvalidEntity;
            const light = self.world.get(id, SceneLight) orelse return error.NoLight;
            if (light.kind != .directional) return error.UnsupportedShadowLight;
            try light.validate();
        }
        var lights = self.world.query(.{*SceneLight});
        while (lights.next()) |view| {
            const light = view.get(*SceneLight);
            if (light.kind != .directional) continue;
            light.casts_shadows = if (entity) |id| view.entity.eql(id) else false;
            self.world.markChanged(view.entity, SceneLight);
        }
    }

    /// Replace ambient illumination/exposure after validation; HDR environment IBL is separate.
    pub fn setEnvironment(self: Lighting, environment: Environment) !void {
        try environment.validate();
        try self.world.insertResource(environment);
    }
};

/// The rotation `aimNewLight` gives a light: down at the ground, from over the left shoulder.
pub const new_light_rotation_deg: math.Vec3 = .init(-50, -30, 0);

/// Tilt a just-added directional or spot light down when `entity` faces the horizon (an
/// unrotated transform), which would leave the ground unlit. Leaves point lights and turned
/// entities alone. For the editor's Add Component, not for loading: scenes keep what they saved.
pub fn aimNewLight(world: *ecs.World, entity: ecs.EntityId) void {
    const light = world.get(entity, SceneLight) orelse return;
    if (light.kind == .point) return;
    const placed = world.get(entity, transform.Transform) orelse return;
    if (!placed.rotation_deg.eql(.zero)) return;
    placed.rotation_deg = new_light_rotation_deg;
    world.markChanged(entity, transform.Transform);
}

const default_environment = Environment{};

/// Gather up to sixteen validated lights. A light whose values don't validate is left out and
/// counted in `invalid`, so one bad light doesn't stop the rest; overflow, a second directional
/// shadow caster, more local shadow maps than there are and a second environment are explicit
/// errors.
pub fn gather(world: *ecs.World) !Frame {
    var result = Frame{};
    // Borrowed, so the post passes' shader keys stay pointing into the world.
    var environment: *const Environment = if (world.getResource(Environment)) |value| value else &default_environment;
    if (world.getResource(Environment) == null) {
        var environments = world.query(.{*const Environment});
        if (environments.next()) |view| environment = view.get(*const Environment);
        if (environments.next() != null) return error.MultipleEnvironments;
    }
    try environment.validate();
    result.ambient = .{ environment.ambient_color[0], environment.ambient_color[1], environment.ambient_color[2], environment.ambient_intensity };
    if (environment.sky.len != 0) {
        result.sky_file = &environment.sky.buffer;
        result.sky_file_len = environment.sky.len;
        result.sky = .{ environment.sky_intensity, environment.sky_intensity * environment.ambient_intensity / default_environment.ambient_intensity, 0, 0 };
    }
    result.options = .{ std.math.exp2(environment.exposure_ev), if (environment.default_light) 1 else 0, -1, 0 };
    result.post = (try post_process.forActiveCamera(world, &environment.post)).frame();
    var lights = world.query(.{ *const SceneLight, *const transform.Transform });
    while (lights.next()) |view| {
        const light = view.get(*const SceneLight).*;
        light.validate() catch {
            result.invalid += 1;
            continue;
        };
        if (result.count == max_lights) return error.TooManyLights;
        const matrix = transform.worldMatrix(world, view.entity).data;
        for (matrix) |column| {
            const values: [4]f32 = column;
            for (values) |value| if (!std.math.isFinite(value)) return error.InvalidLightTransform;
        }
        const forward: @Vector(3, f32) = .{ -matrix[2][0], -matrix[2][1], -matrix[2][2] };
        const length = @sqrt(@reduce(.Add, forward * forward));
        if (light.kind != .point and length < 0.000001) return error.InvalidLightTransform;
        const direction: @Vector(3, f32) = if (light.kind != .point) forward / @as(@Vector(3, f32), @splat(length)) else .{ 0, 0, -1 };
        const first_map = result.local_shadow_maps;
        if (light.casts_shadows and light.kind == .directional) {
            if (result.options[2] >= 0) return error.TooManyShadowLights;
            result.options[2] = @floatFromInt(result.count);
        }
        if (first_map + light.shadowMaps() > max_local_shadow_maps) return error.TooManyShadowLights;
        result.local_shadow_maps += light.shadowMaps();
        result.lights[result.count] = .{
            .position_kind = .{ matrix[3][0], matrix[3][1], matrix[3][2], @floatFromInt(@backingInt(light.kind)) },
            .direction_range = .{ direction[0], direction[1], direction[2], light.range_m },
            .color_intensity = .{ light.color[0], light.color[1], light.color[2], if (light.kind == .directional) light.illuminance_lux else light.intensity_cd },
            .cone_shadow = .{ @cos(light.inner_angle_deg * std.math.rad_per_deg), @cos(light.outer_angle_deg * std.math.rad_per_deg), if (light.casts_shadows) 1 else 0, @floatFromInt(first_map) },
        };
        result.entities[result.count] = .{ .id = view.entity.id, .generation = view.entity.generation };
        result.count += 1;
    }
    return result;
}

test "scene lights follow world transforms and validate changes" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const entity = try world.spawn(.{transform.Transform{ .position = .init(2, 3, 4) }});
    const lighting = Lighting{ .world = &world };
    try lighting.setLight(entity, .{ .point = .{ .range_m = 5 } });
    const frame = try gather(&world);
    try std.testing.expectEqual(@as(u32, 1), frame.count);
    try std.testing.expectEqual(entity.id, frame.entities[0].id);
    try std.testing.expectEqual(entity.generation, frame.entities[0].generation);
    try std.testing.expectEqualSlices(f32, &.{ 2, 3, 4, 1 }, &frame.lights[0].position_kind);
    try std.testing.expectEqual(@as(f32, 5), frame.lights[0].direction_range[3]);
    try std.testing.expectError(error.InvalidLight, lighting.setLight(entity, .{ .point = .{ .range_m = -1 } }));
    try lighting.removeLight(entity);
    try std.testing.expectEqual(@as(u32, 0), (try gather(&world)).count);
}

test "a new light facing the horizon is tilted down to light the ground" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const sun = try world.spawn(.{ transform.Transform{}, SceneLight{} });
    aimNewLight(&world, sun);
    try std.testing.expectEqual(new_light_rotation_deg, world.get(sun, transform.Transform).?.rotation_deg);
    // The ground (+y) now faces it.
    const frame = try gather(&world);
    try std.testing.expect(frame.lights[0].direction_range[1] < -0.5);

    const turned = try world.spawn(.{ transform.Transform{ .rotation_deg = .init(-90, 0, 0) }, SceneLight{} });
    aimNewLight(&world, turned);
    try std.testing.expectEqual(math.Vec3.init(-90, 0, 0), world.get(turned, transform.Transform).?.rotation_deg);
    const bulb = try world.spawn(.{ transform.Transform{}, SceneLight{ .kind = .point } });
    aimNewLight(&world, bulb);
    try std.testing.expectEqual(math.Vec3.zero, world.get(bulb, transform.Transform).?.rotation_deg);
}

test "light overflow is reported rather than silently dropping lights" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    for (0..max_lights + 1) |_| _ = try world.spawn(.{ transform.Transform{}, SceneLight{} });
    try std.testing.expectError(error.TooManyLights, gather(&world));
}

test "light source identities retain reused generations without changing GPU records" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const old = try world.spawn(.{ transform.Transform{}, SceneLight{} });
    world.despawn(old);
    const replacement = try world.spawn(.{ transform.Transform{}, SceneLight{} });
    try std.testing.expectEqual(old.id, replacement.id);
    try std.testing.expect(old.generation != replacement.generation);
    const frame = try gather(&world);
    try std.testing.expectEqual(@as(u32, 1), frame.count);
    try std.testing.expectEqual(replacement.id, frame.entities[0].id);
    try std.testing.expectEqual(replacement.generation, frame.entities[0].generation);
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(GpuLight));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(LightEntity));
}

test "spot cones exposure and exclusive directional shadows are validated" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const spot = try world.spawn(.{ transform.Transform{}, SceneLight{ .kind = .spot, .casts_shadows = true } });
    const sun = try world.spawn(.{ transform.Transform{}, SceneLight{} });
    const controls = Lighting{ .world = &world };
    try std.testing.expectError(error.UnsupportedShadowLight, controls.setShadowCaster(spot));
    try controls.setShadowCaster(sun);
    try controls.setLight(sun, .{ .directional = .{ .illuminance_lux = 2000 } });
    try std.testing.expect((try controls.getLight(sun)).?.casts_shadows);
    // Choosing the directional caster leaves the spot light's own shadows alone.
    try std.testing.expect((try controls.getLight(spot)).?.casts_shadows);
    try controls.setEnvironment(.{ .default_light = false, .exposure_ev = 1 });
    const frame = try gather(&world);
    try std.testing.expectEqual(@as(f32, 2), frame.options[0]);
    try std.testing.expectEqual(@as(f32, 0), frame.options[1]);
    try std.testing.expect(frame.options[2] >= 0);
    try std.testing.expectError(error.InvalidEnvironment, controls.setEnvironment(.{ .exposure_ev = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidLight, (SceneLight{ .kind = .spot, .inner_angle_deg = 40, .outer_angle_deg = 20 }).validate());
}

test "multiple authored environments or shadow casters are explicit errors" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{Environment{}});
    _ = try world.spawn(.{Environment{}});
    try std.testing.expectError(error.MultipleEnvironments, gather(&world));
    try (Lighting{ .world = &world }).setEnvironment(.{});
    _ = try world.spawn(.{ transform.Transform{}, SceneLight{ .casts_shadows = true } });
    _ = try world.spawn(.{ transform.Transform{}, SceneLight{ .casts_shadows = true } });
    try std.testing.expectError(error.TooManyShadowLights, gather(&world));
}

/// Warn when the number of lights `frame` left out as invalid changes to one or more; `reported`
/// keeps the number last reported between frames.
pub fn reportInvalid(frame: Frame, reported: *u32) void {
    if (frame.invalid == reported.*) return;
    reported.* = frame.invalid;
    if (frame.invalid > 0) std.log.warn("{d} scene light(s) left out: check their values", .{frame.invalid});
}

test "point and spot shadows take their maps in turn, and running out is an error" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{ transform.Transform{}, SceneLight{ .kind = .point, .casts_shadows = true } });
    _ = try world.spawn(.{ transform.Transform{}, SceneLight{ .kind = .spot, .casts_shadows = true } });
    _ = try world.spawn(.{ transform.Transform{}, SceneLight{ .kind = .point } });
    const frame = try gather(&world);
    try std.testing.expectEqual(@as(u32, 7), frame.local_shadow_maps);
    var firsts: [2]f32 = undefined;
    var casting: usize = 0;
    for (frame.lights[0..frame.count]) |light| if (light.cone_shadow[2] > 0.5) {
        firsts[casting] = light.cone_shadow[3];
        casting += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), casting);
    // Whichever comes first, the second starts where the first's maps end.
    try std.testing.expect((firsts[0] == 0 and (firsts[1] == 6 or firsts[1] == 1)) or (firsts[1] == 0 and (firsts[0] == 6 or firsts[0] == 1)));
    _ = try world.spawn(.{ transform.Transform{}, SceneLight{ .kind = .point, .casts_shadows = true } });
    _ = try world.spawn(.{ transform.Transform{}, SceneLight{ .kind = .point, .casts_shadows = true } });
    try std.testing.expectError(error.TooManyShadowLights, gather(&world));
}

test "a sky lights in proportion to the ambient intensity" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    try (Lighting{ .world = &world }).setEnvironment(.{ .sky = .init("resources/sky.png"), .sky_intensity = 2, .ambient_intensity = 0.06 });
    const frame = try gather(&world);
    try std.testing.expectEqualStrings(AssetRef(.image).init("resources/sky.png").key(), frame.sky_file.?[0..frame.sky_file_len]);
    try std.testing.expectEqual(@as(f32, 2), frame.sky[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 4), frame.sky[1], 1e-5);
    try std.testing.expectError(error.InvalidEnvironment, (Environment{ .sky_intensity = -1 }).validate());
}

test "an invalid light is left out, and the others still gathered" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{ transform.Transform{}, SceneLight{ .kind = .directional } });
    _ = try world.spawn(.{ transform.Transform{}, SceneLight{ .kind = .point, .range_m = 0 } });
    const frame = try gather(&world);
    try std.testing.expectEqual(@as(u32, 1), frame.count);
    try std.testing.expectEqual(@as(u32, 1), frame.invalid);
}

test "a light taken off an entity that stays is no longer gathered" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const entity = try world.spawn(.{ transform.Transform{}, SceneLight{ .kind = .directional } });
    try std.testing.expectEqual(@as(u32, 1), (try gather(&world)).count);
    world.remove(entity, SceneLight);
    try std.testing.expect(world.isAlive(entity));
    try std.testing.expectEqual(@as(u32, 0), (try gather(&world)).count);
}
