//! Meshes a game makes in code, such as terrain, kept by name: a `Mesh` whose shape is
//! `.generated` names one, and is drawn and collided with as it is now. Setting a name again
//! replaces its triangles; drawing picks the new ones up next frame, and colliders made from it
//! are rebuilt (`physics.remesh`). CPU data only, so a game library may change it in the editor.
const std = @import("std");
const assets = @import("eggy_assets");
const Name = @import("name.zig").Name;
const ByName = @import("by_name.zig").ByName;

pub const Vertex = assets.model.Vertex;

/// The world's resource pointing physics at the meshes (`App.updateWorld` inserts it).
pub const Ref = struct { meshes: *const GeneratedMeshes };

pub const GeneratedMeshes = struct {
    gpa: std.mem.Allocator,
    meshes: ByName(Entry) = .{},

    pub const Entry = struct {
        /// No parts or textures. Its `indices` are empty when its triangles are its vertices in
        /// order, three by three.
        model: assets.Model,
        /// Counts every set, so a cache can tell an old upload from the current triangles.
        version: u32 = 0,
    };

    pub const Error = error{ InvalidName, NoTriangles, IndexOutOfRange } || std.mem.Allocator.Error;

    pub fn init(gpa: std.mem.Allocator) GeneratedMeshes {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *GeneratedMeshes) void {
        var it = self.meshes.entries.valueIterator();
        while (it.next()) |entry| entry.model.deinit(self.gpa);
        self.meshes.deinit(self.gpa);
    }

    /// What `setOwned` takes vertices and indices from, and what the ones it gives back are
    /// freed with.
    pub fn allocator(self: *const GeneratedMeshes) std.mem.Allocator {
        return self.gpa;
    }

    /// Make the mesh `name` the triangles `indices` (three per triangle) list of `vertices`,
    /// both copied, replacing any it had. A name is 1 to `Name.max_len` bytes and not an asset
    /// key (16 hex digits), which a model file is drawn by.
    ///
    /// ```zig
    /// try app.meshes().set("terrain", vertices, indices);
    /// _ = try app.world.spawn(.{ eggy.Transform{}, eggy.Mesh{ .shape = .{ .generated = .init("terrain") } }, eggy.physics.Collider{ .shape = .mesh } });
    /// ```
    pub fn set(self: *GeneratedMeshes, name: []const u8, vertices: []const Vertex, indices: []const u32) Error!void {
        try ByName(Entry).check(name);
        try checkTriangles(vertices.len, indices);
        const owned_vertices = try self.gpa.dupe(Vertex, vertices);
        errdefer self.gpa.free(owned_vertices);
        const owned_indices = try self.gpa.dupe(u32, indices);
        errdefer self.gpa.free(owned_indices);
        if (try self.store(name, owned_vertices, owned_indices)) |old| self.gpa.free(old);
    }

    /// `set` without copying: the mesh takes `vertices`, and `indices` when given, which must
    /// come from `allocator()`. Null `indices` lists the triangles in order (vertices 0, 1, 2,
    /// then 3, 4, 5, and so on), drawn without an index buffer. Returns the vertices of the
    /// mesh it replaces, now the caller's to fill again or free; on an error, `vertices` and
    /// `indices` are still the caller's.
    ///
    /// ```zig
    /// const vertices = try app.meshes().allocator().alloc(eggy.generated_meshes.Vertex, count);
    /// fill(vertices); // on a worker thread, say
    /// if (try app.meshes().setOwned("chunk 3 4", vertices, null)) |spare| spares.append(spare);
    /// ```
    pub fn setOwned(self: *GeneratedMeshes, name: []const u8, vertices: []Vertex, indices: ?[]u32) Error!?[]Vertex {
        try ByName(Entry).check(name);
        if (indices) |listed| try checkTriangles(vertices.len, listed) else if (vertices.len == 0 or vertices.len % 3 != 0) return error.NoTriangles;
        return self.store(name, vertices, indices orelse &.{});
    }

    /// Keep `vertices` and `indices` as `name`; returns the vertices it replaces, freeing the rest.
    fn store(self: *GeneratedMeshes, name: []const u8, vertices: []Vertex, indices: []u32) Error!?[]Vertex {
        const model: assets.Model = .{ .vertices = vertices, .indices = indices, .parts = &.{}, .textures = &.{} };
        const old = (try self.meshes.put(self.gpa, name, .{ .model = model })) orelse return null;
        return self.keepVertices(old);
    }

    /// Forget the mesh `name`; `Mesh`es naming it draw nothing, and colliders made from it go.
    pub fn remove(self: *GeneratedMeshes, name: []const u8) void {
        if (self.removeOwned(name)) |vertices| self.gpa.free(vertices);
    }

    /// `remove`, giving its vertices back to the caller to fill again or free with `allocator()`.
    pub fn removeOwned(self: *GeneratedMeshes, name: []const u8) ?[]Vertex {
        return self.keepVertices(self.meshes.remove(self.gpa, name) orelse return null);
    }

    /// The mesh `name`, borrowed until it is next set or removed.
    pub fn get(self: *const GeneratedMeshes, name: []const u8) ?*const Entry {
        return self.meshes.get(name);
    }

    /// The names set or removed since the last call, borrowed until the next `set` or `remove`;
    /// the list is emptied for the next call.
    pub fn takeChanged(self: *GeneratedMeshes) []const Name {
        return self.meshes.takeChanged();
    }

    /// `entry`'s vertices, its other memory freed.
    fn keepVertices(self: *GeneratedMeshes, entry: Entry) []Vertex {
        var model = entry.model;
        const vertices = model.vertices;
        model.vertices = &.{};
        model.deinit(self.gpa);
        return vertices;
    }
};

fn checkTriangles(vertex_count: usize, indices: []const u32) GeneratedMeshes.Error!void {
    if (indices.len == 0 or indices.len % 3 != 0) return error.NoTriangles;
    for (indices) |index| if (index >= vertex_count) return error.IndexOutOfRange;
}

test "setOwned takes the vertices without allocating or copying them, and gives them back" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var meshes = GeneratedMeshes.init(counting.allocator());
    defer meshes.deinit();
    const gpa = meshes.allocator();

    // A full chunk's worth: 6,912 vertices, listed in order.
    const first = try gpa.alloc(Vertex, 6912);
    @memset(first, .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 } });
    try std.testing.expect(try meshes.setOwned("chunk", first, null) == null);
    _ = meshes.takeChanged();

    const second = try gpa.alloc(Vertex, 6912);
    @memset(second, .{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 1, 0 } });
    const allocations = counting.allocations;
    const allocated_bytes = counting.allocated_bytes;
    const spare = (try meshes.setOwned("chunk", second, null)).?;
    try std.testing.expectEqual(allocations, counting.allocations);
    try std.testing.expectEqual(allocated_bytes, counting.allocated_bytes);
    try std.testing.expectEqual(second.ptr, meshes.get("chunk").?.model.vertices.ptr);
    try std.testing.expectEqual(first.ptr, spare.ptr);
    gpa.free(spare);
    try std.testing.expectEqual(second.ptr, meshes.removeOwned("chunk").?.ptr);
    gpa.free(second);
}
