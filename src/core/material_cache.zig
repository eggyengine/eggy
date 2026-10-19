//! Reusable material assets cached by project-relative path for the renderer.
const std = @import("std");
const Material = @import("material.zig").Material;
const materials = @import("materials.zig");
const Resources = @import("resources/resources.zig").Resources;
const refs = @import("refs.zig");

pub const MaterialCache = struct {
    gpa: std.mem.Allocator,
    resources: Resources = .{},
    entries: std.StringHashMapUnmanaged(?*Material) = .empty,

    pub fn deinit(self: *MaterialCache) void {
        self.forgetAll();
        self.entries.deinit(self.gpa);
    }

    pub fn forgetAll(self: *MaterialCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |material| self.gpa.destroy(material);
            self.gpa.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Failed assets are logged once and not drawn until cache invalidation.
    pub fn get(self: *MaterialCache, path: []const u8) ?*const Material {
        if (self.entries.get(path)) |known| return known;
        const material = self.load(path) catch |err| blk: {
            std.log.err("cannot load material {s}: {t}", .{ path, err });
            break :blk null;
        };
        const key = self.gpa.dupe(u8, path) catch |err| {
            if (material) |value| self.gpa.destroy(value);
            std.log.err("cannot cache material {s}: {t}", .{ path, err });
            return null;
        };
        self.entries.put(self.gpa, key, material) catch |err| {
            self.gpa.free(key);
            if (material) |value| self.gpa.destroy(value);
            std.log.err("cannot cache material {s}: {t}", .{ path, err });
            return null;
        };
        return material;
    }

    fn load(self: *MaterialCache, path: []const u8) !*Material {
        const source = try self.resources.read(self.gpa, try refs.AssetRef(.material).parse(path));
        defer self.gpa.free(source);
        const value = try materials.parse(self.gpa, source);
        const material = try self.gpa.create(Material);
        material.* = value;
        return material;
    }
};
