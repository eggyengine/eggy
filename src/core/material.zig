//! The serializable material component used by mesh gathering and the Inspector.
const std = @import("std");
const AssetRef = @import("refs.zig").AssetRef;

/// Surface properties on a Mesh entity. An optional asset replaces all inline properties.
/// Alpha is cut out below `alpha_cutoff`; translucent blending is not supported.
pub const Material = struct {
    /// Marks it in the editor (nf-md-palette).
    pub const icon = "\u{f03d8}";
    pub const category = "Rendering";
    file: AssetRef(.material) = .{},
    color: [4]f32 = @splat(1),
    texture: AssetRef(.image) = .{},
    metallic: f32 = 0,
    roughness: f32 = 1,
    emissive_color: [3]f32 = @splat(0),
    unlit: bool = false,
    alpha_cutoff: f32 = 0.01,
    /// A surface shader (`Surface surface(SurfaceInput input)`) that changes how the surface
    /// looks before it is lit; none draws it as these fields say.
    shader: AssetRef(.shader) = .{},

    pub fn validate(self: Material) error{InvalidMaterial}!void {
        for (self.color) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidMaterial;
        for (self.emissive_color) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidMaterial;
        for ([_]f32{ self.metallic, self.roughness, self.alpha_cutoff }) |value| {
            if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidMaterial;
        }
    }
};
