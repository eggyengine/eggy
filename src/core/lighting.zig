//! Validated scene lights and ambient exposure gathered into a renderer-owned frame.
const std = @import("std");
const ecs = @import("clutch");
const transform = @import("transform.zig");
pub const support: @import("support.zig").Support = .available;
pub const max_lights = 16;

pub const Light = union(enum) {
    directional: struct { color: [3]f32 = @splat(1), illuminance_lux: f32 = 1000 },
    point: struct { color: [3]f32 = @splat(1), intensity_cd: f32 = 100, range_m: f32 = 10 },
    spot: struct { color: [3]f32 = @splat(1), intensity_cd: f32 = 100, range_m: f32 = 10, inner_angle_deg: f32 = 20, outer_angle_deg: f32 = 30 },
};

/// Ambient illumination and photographic exposure shared by all views of the current world.
pub const Environment = struct {
    ambient_color: [3]f32 = @splat(1),
    ambient_intensity: f32 = 0.03,
    exposure_ev: f32 = 0,
    /// Preserve the editor/runtime's helpful light until a scene authors its own lights.
    default_light: bool = true,

    pub fn validate(self: Environment) error{InvalidEnvironment}!void {
        for (self.ambient_color) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidEnvironment;
        if (!std.math.isFinite(self.ambient_intensity) or self.ambient_intensity < 0 or
            !std.math.isFinite(self.exposure_ev) or @abs(self.exposure_ev) > 32) return error.InvalidEnvironment;
    }
};

/// Editable light component. Directional and spot lights shine along local -Z.
pub const SceneLight = struct {
    pub const dependencies = .{transform.Transform};
    kind: enum { directional, point, spot } = .directional,
    color: [3]f32 = @splat(1),
    illuminance_lux: f32 = 1000,
    intensity_cd: f32 = 100,
    range_m: f32 = 10,
    inner_angle_deg: f32 = 20,
    outer_angle_deg: f32 = 30,
    /// One directional shadow caster per world; point/spot shadow maps are not implemented.
    casts_shadows: bool = false,

    pub fn validate(self: SceneLight) error{ InvalidLight, UnsupportedShadowLight }!void {
        for (self.color) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidLight;
        for ([_]f32{ self.illuminance_lux, self.intensity_cd, self.range_m }) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidLight;
        }
        if (self.kind != .directional and self.range_m == 0) return error.InvalidLight;
        if (!std.math.isFinite(self.inner_angle_deg) or !std.math.isFinite(self.outer_angle_deg) or
            self.inner_angle_deg < 0 or self.inner_angle_deg >= self.outer_angle_deg or self.outer_angle_deg >= 90)
            return error.InvalidLight;
        if (self.casts_shadows and self.kind != .directional) return error.UnsupportedShadowLight;
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
    ambient: [4]f32 = .{ 1, 1, 1, 0.03 },
    /// x: exposure multiplier, y: default-light enabled, z: shadow-light index (-1 for none).
    options: [4]f32 = .{ 1, 1, -1, 0 },
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
        if (self.world.get(entity, SceneLight)) |previous|
            component.casts_shadows = previous.casts_shadows and component.kind == .directional;
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

    /// Enable one directional shadow caster without changing existing lights on failure.
    pub fn setShadowCaster(self: Lighting, entity: ?ecs.EntityId) !void {
        if (entity) |id| {
            if (!self.world.isAlive(id)) return error.InvalidEntity;
            const light = self.world.get(id, SceneLight) orelse return error.NoLight;
            if (light.kind != .directional) return error.UnsupportedShadowLight;
            try light.validate();
        }
        var lights = self.world.query(.{*SceneLight});
        while (lights.next()) |view| {
            view.get(*SceneLight).casts_shadows = if (entity) |id| view.entity.eql(id) else false;
            self.world.markChanged(view.entity, SceneLight);
        }
    }

    /// Replace ambient illumination/exposure after validation; HDR environment IBL is separate.
    pub fn setEnvironment(self: Lighting, environment: Environment) !void {
        try environment.validate();
        try self.world.insertResource(environment);
    }
};

/// Gather up to sixteen validated lights; invalid values and overflow are explicit errors.
pub fn gather(world: *ecs.World) !Frame {
    var result = Frame{};
    var environment = if (world.getResource(Environment)) |value| value.* else Environment{};
    if (world.getResource(Environment) == null) {
        var environments = world.query(.{*const Environment});
        if (environments.next()) |view| environment = view.get(*const Environment).*;
        if (environments.next() != null) return error.MultipleEnvironments;
    }
    try environment.validate();
    result.ambient = .{ environment.ambient_color[0], environment.ambient_color[1], environment.ambient_color[2], environment.ambient_intensity };
    result.options = .{ std.math.exp2(environment.exposure_ev), if (environment.default_light) 1 else 0, -1, 0 };
    var lights = world.query(.{ *const SceneLight, *const transform.Transform });
    while (lights.next()) |view| {
        const light = view.get(*const SceneLight).*;
        try light.validate();
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
        if (light.casts_shadows) {
            if (result.options[2] >= 0) return error.TooManyShadowLights;
            result.options[2] = @floatFromInt(result.count);
        }
        result.lights[result.count] = .{
            .position_kind = .{ matrix[3][0], matrix[3][1], matrix[3][2], @floatFromInt(@intFromEnum(light.kind)) },
            .direction_range = .{ direction[0], direction[1], direction[2], light.range_m },
            .color_intensity = .{ light.color[0], light.color[1], light.color[2], if (light.kind == .directional) light.illuminance_lux else light.intensity_cd },
            .cone_shadow = .{ @cos(light.inner_angle_deg * std.math.rad_per_deg), @cos(light.outer_angle_deg * std.math.rad_per_deg), if (light.casts_shadows) 1 else 0, 0 },
        };
        result.entities[result.count] = .{ .id = view.entity.id, .generation = view.entity.generation };
        result.count += 1;
    }
    return result;
}

test "scene lights follow world transforms and validate changes" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const entity = try world.spawn(.{transform.Transform{ .position = .{ 2, 3, 4 } }});
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
    const spot = try world.spawn(.{ transform.Transform{}, SceneLight{ .kind = .spot } });
    const sun = try world.spawn(.{ transform.Transform{}, SceneLight{} });
    const controls = Lighting{ .world = &world };
    try std.testing.expectError(error.UnsupportedShadowLight, controls.setShadowCaster(spot));
    try controls.setShadowCaster(sun);
    try controls.setLight(sun, .{ .directional = .{ .illuminance_lux = 2000 } });
    try std.testing.expect((try controls.getLight(sun)).?.casts_shadows);
    try std.testing.expectError(error.UnsupportedShadowLight, controls.setShadowCaster(spot));
    try std.testing.expect((try controls.getLight(sun)).?.casts_shadows);
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
