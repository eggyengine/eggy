//! Data a game makes in code, kept by name, with the names set or removed since they were last
//! taken: what `GeneratedMeshes` and `Heightfields` keep their meshes and grids in.
const std = @import("std");
const assets = @import("eggy_assets");
const Name = @import("name.zig").Name;

/// `Value`s by name. `Value` is a struct with a `version: u32` field, which `put` numbers anew
/// each time so a cache can tell an old upload from the current one.
pub fn ByName(comptime Value: type) type {
    return struct {
        const Self = @This();

        /// By name, which the map owns.
        entries: std.StringHashMapUnmanaged(Value) = .empty,
        /// Names set or removed since `takeChanged`, for what was built from them to be rebuilt.
        changed: std.ArrayList(Name) = .empty,
        next_version: u32 = 1,

        pub const Error = error{InvalidName} || std.mem.Allocator.Error;

        /// Free the names; the values are the caller's to free first (`iterator`).
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            var it = self.entries.keyIterator();
            while (it.next()) |key| gpa.free(key.*);
            self.entries.deinit(gpa);
            self.changed.deinit(gpa);
        }

        /// Whether `name` can be used: 1 to `Name.max_len` bytes and not an asset key (16 hex
        /// digits), which a model file is drawn by.
        pub fn check(name: []const u8) error{InvalidName}!void {
            if (name.len == 0 or name.len > Name.max_len) return error.InvalidName;
            if (assets.id.parse(name)) |_| return error.InvalidName else |_| {}
        }

        /// Make `value` the one named `name`, numbered with a new version; returns the value it
        /// replaces, now the caller's. On an error nothing changes.
        pub fn put(self: *Self, gpa: std.mem.Allocator, name: []const u8, value: Value) Error!?Value {
            try check(name);
            try self.changed.ensureUnusedCapacity(gpa, 1);
            const found = try self.entries.getOrPut(gpa, name);
            const old: ?Value = if (found.found_existing) found.value_ptr.* else null;
            if (!found.found_existing) found.key_ptr.* = gpa.dupe(u8, name) catch |err| {
                self.entries.removeByPtr(found.key_ptr);
                return err;
            };
            found.value_ptr.* = value;
            found.value_ptr.version = self.next_version;
            self.next_version +%= 1;
            self.changed.appendAssumeCapacity(.init(name));
            return old;
        }

        /// Forget `name`; returns its value, now the caller's.
        pub fn remove(self: *Self, gpa: std.mem.Allocator, name: []const u8) ?Value {
            const removed = self.entries.fetchRemove(name) orelse return null;
            gpa.free(removed.key);
            self.changed.append(gpa, .init(name)) catch {};
            return removed.value;
        }

        /// The value named `name`, borrowed until it is next set or removed.
        pub fn get(self: *const Self, name: []const u8) ?*const Value {
            return self.entries.getPtr(name);
        }

        /// The names set or removed since the last call, borrowed until the next `put` or
        /// `remove`; the list is emptied for the next call.
        pub fn takeChanged(self: *Self) []const Name {
            const names = self.changed.items;
            self.changed.items.len = 0;
            return names;
        }
    };
}
