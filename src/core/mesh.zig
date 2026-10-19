//! `Mesh`: the shape an entity is drawn as (built in, or a model file of the project), its
//! colour, and the image painted on it (a model's own textures, without one). A built-in component, drawn by `mesh_renderer.zig` wherever the entity's `Transform`
//! puts it. `gather` lists what to draw; it
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

/// The shapes there are, each about a metre across, centred on the entity.
pub const Shape = enum(u32) { cube, sphere, plane, cylinder, cone };

/// What a `Mesh` is: one of the built-in shapes, or a model file of the project.
pub const Source = union(enum) {
    cube,
    sphere,
    plane,
    cylinder,
    cone,
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
    /// The model file it is drawn as (its path in the project), when not a built-in shape. It
    /// points into the world's `Mesh`, so it lasts only until the world next changes.
    model_file_len: u32 = 0,
    model_file: ?[*]const u8 = null,
    /// The image it is painted with (its path in the project), if any; it points into the
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
    /// paths above. `MeshRenderer.prepare` poses the model from it.
    animator: ?*const Animator = null,
    /// Set by `MeshRenderer.prepare`: whether this entity's corners are posed (so it is drawn
    /// from its own vertex buffer, on its own), and the box round them in model space.
    deformed: u32 = 0,
    bounds_min: [3]f32 = @splat(0),
    bounds_max: [3]f32 = @splat(0),

    /// Reconstruct the source entity ID by value, without checking that it is still alive.
    /// Resolve it only against the world from which this drawable was gathered.
    ///
    /// ```zig
    /// const id = drawable.entity();
    /// ```
    pub fn entity(self: Drawable) ecs.EntityId {
        return .init(self.entity_id, self.entity_generation);
    }

    /// The model file's path, or null for a built-in shape.
    /// Borrows the originating Mesh's inline buffer; world storage changes invalidate it.
    ///
    /// ```zig
    /// const model_path = drawable.modelFile() orelse return;
    /// ```
    pub fn modelFile(self: Drawable) ?[]const u8 {
        const file = self.model_file orelse return null;
        return file[0..self.model_file_len];
    }

    /// The image's path, or null without one.
    /// Borrows the originating Mesh's inline buffer; world storage changes invalidate it.
    ///
    /// ```zig
    /// const texture_path = drawable.textureFile() orelse return;
    /// ```
    pub fn textureFile(self: Drawable) ?[]const u8 {
        const file = self.texture_file orelse return null;
        return file[0..self.texture_file_len];
    }

    pub fn materialFile(self: Drawable) ?[]const u8 {
        const file = self.material_file orelse return null;
        return file[0..self.material_file_len];
    }

    /// Copy inline GPU factors, borrowing only the material's optional texture path.
    pub fn applyMaterial(self: *Drawable, material: *const Material) void {
        self.surface_color = material.color;
        self.material_params = .{ material.metallic, material.roughness, if (material.unlit) 1 else 0, 1 };
        self.emissive_cutoff = .{ material.emissive_color[0], material.emissive_color[1], material.emissive_color[2], material.alpha_cutoff };
        if (material.texture.len != 0) {
            self.texture_file = &material.texture.buffer;
            self.texture_file_len = material.texture.len;
        }
    }
};

/// Every entity of `world` with a `Mesh` and a `Transform`, placed through its parents'
/// transforms, into `out`. Returns how many were written; any past `out.len` are left out.
/// Skips model sources with unset paths. The caller owns `out`, but file paths inside
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
    return count;
}

/// Gather every drawable without truncation; free the result with `gpa.free`.
/// File paths still borrow the world's Mesh components, as in `gather`.
/// Skips unset model sources and propagates allocation failure; freeing the returned
/// slice does not free any component-owned paths.
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
    return result.toOwnedSlice(gpa);
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
                .cylinder => try builder.lathe(.{ 0.5, 0.5 }),
                .cone => try builder.lathe(.{ 0.5, 0 }),
            }
            ranges[@intFromEnum(shape)] = .{ .first_index = first, .index_count = @as(u32, @intCast(builder.indices.items.len)) - first };
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
        for (0..rings) |ring| for (0..segments) |side| {
            const a: u32 = first + @as(u32, @intCast(ring * (segments + 1) + side));
            const b = a + segments + 1;
            try self.triangle(a, b, a + 1);
            try self.triangle(a + 1, b, b + 1);
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
            for (0..segments) |side| try self.triangle(centre, centre + 1 + @as(u32, @intCast(side)), centre + 2 + @as(u32, @intCast(side)));
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

test "allocated gathering includes every drawable and preserves borrowed model paths" {
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
            try std.testing.expectEqualStrings("ship.glb", drawn_model.modelFile().?);
            try std.testing.expectEqualStrings("ship.png", drawn_model.textureFile().?);
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
    const parent = try world.spawn(.{Transform{ .position = .{ 5, 0, 0 } }});
    const child = try world.spawn(.{ Transform{ .position = .{ 0, 2, 0 } }, Mesh{ .shape = .sphere } });
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
    try std.testing.expectEqualStrings("ships/fighter.glb", model.modelFile().?);
    try std.testing.expectEqual(Shape.cone, cone.shape);
    try std.testing.expect(cone.modelFile() == null);
    try std.testing.expectEqualStrings("art/wood.png", cone.textureFile().?);
    try std.testing.expect(model.textureFile() == null);
}
