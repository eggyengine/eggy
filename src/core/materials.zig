//! Material assignment contracts beyond the current Mesh color and texture.
const api = @import("support.zig");
const ecs = @import("clutch");
pub const support: api.Support = .not_implemented;
pub const Material = struct { color: [4]f32 = @splat(1), metallic: f32 = 0, roughness: f32 = 1 };

// ponytail: the renderer has no material system, add a material pipeline before assignment.
pub const Materials = struct {
    pub fn assign(_: Materials, entity: ecs.EntityId, material: Material) api.Error!void {
        return api.notImplemented(.{ entity, material });
    }
    pub fn applyEffect(_: Materials, effect: enum { bloom, tone_mapping }, strength: f32) api.Error!void {
        return api.notImplemented(.{ effect, strength });
    }
};
