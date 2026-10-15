//! `Mesh`: the simple shape an entity is drawn as, and its colour. A built-in component, drawn by
//! `mesh_renderer.zig` wherever the entity's `Transform` puts it. `gather` lists what to draw; it
//! runs where the component types are known (the runtime, or the editor's game library).
const std = @import("std");
const ecs = @import("clutch");
const math = @import("eggenvector");
const transform_zig = @import("transform.zig");
const Transform = transform_zig.Transform;
const AssetRef = @import("refs.zig").AssetRef;

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
};

pub const Mesh = struct {
    shape: Source = .cube,
    /// Red, green and blue, 0 to 1.
    color: [3]f32 = .{ 0.8, 0.8, 0.8 },
};

/// One entity to draw: where (its model matrix's columns), in what colour, as what shape, and
/// which entity it is. Plain data, so it crosses from the editor's game library as is.
pub const Drawable = extern struct {
    model: [4][4]f32,
    color: [4]f32,
    shape: Shape,
    entity_id: u32,
    entity_generation: u32,

    pub fn entity(self: Drawable) ecs.EntityId {
        return .init(self.entity_id, self.entity_generation);
    }
};

/// Every entity of `world` with a `Mesh` and a `Transform`, placed through its parents'
/// transforms, into `out`. Returns how many were written; any past `out.len` are left out.
pub fn gather(world: *ecs.World, out: []Drawable) usize {
    var count: usize = 0;
    var meshes = world.query(.{ *const Mesh, *const Transform });
    while (meshes.next()) |view| {
        if (count == out.len) break;
        const mesh = view.get(*const Mesh);
        // ponytail: models aren't drawn yet; draw them once they can be loaded.
        const shape: Shape = switch (mesh.shape) {
            .model => continue,
            inline else => |_, tag| @field(Shape, @tagName(tag)),
        };
        const model = transform_zig.worldMatrix(world, view.entity);
        out[count] = .{ .model = undefined, .color = .{ mesh.color[0], mesh.color[1], mesh.color[2], 1 }, .shape = shape, .entity_id = view.entity.id, .entity_generation = view.entity.generation };
        for (&out[count].model, model.data) |*column, data| column.* = data;
        count += 1;
    }
    return count;
}

/// A vertex of a shape: where it is, and which way its surface faces.
pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
};

/// Every shape's vertices and triangles in one pair of lists; `ranges[shape]` says which part of
/// `indices` draws it.
pub const Geometry = struct {
    vertices: []const Vertex,
    indices: []const u32,
    ranges: [shape_count]Range,

    pub const Range = struct { first_index: u32, index_count: u32 };

    /// Build every shape in `arena`.
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

    fn vertex(self: *Builder, position: [3]f32, normal: [3]f32) !u32 {
        try self.vertices.append(self.arena, .{ .position = position, .normal = normal });
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
        const a = try self.vertex(c - r - u, normal);
        const b = try self.vertex(c + r - u, normal);
        const d = try self.vertex(c + r + u, normal);
        const e = try self.vertex(c - r + u, normal);
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
                _ = try self.vertex(.{ normal[0] * 0.5, normal[1] * 0.5, normal[2] * 0.5 }, normal);
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
            _ = try self.vertex(.{ x * bottom, -0.5, z * bottom }, normal);
            _ = try self.vertex(.{ x * top, 0.5, z * top }, normal);
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
            const centre = try self.vertex(.{ 0, end.y, 0 }, normal);
            for (0..segments + 1) |side| {
                const round = std.math.tau * @as(f32, @floatFromInt(side)) / segments;
                _ = try self.vertex(.{ @cos(round) * end.radius, end.y, @sin(round) * end.radius }, normal);
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
