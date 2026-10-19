//! Authored animation clips (`.clip.zon`) cached by project-relative path, for the animation step
//! and the renderer. The editor swaps in a clip it is editing with `replace`, so playback shows
//! unsaved keys.
const std = @import("std");
const assets = @import("eggy_assets");
const Resources = @import("resources/resources.zig").Resources;
const refs = @import("refs.zig");

pub const ClipCache = struct {
    gpa: std.mem.Allocator,
    resources: Resources = .{},
    entries: std.StringHashMapUnmanaged(?*assets.clip.Clip) = .empty,

    pub fn deinit(self: *ClipCache) void {
        self.forgetAll();
        self.entries.deinit(self.gpa);
    }

    /// Drop every clip; each is read again, from the project, when next asked for.
    /// Invalidates every pointer `get` gave out.
    pub fn forgetAll(self: *ClipCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.free(entry.value_ptr.*);
            self.gpa.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    /// The clip at `path`, read on first use. A file that can't be read or is invalid is logged
    /// once and null until the cache is forgotten. The pointer lives until `replace`, `forget`
    /// or `forgetAll`.
    pub fn get(self: *ClipCache, path: []const u8) ?*const assets.clip.Clip {
        if (self.entries.get(path)) |known| return known;
        const clip = self.load(path) catch |err| blk: {
            std.log.err("cannot load animation {s}: {t}", .{ path, err });
            break :blk null;
        };
        self.store(path, clip) catch |err| {
            self.free(clip);
            std.log.err("cannot cache animation {s}: {t}", .{ path, err });
            return null;
        };
        return clip;
    }

    /// Use `clip` (a copy is made) for `path` from now on, whatever the project holds. Call it
    /// between frames: pointers from `get` are invalidated.
    pub fn replace(self: *ClipCache, path: []const u8, clip: assets.clip.Clip) !void {
        try clip.validate();
        const owned = try self.gpa.create(assets.clip.Clip);
        errdefer self.gpa.destroy(owned);
        owned.* = try clip.clone(self.gpa);
        errdefer owned.deinit(self.gpa);
        try self.store(path, owned);
    }

    /// Forget `path` alone, so the project's file is read again.
    pub fn forget(self: *ClipCache, path: []const u8) void {
        if (self.entries.fetchRemove(path)) |removed| {
            self.free(removed.value);
            self.gpa.free(removed.key);
        }
    }

    fn store(self: *ClipCache, path: []const u8, clip: ?*assets.clip.Clip) !void {
        if (self.entries.getPtr(path)) |existing| {
            self.free(existing.*);
            existing.* = clip;
            return;
        }
        const key = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(key);
        try self.entries.put(self.gpa, key, clip);
    }

    fn free(self: *ClipCache, clip: ?*assets.clip.Clip) void {
        const owned = clip orelse return;
        owned.deinit(self.gpa);
        self.gpa.destroy(owned);
    }

    fn load(self: *ClipCache, path: []const u8) !*assets.clip.Clip {
        const source = try self.resources.read(self.gpa, try refs.AssetRef(.animation).parse(path));
        defer self.gpa.free(source);
        const clip = try self.gpa.create(assets.clip.Clip);
        errdefer self.gpa.destroy(clip);
        clip.* = try assets.clip.parse(self.gpa, source);
        return clip;
    }
};

test "a replaced clip is what get returns until it is forgotten" {
    const gpa = std.testing.allocator;
    var cache = ClipCache{ .gpa = gpa };
    defer cache.deinit();
    const tracks = [_]assets.clip.Track{.{ .target = "", .property = .position, .keys = &.{.{ .time_s = 1, .value = .{ 1, 2, 3 } }} }};
    try cache.replace("walk.clip.zon", .{ .duration_s = 1, .tracks = &tracks });
    try std.testing.expectEqual(@as(f32, 1), cache.get("walk.clip.zon").?.duration_s);
    try cache.replace("walk.clip.zon", .{ .duration_s = 4, .tracks = &tracks });
    try std.testing.expectEqual(@as(f32, 4), cache.get("walk.clip.zon").?.duration_s);
    cache.forget("walk.clip.zon");
    try std.testing.expectEqual(@as(usize, 0), cache.entries.count());
}
