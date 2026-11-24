//! Authored surface materials, stored as components or reusable `.material.zon` assets.
const std = @import("std");
const zon_file = @import("eggy_assets").zon;
const ecs = @import("clutch");
const refs = @import("refs.zig");
const api = @import("support.zig");
pub const Material = @import("material.zig").Material;
pub const support: api.Support = .available;

/// Borrowed access to this world's material components; obtain it from `app.materials()`.
pub const Materials = struct {
    world: *ecs.World,

    /// Assign validated surface properties. A file, when set, supplies the whole material.
    pub fn assign(self: Materials, entity: ecs.EntityId, material: Material) !void {
        if (!self.world.isAlive(entity)) return error.InvalidEntity;
        try material.validate();
        try self.world.addComponent(entity, material);
        self.world.markChanged(entity, Material);
    }
};

/// Parse a reusable material, copying its texture reference into the returned value.
pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !Material {
    const File = struct {
        color: [4]f32 = @splat(1),
        texture: []const u8 = "",
        normal_texture: []const u8 = "",
        metallic_roughness_texture: []const u8 = "",
        emissive_texture: []const u8 = "",
        occlusion_texture: []const u8 = "",
        metallic: f32 = 0,
        roughness: f32 = 1,
        emissive_color: [3]f32 = @splat(0),
        unlit: bool = false,
        alpha_mode: Material.AlphaMode = .cutout,
        alpha_cutoff: f32 = 0.01,
        double_sided: bool = false,
        shader: []const u8 = "",
    };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const file = try zon_file.parse(File, arena.allocator(), source, .{});
    const material = Material{
        .color = file.color,
        .texture = try refs.AssetRef(.image).parse(file.texture),
        .normal_texture = try refs.AssetRef(.image).parse(file.normal_texture),
        .metallic_roughness_texture = try refs.AssetRef(.image).parse(file.metallic_roughness_texture),
        .emissive_texture = try refs.AssetRef(.image).parse(file.emissive_texture),
        .occlusion_texture = try refs.AssetRef(.image).parse(file.occlusion_texture),
        .metallic = file.metallic,
        .roughness = file.roughness,
        .emissive_color = file.emissive_color,
        .unlit = file.unlit,
        .alpha_mode = file.alpha_mode,
        .alpha_cutoff = file.alpha_cutoff,
        .double_sided = file.double_sided,
        .shader = try refs.AssetRef(.shader).parse(file.shader),
    };
    try material.validate();
    return material;
}
