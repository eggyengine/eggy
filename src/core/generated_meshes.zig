//! Meshes a game makes in code, such as terrain, kept by name: a `Mesh` whose shape is
//! `.generated` names one, and is drawn and collided with as it is now. Setting a name again
//! replaces its triangles; drawing picks the new ones up next frame, and colliders made from it
//! are rebuilt (`physics.remesh`). CPU data only, so a game library may change it in the editor.
const std = @import("std");
const assets = @import("eggy_assets");
const Name = @import("name.zig").Name;

pub const Vertex = assets.model.Vertex;

/// The world's resource pointing physics at the meshes (`App.updateWorld` inserts it).
pub const Ref = struct { meshes: *const GeneratedMeshes };

pub const GeneratedMeshes = struct {
    gpa: std.mem.Allocator,
    /// By name, which the map owns.
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Names set or removed since `takeChanged`, for colliders to be rebuilt from.
    changed: std.ArrayList(Name) = .empty,
    /// Counts every `set`, so a cache can tell an old upload from the current triangles.
    next_version: u32 = 1,

    pub const Entry = struct {
        /// One part, no textures.
        model: assets.Model,
        version: u32,
    };

    pub const Error = error{ InvalidName, NoTriangles, IndexOutOfRange } || std.mem.Allocator.Error;

    pub fn init(gpa: std.mem.Allocator) GeneratedMeshes {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *GeneratedMeshes) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.model.deinit(self.gpa);
            self.gpa.free(entry.key_ptr.*);
        }
        self.entries.deinit(self.gpa);
        self.changed.deinit(self.gpa);
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
        if (name.len == 0 or name.len > Name.max_len) return error.InvalidName;
        if (assets.id.parse(name)) |_| return error.InvalidName else |_| {}
        if (indices.len == 0 or indices.len % 3 != 0) return error.NoTriangles;
        for (indices) |index| if (index >= vertices.len) return error.IndexOutOfRange;

        const owned_vertices = try self.gpa.dupe(Vertex, vertices);
        errdefer self.gpa.free(owned_vertices);
        const owned_indices = try self.gpa.dupe(u32, indices);
        errdefer self.gpa.free(owned_indices);
        const parts = try self.gpa.alloc(assets.model.Part, 1);
        errdefer self.gpa.free(parts);
        parts[0] = .{ .first_index = 0, .index_count = @intCast(indices.len) };
        try self.changed.ensureUnusedCapacity(self.gpa, 1);
        const found = try self.entries.getOrPut(self.gpa, name);
        if (found.found_existing) {
            found.value_ptr.model.deinit(self.gpa);
        } else {
            found.key_ptr.* = self.gpa.dupe(u8, name) catch |err| {
                self.entries.removeByPtr(found.key_ptr);
                return err;
            };
        }
        found.value_ptr.* = .{
            .model = .{ .vertices = owned_vertices, .indices = owned_indices, .parts = parts, .textures = &.{} },
            .version = self.next_version,
        };
        self.next_version +%= 1;
        self.changed.appendAssumeCapacity(.init(name));
    }

    /// Forget the mesh `name`; `Mesh`es naming it draw nothing, and colliders made from it go.
    pub fn remove(self: *GeneratedMeshes, name: []const u8) void {
        const removed = self.entries.fetchRemove(name) orelse return;
        var model = removed.value.model;
        model.deinit(self.gpa);
        self.gpa.free(removed.key);
        self.changed.append(self.gpa, .init(name)) catch {};
    }

    /// The mesh `name`, borrowed until it is next set or removed.
    pub fn get(self: *const GeneratedMeshes, name: []const u8) ?*const Entry {
        return self.entries.getPtr(name);
    }

    /// The names set or removed since the last call, borrowed until the next `set` or `remove`;
    /// the list is emptied for the next call.
    pub fn takeChanged(self: *GeneratedMeshes) []const Name {
        const names = self.changed.items;
        self.changed.items.len = 0;
        return names;
    }
};
