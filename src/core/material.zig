//! The serializable material component used by mesh gathering and the Inspector.
const std = @import("std");
const AssetRef = @import("refs.zig").AssetRef;

/// Surface properties on a Mesh entity. An optional asset replaces all inline properties. Each
/// map left unset falls back to the model's own (for a model file), else to a neutral one.
pub const Material = struct {
    /// Marks it in the editor (nf-md-palette).
    pub const icon = "\u{f03d8}";
    pub const category = "Rendering";
    pub const AlphaMode = @import("eggy_assets").model.AlphaMode;
    file: AssetRef(.material) = .{},
    color: [4]f32 = @splat(1),
    texture: AssetRef(.image) = .{},
    /// Tangent-space normals that bend how light falls, +y towards the image's top (glTF's way).
    normal_texture: AssetRef(.image) = .{},
    /// Roughness in green and metallic in blue, multiplying `roughness` and `metallic`.
    metallic_roughness_texture: AssetRef(.image) = .{},
    /// Multiplies `emissive_color`, so set that too (white shows the map as it is).
    emissive_texture: AssetRef(.image) = .{},
    /// How much ambient and sky light reaches each point, in red.
    occlusion_texture: AssetRef(.image) = .{},
    metallic: f32 = 0,
    roughness: f32 = 1,
    emissive_color: [3]f32 = @splat(0),
    unlit: bool = false,
    /// `.cutout` leaves out pixels below `alpha_cutoff`; `.blend` mixes the surface over what is
    /// behind it (glass, smoke, water), drawn after everything opaque, farthest first.
    alpha_mode: AlphaMode = .cutout,
    alpha_cutoff: f32 = 0.01,
    /// Drawn from behind too; otherwise only the side its normals face shows.
    double_sided: bool = false,
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

    /// Its maps, in `assets.model.Maps`' order.
    pub fn maps(self: *const Material) [4]*const AssetRef(.image) {
        return .{ &self.normal_texture, &self.metallic_roughness_texture, &self.emissive_texture, &self.occlusion_texture };
    }
};
