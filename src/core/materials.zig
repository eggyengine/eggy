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
        metallic: f32 = 0,
        roughness: f32 = 1,
        emissive_color: [3]f32 = @splat(0),
        unlit: bool = false,
        alpha_cutoff: f32 = 0.01,
        shader: []const u8 = "",
    };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const file = try zon_file.parse(File, arena.allocator(), source, .{});
    const material = Material{
        .color = file.color,
        .texture = try refs.AssetRef(.image).parse(file.texture),
        .metallic = file.metallic,
        .roughness = file.roughness,
        .emissive_color = file.emissive_color,
        .unlit = file.unlit,
        .alpha_cutoff = file.alpha_cutoff,
        .shader = try refs.AssetRef(.shader).parse(file.shader),
    };
    try material.validate();
    return material;
}

test "material files validate parameters and own texture references" {
    const material = try parse(std.testing.allocator,
        \\.{ .color = .{ 1, 0.5, 0.2, 1 }, .metallic = 0.7,
        \\ .roughness = 0.3, .texture = "resources/metal.png", .shader = "resources/shine.slang" }
    );
    try std.testing.expectEqual(refs.AssetRef(.shader).init("resources/shine.slang").id(), material.shader.id());
    try std.testing.expectEqual(@as(f32, 0.7), material.metallic);
    try std.testing.expectEqual(refs.AssetRef(.image).init("resources/metal.png").id(), material.texture.id());
    try std.testing.expectError(error.InvalidMaterial, parse(std.testing.allocator, ".{ .roughness = -1 }"));
    try std.testing.expectError(error.InvalidPath, parse(std.testing.allocator, ".{ .texture = \"../outside.png\" }"));
}

test "material assignment changes a live entity and rejects invalid edits" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const materials = Materials{ .world = &world };
    const entity = try world.spawn(.{});
    try materials.assign(entity, .{ .roughness = 0.4 });
    try std.testing.expectEqual(@as(f32, 0.4), world.get(entity, Material).?.roughness);
    try std.testing.expectError(error.InvalidMaterial, materials.assign(entity, .{ .metallic = 2 }));
    try std.testing.expectEqual(@as(f32, 0.4), world.get(entity, Material).?.roughness);
    world.despawn(entity);
    try std.testing.expectError(error.InvalidEntity, materials.assign(entity, .{}));
}

test "authored materials and lights survive scene serialization" {
    const lighting = @import("lighting.zig");
    const Transform = @import("transform.zig").Transform;
    const scene = @import("scene.zig");
    const Registry = @import("components.zig").Registry(&.{ Material, lighting.SceneLight, Transform }, &.{ "eggy", "eggy", "eggy" });
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{ Material{ .file = .init("resources/gold.material.zon") }, lighting.SceneLight{ .kind = .point, .range_m = 4 }, Transform{} });
    var captured = try scene.Scene.capture(std.testing.allocator, &world, scene.registryAccess(Registry), null);
    defer captured.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try captured.write(&bytes.writer);
    const source = try std.testing.allocator.dupeSentinel(u8, bytes.written(), 0);
    defer std.testing.allocator.free(source);
    var parsed = try scene.Scene.parse(std.testing.allocator, source);
    defer parsed.deinit();
    var other = ecs.World.init(std.testing.allocator);
    defer other.deinit();
    const made = try parsed.instantiate(std.testing.allocator, &other, scene.registryAccess(Registry), null);
    defer std.testing.allocator.free(made.entities);
    try std.testing.expectEqual(@as(usize, 0), made.skipped);
    try std.testing.expectEqual(refs.AssetRef(.material).init("resources/gold.material.zon").id(), other.get(made.entities[0], Material).?.file.id());
    try std.testing.expectEqual(@as(f32, 4), other.get(made.entities[0], lighting.SceneLight).?.range_m);
}
