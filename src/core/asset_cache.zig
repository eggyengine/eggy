//! Assets read from text and kept by key until forgotten: materials for the renderer, animation
//! graphs for their components. `AssetCache` makes one for any kind that parses from its file.
const std = @import("std");
const Material = @import("material.zig").Material;
const materials = @import("materials.zig");
const Resources = @import("resources/resources.zig").Resources;
const refs = @import("refs.zig");
const assets = @import("eggy_assets");

/// A cache of `kind` assets, each read through `resources` and made a `Value` by `parse` on first
/// use. `free` releases one.
pub fn AssetCache(comptime kind: assets.Kind, comptime Value: type, comptime parse: fn (std.mem.Allocator, [:0]const u8) anyerror!Value, comptime free: fn (std.mem.Allocator, Value) void) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        resources: Resources = .{},
        entries: std.StringHashMapUnmanaged(?*Value) = .empty,

        pub fn deinit(self: *Self) void {
            self.forgetAll();
            self.entries.deinit(self.gpa);
        }

        /// Drop every asset; each is read again when next asked for. Invalidates what `get` gave.
        pub fn forgetAll(self: *Self) void {
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                self.release(entry.value_ptr.*);
                self.gpa.free(entry.key_ptr.*);
            }
            self.entries.clearRetainingCapacity();
        }

        /// Drop the asset `key`, as after its file changed.
        pub fn forget(self: *Self, key: []const u8) void {
            const removed = self.entries.fetchRemove(key) orelse return;
            self.release(removed.value);
            self.gpa.free(removed.key);
        }

        /// The asset `key`, read on first use. One that fails is logged once and null until
        /// forgotten. The pointer lives until `forget` or `forgetAll`.
        pub fn get(self: *Self, key: []const u8) ?*const Value {
            if (self.entries.get(key)) |known| return known;
            const value = self.load(key) catch |err| blk: {
                std.log.err("cannot load {t} {s}: {t}", .{ kind, key, err });
                break :blk null;
            };
            const owned_key = self.gpa.dupe(u8, key) catch |err| return self.dropUncached(value, key, err);
            self.entries.put(self.gpa, owned_key, value) catch |err| {
                self.gpa.free(owned_key);
                return self.dropUncached(value, key, err);
            };
            return value;
        }

        fn dropUncached(self: *Self, value: ?*Value, key: []const u8, err: anyerror) ?*const Value {
            self.release(value);
            std.log.err("cannot cache {t} {s}: {t}", .{ kind, key, err });
            return null;
        }

        fn release(self: *Self, value: ?*Value) void {
            const owned = value orelse return;
            free(self.gpa, owned.*);
            self.gpa.destroy(owned);
        }

        fn load(self: *Self, key: []const u8) !*Value {
            const source = try self.resources.read(self.gpa, try refs.AssetRef(kind).parse(key));
            defer self.gpa.free(source);
            const value = try self.gpa.create(Value);
            errdefer self.gpa.destroy(value);
            value.* = try parse(self.gpa, source);
            return value;
        }
    };
}

fn freeMaterial(_: std.mem.Allocator, _: Material) void {}

pub const MaterialCache = AssetCache(.material, Material, materials.parse, freeMaterial);
