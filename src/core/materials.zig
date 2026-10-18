//! Material assignment contracts beyond the current Mesh color and texture.
const api = @import("support.zig");
const ecs = @import("clutch");
pub const support: api.Support = .not_implemented;
pub const Material = struct { color: [4]f32 = @splat(1), metallic: f32 = 0, roughness: f32 = 1 };

// ponytail: the renderer has no material system, add a material pipeline before assignment.
pub const Materials = struct {
    /// Request RGBA color, metallic and roughness parameters for an entity.
    /// Currently returns `NotImplemented`, without validating parameters or changing Mesh.
    /// Existing Mesh color/texture fields remain the working rendering path.
    ///
    /// ```zig
    /// try app.materials.assign(entity, .{ .metallic = 0.8, .roughness = 0.2 });
    /// // Currently returns NotImplemented.
    /// ```
    pub fn assign(_: Materials, entity: ecs.EntityId, material: Material) api.Error!void {
        return api.notImplemented(.{ entity, material });
    }
    /// Request a named renderer effect and its strength.
    /// Currently returns `NotImplemented`; no postprocessing pass or strength validation occurs.
    ///
    /// ```zig
    /// try app.materials.applyEffect(.bloom, 0.5); // Currently NotImplemented.
    /// ```
    pub fn applyEffect(_: Materials, effect: enum { bloom, tone_mapping }, strength: f32) api.Error!void {
        return api.notImplemented(.{ effect, strength });
    }
};
