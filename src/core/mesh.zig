//! `Mesh`: the shape an entity is drawn as (built in, or a model file of the project), its
//! colour, and the image painted on it (a model's own textures, without one). A built-in component, drawn by `mesh_renderer.zig` wherever the entity's `Transform`
//! puts it. `gather` lists what to draw, `Sprite`s among it as quads; it
//! runs where the component types are known (the runtime, or the editor's game library).
const std = @import("std");
const ecs = @import("clutch");
const math = @import("eggenvector");
const transform_zig = @import("transform.zig");
const Transform = transform_zig.Transform;
const AssetRef = @import("refs.zig").AssetRef;
const assets = @import("eggy_assets");
const Material = @import("material.zig").Material;
const Animator = @import("animation.zig").Animator;
const Sprite = @import("sprite.zig").Sprite;
const SpriteAnimator = @import("sprite_animator.zig").SpriteAnimator;
const Tilemap = @import("tilemap.zig").Tilemap;

/// The shapes there are, each about a metre across, centred on the entity. A `plane` faces up
/// (+y); a `quad` faces the front (+z), as sprites do.
pub const Shape = enum(u32) { cube, sphere, plane, cylinder, cone, quad };

/// What a `Mesh` is: one of the built-in shapes, or a model file of the project.
pub const Source = union(enum) {
    cube,
    sphere,
    plane,
    cylinder,
    cone,
    quad,
    model: AssetRef(.model),

    /// The built-in `shape`, as a `Mesh`'s shape.
    /// Returns a source tag without loading or allocating geometry.
    ///
    /// ```zig
    /// const source = Source.of(.sphere);
    /// ```
    pub fn of(shape: Shape) Source {
        return switch (shape) {
            inline else => |tag| @unionInit(Source, @tagName(tag), {}),
        };
    }
};

pub const Mesh = struct {
    /// Marks it in the editor (nf-md-cube_outline).
    pub const icon = "\u{f01a7}";
    pub const category = "Rendering";
    /// Drawn where its `Transform` puts it.
    pub const dependencies = .{Transform};

    shape: Source = .cube,
    /// Red, green and blue, 0 to 1; the texture is tinted by it.
    color: [3]f32 = .{ 0.8, 0.8, 0.8 },
    /// An image painted over the shape; none keeps a model's own textures, or plain colour.
    texture: AssetRef(.image) = .{},
};

/// One entity to draw: where (its model matrix's columns), in what colour, as what shape or
/// model file, and which entity it is. Plain data, so it crosses from the editor's game library
/// as is.
pub const Drawable = extern struct {
    model: [4][4]f32,
    color: [4]f32,
    /// A built-in shape's; `.cube` for a model file, as far as picking goes.
    shape: Shape,
    entity_id: u32,
    entity_generation: u32,
    /// The model's canonical identity key, when not a built-in shape. It
    /// points into the world's `Mesh`, so it lasts only until the world next changes.
    model_file_len: u32 = 0,
    model_file: ?[*]const u8 = null,
    /// The image's canonical identity key, if any; it points into the
    /// world's `Mesh` as `model_file` does.
    texture_file_len: u32 = 0,
    texture_file: ?[*]const u8 = null,
    surface_color: [4]f32 = @splat(1),
    /// Metallic, roughness, unlit, and whether this overrides imported material factors.
    material_params: [4]f32 = .{ 0, 1, 0, 0 },
    /// Emissive RGB and alpha-cutout threshold.
    emissive_cutoff: [4]f32 = .{ 0, 0, 0, 0.01 },
    material_file: ?[*]const u8 = null,
    material_file_len: u32 = 0,
    material_failed: bool = false,
    /// What plays on the entity's model, if it has an `Animator`; borrowed from the world like the
    /// keys above. `MeshRenderer.prepare` poses the model from it.
    animator: ?*const Animator = null,
    /// Set by `MeshRenderer.prepare`: whether this entity's corners are posed (so it is drawn
    /// from its own vertex buffer, on its own), and the box round them in model space.
    deformed: u32 = 0,
    bounds_min: [3]f32 = @splat(0),
    bounds_max: [3]f32 = @splat(0),
    /// Zero for what only the editor draws (its stand-ins for lights and cameras), which mustn't
    /// throw shadows over the scene.
    casts_shadow: u32 = 1,
    /// The part of the texture drawn across the shape: left, top, right, bottom.
    uv_rect: [4]f32 = .{ 0, 0, 1, 1 },
    /// The material's surface shader's identity key, if any; borrowed like `material_file`.
    shader_file: ?[*]const u8 = null,
    shader_file_len: u32 = 0,
    /// The authored material it is drawn with, for its maps; borrowed like `animator`. None
    /// leaves a model's parts their own maps, alpha and sides.
    material: ?*const Material = null,
    /// 1 when blended over what is behind it (`Material.AlphaMode.blend`), drawn after
    /// everything opaque, farthest first.
    alpha_blend: u32 = 0,
    /// 1 when its back faces are drawn too.
    double_sided: u32 = 0,

    /// Reconstruct the source entity ID by value, without checking that it is still alive.
    /// Resolve it only against the world from which this drawable was gathered.
    ///
    /// ```zig
    /// const id = drawable.entity();
    /// ```
    pub fn entity(self: Drawable) ecs.EntityId {
        return .init(self.entity_id, self.entity_generation);
    }

    /// The model's identity key, or null for a built-in shape.
    /// Borrows the originating Mesh's inline buffer; world storage changes invalidate it.
    ///
    /// ```zig
    /// const model_key = drawable.modelFile() orelse return;
    /// ```
    pub fn modelFile(self: Drawable) ?[]const u8 {
        const file = self.model_file orelse return null;
        return file[0..self.model_file_len];
    }

    /// The image's identity key, or null without one.
    /// Borrows the originating Mesh's inline buffer; world storage changes invalidate it.
    ///
    /// ```zig
    /// const texture_key = drawable.textureFile() orelse return;
    /// ```
    pub fn textureFile(self: Drawable) ?[]const u8 {
        const file = self.texture_file orelse return null;
        return file[0..self.texture_file_len];
    }

    pub fn materialFile(self: Drawable) ?[]const u8 {
        const file = self.material_file orelse return null;
        return file[0..self.material_file_len];
    }

    /// Copy inline GPU factors, borrowing only the material's optional texture identity.
    pub fn applyMaterial(self: *Drawable, material: *const Material) void {
        self.surface_color = material.color;
        self.material_params = .{ material.metallic, material.roughness, if (material.unlit) 1 else 0, 1 };
        self.emissive_cutoff = .{ material.emissive_color[0], material.emissive_color[1], material.emissive_color[2], material.alpha_cutoff };
        self.material = material;
        self.alpha_blend = @intFromBool(material.alpha_mode == .blend);
        self.double_sided = @intFromBool(material.double_sided);
        if (material.texture.len != 0) {
            self.texture_file = &material.texture.buffer;
            self.texture_file_len = material.texture.len;
        }
        if (material.shader.len != 0) {
            self.shader_file = &material.shader.buffer;
            self.shader_file_len = material.shader.len;
        }
    }

    /// The surface shader's identity key, or null for Eggy's own surface.
    pub fn shaderFile(self: Drawable) ?[]const u8 {
        const file = self.shader_file orelse return null;
        return file[0..self.shader_file_len];
    }
};

/// Every entity of `world` with a `Mesh` and a `Transform`, placed through its parents'
/// transforms, into `out`. Returns how many were written; any past `out.len` are left out.
/// Skips model sources with unset identities. The caller owns `out`, but identity keys inside
/// results borrow Mesh storage and must not survive world changes.
///
/// ```zig
/// var buffer: [256]Drawable = undefined;
/// const count = gather(world, &buffer);
/// const drawables = buffer[0..count];
/// ```
pub fn gather(world: *ecs.World, out: []Drawable) usize {
    var count: usize = 0;
    var meshes = world.query(.{ *const Mesh, *const Transform });
    while (meshes.next()) |view| {
        if (count == out.len) break;
        out[count] = drawable(world, view.entity, view.get(*const Mesh)) orelse continue;
        count += 1;
    }
    var sprites = world.query(.{ *const Sprite, *const Transform });
    while (sprites.next()) |view| {
        if (count == out.len) break;
        out[count] = spriteDrawable(world, view.entity, view.get(*const Sprite)) orelse continue;
        count += 1;
    }
    var tilemaps = world.query(.{ *const Tilemap, *const Transform });
    while (tilemaps.next()) |view| {
        if (count == out.len) break;
        out[count] = tilemapDrawable(world, view.entity, view.get(*const Tilemap)) orelse continue;
        count += 1;
    }
    return count;
}

/// Gather every drawable without truncation; free the result with `gpa.free`.
/// Identity keys still borrow the world's Mesh components, as in `gather`.
/// Skips unset model sources and propagates allocation failure; freeing the returned
/// slice does not free any component-owned keys.
///
/// ```zig
/// const drawables = try gatherAlloc(gpa, world);
/// defer gpa.free(drawables);
/// ```
pub fn gatherAlloc(gpa: std.mem.Allocator, world: *ecs.World) ![]Drawable {
    var result: std.ArrayList(Drawable) = .empty;
    defer result.deinit(gpa);
    var meshes = world.query(.{ *const Mesh, *const Transform });
    while (meshes.next()) |view| {
        try result.append(gpa, drawable(world, view.entity, view.get(*const Mesh)) orelse continue);
    }
    var sprites = world.query(.{ *const Sprite, *const Transform });
    while (sprites.next()) |view| {
        try result.append(gpa, spriteDrawable(world, view.entity, view.get(*const Sprite)) orelse continue);
    }
    var tilemaps = world.query(.{ *const Tilemap, *const Transform });
    while (tilemaps.next()) |view| {
        try result.append(gpa, tilemapDrawable(world, view.entity, view.get(*const Tilemap)) orelse continue);
    }
    return result.toOwnedSlice(gpa);
}

/// A tilemap as its map file's model, unlit and painted with its tileset; none without both.
fn tilemapDrawable(world: *ecs.World, entity: ecs.EntityId, tilemap: *const Tilemap) ?Drawable {
    if (tilemap.map.len == 0 or tilemap.tileset.len == 0) return null;
    var world_matrix: [4][4]f32 = undefined;
    for (&world_matrix, transform_zig.worldMatrix(world, entity).data) |*column, data| column.* = data;
    return .{
        .model = tilemap.placed(world_matrix),
        .color = tilemap.color,
        .shape = .quad,
        .entity_id = entity.id,
        .entity_generation = entity.generation,
        .model_file = &tilemap.map.buffer,
        .model_file_len = tilemap.map.len,
        .texture_file = &tilemap.tileset.buffer,
        .texture_file_len = tilemap.tileset.len,
        .material_params = .{ 0, 1, 1, 1 },
        .emissive_cutoff = .{ 0, 0, 0, tilemap.alpha_cutoff },
        .casts_shadow = 0,
        .double_sided = 1,
    };
}

/// A sprite as an unlit quad showing its part of its image (its animator's frame, if it has
/// one, so the editor shows it too); none without an image.
fn spriteDrawable(world: *ecs.World, entity: ecs.EntityId, sprite: *const Sprite) ?Drawable {
    if (sprite.image.len == 0) return null;
    var shown = sprite.*;
    if (world.get(entity, SpriteAnimator)) |animator| shown.region = animator.region(animator.frame());
    var world_matrix: [4][4]f32 = undefined;
    for (&world_matrix, transform_zig.worldMatrix(world, entity).data) |*column, data| column.* = data;
    return .{
        .model = shown.placed(world_matrix),
        .color = shown.color,
        .shape = .quad,
        .entity_id = entity.id,
        .entity_generation = entity.generation,
        .texture_file = &sprite.image.buffer,
        .texture_file_len = sprite.image.len,
        .material_params = .{ 0, 1, 1, 1 },
        .emissive_cutoff = .{ 0, 0, 0, shown.alpha_cutoff },
        .casts_shadow = 0,
        .uv_rect = shown.uvRect(),
        .alpha_blend = @intFromBool(shown.alpha_mode == .blend),
        .double_sided = 1,
    };
}

fn drawable(world: *ecs.World, entity: ecs.EntityId, mesh: *const Mesh) ?Drawable {
    var result = Drawable{ .model = undefined, .color = .{ mesh.color[0], mesh.color[1], mesh.color[2], 1 }, .shape = .cube, .entity_id = entity.id, .entity_generation = entity.generation };
    switch (mesh.shape) {
        // A model with no file yet is nothing to draw.
        .model => |*file| {
            if (file.len == 0) return null;
            result.model_file = &file.buffer;
            result.model_file_len = file.len;
            result.animator = world.get(entity, Animator);
        },
        inline else => |_, tag| result.shape = @field(Shape, @tagName(tag)),
    }
    if (mesh.texture.len > 0) {
        result.texture_file = &mesh.texture.buffer;
        result.texture_file_len = mesh.texture.len;
    }
    if (world.get(entity, Material)) |material| {
        material.validate() catch {
            std.log.err("entity {d} has invalid material parameters; it is not drawn", .{entity.id});
            result.material_failed = true;
        };
        if (material.file.len != 0) {
            result.material_file = &material.file.buffer;
            result.material_file_len = material.file.len;
        } else result.applyMaterial(material);
    }
    const model = transform_zig.worldMatrix(world, entity);
    for (&result.model, model.data) |*column, data| column.* = data;
    return result;
}

/// A vertex of a shape or model: where it is, which way its surface faces, and where on a texture.
pub const Vertex = assets.model.Vertex;

/// Every shape's vertices and triangles in one pair of lists; `ranges[shape]` says which part of
/// `indices` draws it.
pub const Geometry = struct {
    vertices: []const Vertex,
    indices: []const u32,
    ranges: [shape_count]Range,

    pub const Range = struct { first_index: u32, index_count: u32 };

    /// Build every shape in `arena`.
    /// Host geometry helper: returns borrowed arena-backed vertex/index slices and ranges
    /// indexed by `@intFromEnum(Shape)`. Release the arena after upload/use; allocation
    /// errors propagate, including partial allocations that the arena must reclaim.
    ///
    /// ```zig
    /// var arena = std.heap.ArenaAllocator.init(gpa);
    /// defer arena.deinit();
    /// const geometry = try Geometry.build(arena.allocator());
    /// ```
    pub fn build(arena: std.mem.Allocator) !Geometry {
        var builder: Builder = .{ .arena = arena };
        var ranges: [shape_count]Range = undefined;
        for (std.enums.values(Shape)) |shape| {
            const first: u32 = @intCast(builder.indices.items.len);
            switch (shape) {
                .cube => try builder.cube(),
                .sphere => try builder.sphere(),
                .plane => try builder.quad(.{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, -1 }),
                .quad => try builder.quad(.{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }),
                .cylinder => try builder.lathe(.{ 0.5, 0.5 }),
                .cone => try builder.lathe(.{ 0.5, 0 }),
            }
            ranges[@backingInt(shape)] = .{ .first_index = first, .index_count = @as(u32, @intCast(builder.indices.items.len)) - first };
        }
        return .{ .vertices = builder.vertices.items, .indices = builder.indices.items, .ranges = ranges };
    }
};

const shape_count = std.enums.values(Shape).len;
/// How many sides round shapes have.
const segments = 32;

const Builder = struct {
    arena: std.mem.Allocator,
    vertices: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,

    fn vertex(self: *Builder, position: [3]f32, normal: [3]f32, uv: [2]f32) !u32 {
        try self.vertices.append(self.arena, .{ .position = position, .normal = normal, .uv = uv });
        return @intCast(self.vertices.items.len - 1);
    }

    fn triangle(self: *Builder, a: u32, b: u32, c: u32) !void {
        try self.indices.appendSlice(self.arena, &.{ a, b, c });
    }

    /// A square a metre across, centred on `centre`, facing `normal`, spanned by `right` and `up`.
    fn quad(self: *Builder, centre: [3]f32, normal: [3]f32, right: [3]f32, up: [3]f32) !void {
        const c: @Vector(3, f32) = centre;
        const r = @as(@Vector(3, f32), right) * @as(@Vector(3, f32), @splat(0.5));
        const u = @as(@Vector(3, f32), up) * @as(@Vector(3, f32), @splat(0.5));
        // The whole texture on each face, its top along `up`.
        const a = try self.vertex(c - r - u, normal, .{ 0, 1 });
        const b = try self.vertex(c + r - u, normal, .{ 1, 1 });
        const d = try self.vertex(c + r + u, normal, .{ 1, 0 });
        const e = try self.vertex(c - r + u, normal, .{ 0, 0 });
        try self.triangle(a, b, d);
        try self.triangle(a, d, e);
    }

    fn cube(self: *Builder) !void {
        try self.quad(.{ 0.5, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 1, 0 });
        try self.quad(.{ -0.5, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 0 });
        try self.quad(.{ 0, 0.5, 0 }, .{ 0, 1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, -1 });
        try self.quad(.{ 0, -0.5, 0 }, .{ 0, -1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 });
        try self.quad(.{ 0, 0, 0.5 }, .{ 0, 0, 1 }, .{ 1, 0, 0 }, .{ 0, 1, 0 });
        try self.quad(.{ 0, 0, -0.5 }, .{ 0, 0, -1 }, .{ -1, 0, 0 }, .{ 0, 1, 0 });
    }

    /// A sphere half a metre in radius, in rings from the top down.
    fn sphere(self: *Builder) !void {
        const rings = segments / 2;
        const first: u32 = @intCast(self.vertices.items.len);
        for (0..rings + 1) |ring| {
            const down = std.math.pi * @as(f32, @floatFromInt(ring)) / rings;
            for (0..segments + 1) |side| {
                const round = std.math.tau * @as(f32, @floatFromInt(side)) / segments;
                const normal = [3]f32{ @sin(down) * @cos(round), @cos(down), @sin(down) * @sin(round) };
                // The texture wrapped round once, top to bottom.
                const uv = [2]f32{ @as(f32, @floatFromInt(side)) / segments, @as(f32, @floatFromInt(ring)) / rings };
                _ = try self.vertex(.{ normal[0] * 0.5, normal[1] * 0.5, normal[2] * 0.5 }, normal, uv);
            }
        }
        // Counter-clockwise from outside, as every shape's front faces are.
        for (0..rings) |ring| for (0..segments) |side| {
            const a: u32 = first + @as(u32, @intCast(ring * (segments + 1) + side));
            const b = a + segments + 1;
            try self.triangle(a, a + 1, b);
            try self.triangle(a + 1, b + 1, b);
        };
    }

    /// A round shape a metre tall: `radii` at the bottom and top (a cylinder, or a cone with a
    /// top of 0), with its ends closed.
    fn lathe(self: *Builder, radii: [2]f32) !void {
        const bottom, const top = radii;
        // The side: its normal leans up as the shape narrows.
        const slope = bottom - top;
        const first: u32 = @intCast(self.vertices.items.len);
        for (0..segments + 1) |side| {
            const round = std.math.tau * @as(f32, @floatFromInt(side)) / segments;
            const x = @cos(round);
            const z = @sin(round);
            const length = @sqrt(1 + slope * slope);
            const normal = [3]f32{ x / length, slope / length, z / length };
            // The side wrapped in the texture once round.
            const u = @as(f32, @floatFromInt(side)) / segments;
            _ = try self.vertex(.{ x * bottom, -0.5, z * bottom }, normal, .{ u, 1 });
            _ = try self.vertex(.{ x * top, 0.5, z * top }, normal, .{ u, 0 });
        }
        for (0..segments) |side| {
            const a = first + @as(u32, @intCast(side * 2));
            try self.triangle(a, a + 1, a + 2);
            try self.triangle(a + 2, a + 1, a + 3);
        }
        // The ends: fans round a centre.
        for ([_]struct { y: f32, radius: f32 }{ .{ .y = -0.5, .radius = bottom }, .{ .y = 0.5, .radius = top } }) |end| {
            if (end.radius == 0) continue;
            const normal = [3]f32{ 0, if (end.y > 0) 1 else -1, 0 };
            // The texture's middle on the centre, its edge round the rim.
            const centre = try self.vertex(.{ 0, end.y, 0 }, normal, .{ 0.5, 0.5 });
            for (0..segments + 1) |side| {
                const round = std.math.tau * @as(f32, @floatFromInt(side)) / segments;
                _ = try self.vertex(.{ @cos(round) * end.radius, end.y, @sin(round) * end.radius }, normal, .{ 0.5 + @cos(round) * 0.5, 0.5 + @sin(round) * 0.5 });
            }
            // Round one way seen from below, the other from above.
            for (0..segments) |side| {
                const rim = centre + 1 + @as(u32, @intCast(side));
                if (end.y > 0) try self.triangle(centre, rim + 1, rim) else try self.triangle(centre, rim, rim + 1);
            }
        }
    }
};

test "every shape has triangles, each pointing at a real vertex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const geometry = try Geometry.build(arena.allocator());
    for (geometry.ranges) |range| {
        try std.testing.expect(range.index_count > 0);
        try std.testing.expectEqual(@as(u32, 0), range.index_count % 3);
    }
    for (geometry.indices) |index| try std.testing.expect(index < geometry.vertices.len);
}

test "every shape's triangles turn counter-clockwise seen from the side their normals face" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const geometry = try Geometry.build(arena.allocator());
    var index: usize = 0;
    while (index < geometry.indices.len) : (index += 3) {
        const corners = geometry.indices[index..][0..3];
        const a: math.Vec3 = .fromArray(geometry.vertices[corners[0]].position);
        const b: math.Vec3 = .fromArray(geometry.vertices[corners[1]].position);
        const c: math.Vec3 = .fromArray(geometry.vertices[corners[2]].position);
        const facing = b.sub(a).cross(c.sub(a));
        // The sphere's poles squeeze some triangles to nothing.
        if (facing.length() < 1e-7) continue;
        var normal: math.Vec3 = .zero;
        for (corners) |corner| normal = normal.add(.fromArray(geometry.vertices[corner].normal));
        try std.testing.expect(facing.dot(normal) > 0);
    }
}

test "allocated gathering includes every drawable and preserves borrowed asset identities" {
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var world = ecs.World.init(std.testing.allocator);
            defer world.deinit();
            const empty = try gatherAlloc(gpa, &world);
            defer gpa.free(empty);
            try std.testing.expectEqual(@as(usize, 0), empty.len);
            const cube = try world.spawn(.{ Mesh{}, Transform{} });
            const model = try world.spawn(.{ Mesh{ .shape = .{ .model = .init("ship.glb") }, .texture = .init("ship.png") }, Transform{} });
            _ = try world.spawn(.{ Mesh{ .shape = .{ .model = .{} } }, Transform{} });
            const all = try gatherAlloc(gpa, &world);
            defer gpa.free(all);
            try std.testing.expectEqual(@as(usize, 2), all.len);
            const drawn_cube, const drawn_model = if (all[0].entity().eql(cube)) .{ all[0], all[1] } else .{ all[1], all[0] };
            try std.testing.expect(drawn_cube.entity().eql(cube));
            try std.testing.expect(drawn_model.entity().eql(model));
            try std.testing.expectEqualStrings(AssetRef(.model).init("ship.glb").key(), drawn_model.modelFile().?);
            try std.testing.expectEqualStrings(AssetRef(.image).init("ship.png").key(), drawn_model.textureFile().?);
            var buffer: [1]Drawable = undefined;
            try std.testing.expectEqual(@as(usize, 1), gather(&world, &buffer));
            try std.testing.expectEqualDeep(buffer[0], all[0]);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "a child's mesh is drawn where its parent's transform puts it" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const parent = try world.spawn(.{Transform{ .position = .init(5, 0, 0) }});
    const child = try world.spawn(.{ Transform{ .position = .init(0, 2, 0) }, Mesh{ .shape = .sphere } });
    try world.setParent(child, parent);

    var drawn: [4]Drawable = undefined;
    try std.testing.expectEqual(@as(usize, 1), gather(&world, &drawn));
    try std.testing.expectEqual(Shape.sphere, drawn[0].shape);
    try std.testing.expect(drawn[0].entity().eql(child));
    try std.testing.expectEqualSlices(f32, &.{ 5, 2, 0, 1 }, &drawn[0].model[3]);
}

test "a model's mesh is drawn as its file, and one with no file isn't drawn" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{ Transform{}, Mesh{ .shape = .{ .model = .init("ships/fighter.glb") } } });
    _ = try world.spawn(.{ Transform{}, Mesh{ .shape = .{ .model = .{} } } });
    _ = try world.spawn(.{ Transform{}, Mesh{ .shape = .of(.cone), .texture = .init("art/wood.png") } });

    var drawn: [4]Drawable = undefined;
    try std.testing.expectEqual(@as(usize, 2), gather(&world, &drawn));
    // In whatever order the world keeps them.
    const model, const cone = if (drawn[0].modelFile() != null) .{ drawn[0], drawn[1] } else .{ drawn[1], drawn[0] };
    try std.testing.expectEqualStrings(AssetRef(.model).init("ships/fighter.glb").key(), model.modelFile().?);
    try std.testing.expectEqual(Shape.cone, cone.shape);
    try std.testing.expect(cone.modelFile() == null);
    try std.testing.expectEqualStrings(AssetRef(.image).init("art/wood.png").key(), cone.textureFile().?);
    try std.testing.expect(model.textureFile() == null);
}
