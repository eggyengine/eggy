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
    pub fn setLight(_: Lighting, entity: ecs.EntityId, light: Light) api.Error!void {
        return api.notImplemented(.{ entity, light });
    }
    pub fn removeLight(_: Lighting, entity: ecs.EntityId) api.Error!void {
        return api.notImplemented(entity);
    }
};
