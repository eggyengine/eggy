//! Directional and point scene lights gathered into a renderer-owned frame.
const std = @import("std");
const ecs = @import("clutch");
const transform = @import("transform.zig");
pub const support: @import("support.zig").Support = .available;
pub const max_lights = 16;

pub const Light = union(enum) {
    directional: struct { color: [3]f32 = @splat(1), illuminance_lux: f32 = 1000 },
    point: struct { color: [3]f32 = @splat(1), intensity_cd: f32 = 100, range_m: f32 = 10 },
};

/// Editable light component. Local -Z is the direction a directional light shines.
pub const SceneLight = struct {
    pub const dependencies = .{transform.Transform};
    kind: enum { directional, point } = .directional,
    color: [3]f32 = @splat(1),
    illuminance_lux: f32 = 1000,
    intensity_cd: f32 = 100,
    range_m: f32 = 10,

    pub fn validate(self: SceneLight) error{InvalidLight}!void {
        for (self.color) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidLight;
        for ([_]f32{ self.illuminance_lux, self.intensity_cd, self.range_m }) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidLight;
        }
        if (self.kind == .point and self.range_m == 0) return error.InvalidLight;
    }
};

pub const GpuLight = extern struct {
    position_kind: [4]f32 = @splat(0),
    direction_range: [4]f32 = @splat(0),
    color_intensity: [4]f32 = @splat(0),
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
};

/// Borrowed component access; obtain it from `app.lighting()`.
pub const Lighting = struct {
    world: *ecs.World,

    pub fn setLight(self: Lighting, entity: ecs.EntityId, light: Light) !void {
        if (!self.world.isAlive(entity)) return error.InvalidEntity;
        const component: SceneLight = switch (light) {
            .directional => |value| .{ .kind = .directional, .color = value.color, .illuminance_lux = value.illuminance_lux },
            .point => |value| .{ .kind = .point, .color = value.color, .intensity_cd = value.intensity_cd, .range_m = value.range_m },
        };
        try component.validate();
        if (self.world.get(entity, transform.Transform) == null) try self.world.addComponent(entity, transform.Transform{});
        try self.world.addComponent(entity, component);
        self.world.markChanged(entity, SceneLight);
    }

    pub fn removeLight(self: Lighting, entity: ecs.EntityId) !void {
        if (!self.world.isAlive(entity)) return error.InvalidEntity;
        self.world.remove(entity, SceneLight);
    }
};

/// Gather up to sixteen validated lights; invalid values and overflow are explicit errors.
pub fn gather(world: *ecs.World) !Frame {
    var result = Frame{};
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
        if (light.kind == .directional and length < 0.000001) return error.InvalidLightTransform;
        const direction: @Vector(3, f32) = if (light.kind == .directional) forward / @as(@Vector(3, f32), @splat(length)) else .{ 0, 0, -1 };
        result.lights[result.count] = .{
            .position_kind = .{ matrix[3][0], matrix[3][1], matrix[3][2], if (light.kind == .point) 1 else 0 },
            .direction_range = .{ direction[0], direction[1], direction[2], light.range_m },
            .color_intensity = .{ light.color[0], light.color[1], light.color[2], if (light.kind == .directional) light.illuminance_lux / 1000 else light.intensity_cd / 100 },
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
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(GpuLight));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(LightEntity));
}
