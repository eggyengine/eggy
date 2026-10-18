//! Light request contracts beyond the renderer's built-in shading.
const api = @import("support.zig");
const ecs = @import("clutch");
pub const support: api.Support = .not_implemented;
pub const Light = union(enum) {
    directional: struct { color: [3]f32 = @splat(1), illuminance_lux: f32 = 1000 },
    point: struct { color: [3]f32 = @splat(1), intensity_cd: f32 = 100, range_m: f32 = 10 },
};

// ponytail: scene lights are not rendered, add light gathering and shaders first.
pub const Lighting = struct {
    /// Request a directional light (lux) or point light (candela, range in metres) on an entity.
    /// Currently returns `NotImplemented`, without changing components or built-in shading.
    ///
    /// ```zig
    /// try app.lighting.setLight(entity, .{ .point = .{ .intensity_cd = 200, .range_m = 5 } });
    /// // Currently returns NotImplemented.
    /// ```
    pub fn setLight(_: Lighting, entity: ecs.EntityId, light: Light) api.Error!void {
        return api.notImplemented(.{ entity, light });
    }
    /// Request removal of an entity's light, not deletion of the entity itself.
    /// Currently returns `NotImplemented`, with no world or renderer changes.
    ///
    /// ```zig
    /// try app.lighting.removeLight(entity); // Currently NotImplemented.
    /// ```
    pub fn removeLight(_: Lighting, entity: ecs.EntityId) api.Error!void {
        return api.notImplemented(entity);
    }
};
