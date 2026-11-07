//! Animation clips cached by their asset key (`AssetRef(.animation).key()`, the hex identity),
//! for the animation step and the renderer. A key is either an authored clip (`.clip.zon`: entity
//! and model-node keyframes) or one a model import produced (`EGGYCLIP` binary: channels on the
//! model's own nodes, blend shapes and vertices); `get` tells them apart by the binary's signature.
//! The editor swaps in a clip it is editing with `replace`, so playback shows unsaved keys.
const std = @import("std");
const assets = @import("eggy_assets");
const Resources = @import("resources/resources.zig").Resources;
const refs = @import("refs.zig");

/// A clip as loaded.
pub const Loaded = union(enum) {
    authored: assets.clip.Clip,
    imported: Imported,

    /// How long the clip runs, in seconds.
    pub fn duration_s(self: Loaded) f32 {
        return switch (self) {
            .authored => |clip| clip.duration_s,
            .imported => |imported| imported.file.clip.duration_s,
        };
    }
};

/// An imported clip, and how it fits each model it has been played on.
pub const Imported = struct {
    file: assets.imported_clip.File,
    fits: std.ArrayList(Fit) = .empty,

    fn deinit(self: *Imported, gpa: std.mem.Allocator) void {
        for (self.fits.items) |fit| switch (fit.clip) {
            .retargeted => |clip| gpa.free(clip.tracks),
            .none, .own => {},
        };
        self.fits.deinit(gpa);
        self.file.deinit(gpa);
    }
};

/// How an imported clip plays on one model: as made, for its source model; retargeted by bone
/// name, for another; or not at all. Kept by model id and node count, so a reloaded model with
/// other nodes is fitted again.
pub const Fit = struct {
    model_id: assets.Id,
    node_count: usize,
    clip: union(enum) { none, own, retargeted: assets.model.Clip },
};

pub const ClipCache = struct {
    gpa: std.mem.Allocator,
    resources: Resources = .{},
    entries: std.StringHashMapUnmanaged(?*Loaded) = .empty,

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

    /// The clip with this `key`, read on first use. A clip that can't be read or is invalid is
    /// logged once and null until the cache is forgotten. The pointer lives until `replace`,
    /// `forget` or `forgetAll`.
    pub fn get(self: *ClipCache, key: []const u8) ?*const Loaded {
        return self.find(key);
    }

    /// The authored clip with this `key`; null for an imported one or one that doesn't load.
    pub fn authored(self: *ClipCache, key: []const u8) ?*const assets.clip.Clip {
        const loaded = self.find(key) orelse return null;
        return switch (loaded.*) {
            .authored => |*clip| clip,
            .imported => null,
        };
    }

    /// The imported clip with this `key` as it plays on the model `model_id` (the id of the
    /// mesh's model), whose nodes, parts and blend shapes are `model`'s. A clip made from
    /// another model plays on the bones of the same names (a Mixamo animation on its
    /// character); one that fits nothing is logged once. Remembered until the clip is
    /// forgotten or the model's nodes change.
    pub fn importedFor(self: *ClipCache, key: []const u8, model_id: assets.Id, model: assets.Model) ?*const assets.model.Clip {
        const loaded = self.find(key) orelse return null;
        const imported = switch (loaded.*) {
            .imported => |*found| found,
            .authored => return null,
        };
        const fit = for (imported.fits.items) |*known| {
            if (known.model_id == model_id and known.node_count == model.rig.nodes.len) break known;
        } else added: {
            const made = fitTo(self.gpa, imported.file, key, model_id, model);
            imported.fits.append(self.gpa, made) catch |err| {
                if (made.clip == .retargeted) self.gpa.free(made.clip.retargeted.tracks);
                std.log.err("cannot keep how animation {s} fits its model: {t}", .{ key, err });
                return null;
            };
            break :added &imported.fits.items[imported.fits.items.len - 1];
        };
        return switch (fit.clip) {
            .none => null,
            .own => &imported.file.clip,
            .retargeted => |*clip| clip,
        };
    }

    /// Use the authored `clip` (a copy is made) for `key` from now on, whatever the project
    /// holds. Call it between frames: pointers from `get` are invalidated.
    pub fn replace(self: *ClipCache, key: []const u8, clip: assets.clip.Clip) !void {
        try clip.validate();
        const owned = try self.gpa.create(Loaded);
        errdefer self.gpa.destroy(owned);
        owned.* = .{ .authored = try clip.clone(self.gpa) };
        errdefer self.free(owned);
        try self.store(key, owned);
    }

    /// Forget `key` alone, so the project's file is read again.
    pub fn forget(self: *ClipCache, key: []const u8) void {
        if (self.entries.fetchRemove(key)) |removed| {
            self.free(removed.value);
            self.gpa.free(removed.key);
        }
    }

    fn find(self: *ClipCache, key: []const u8) ?*Loaded {
        if (self.entries.get(key)) |known| return known;
        const clip = self.load(key) catch |err| blk: {
            std.log.err("cannot load animation {s}: {t}", .{ key, err });
            break :blk null;
        };
        self.store(key, clip) catch |err| {
            self.free(clip);
            std.log.err("cannot cache animation {s}: {t}", .{ key, err });
            return null;
        };
        return clip;
    }

    fn store(self: *ClipCache, key: []const u8, clip: ?*Loaded) !void {
        if (self.entries.getPtr(key)) |existing| {
            self.free(existing.*);
            existing.* = clip;
            return;
        }
        const owned_key = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned_key);
        try self.entries.put(self.gpa, owned_key, clip);
    }

    fn free(self: *ClipCache, clip: ?*Loaded) void {
        const owned = clip orelse return;
        switch (owned.*) {
            .authored => |authored_clip| authored_clip.deinit(self.gpa),
            .imported => |*imported| imported.deinit(self.gpa),
        }
        self.gpa.destroy(owned);
    }

    fn load(self: *ClipCache, key: []const u8) !*Loaded {
        const source = try self.resources.read(self.gpa, try refs.AssetRef(.animation).parse(key));
        defer self.gpa.free(source);
        const loaded = try self.gpa.create(Loaded);
        errdefer self.gpa.destroy(loaded);
        // The binary's signature sits near the start, behind the serializer's own header.
        if (std.mem.indexOf(u8, source[0..@min(source.len, 32)], &assets.imported_clip.magic) != null) {
            var reader: std.Io.Reader = .fixed(source);
            loaded.* = .{ .imported = .{ .file = try assets.imported_clip.read(self.gpa, &reader) } };
        } else loaded.* = .{ .authored = try assets.clip.parse(self.gpa, source) };
        return loaded;
    }
};

/// How `file` (the clip `key`) fits the model `model_id` with `model`'s nodes, logging why not.
fn fitTo(gpa: std.mem.Allocator, file: assets.imported_clip.File, key: []const u8, model_id: assets.Id, model: assets.Model) Fit {
    var fit = Fit{ .model_id = model_id, .node_count = model.rig.nodes.len, .clip = .none };
    if (file.source_model == model_id) {
        file.validateFor(model_id, model) catch |err| {
            std.log.warn("animation {s} doesn't fit its model: {t}", .{ key, err });
            return fit;
        };
        fit.clip = .own;
        return fit;
    }
    const clip = file.retarget(gpa, model) catch |err| {
        std.log.err("cannot fit animation {s} to model {x}: {t}", .{ key, model_id, err });
        return fit;
    };
    if (clip.tracks.len == 0 or !model.clipIsWhole(clip)) {
        gpa.free(clip.tracks);
        std.log.warn("animation {s} moves no bone that model {x} has", .{ key, model_id });
        return fit;
    }
    fit.clip = .{ .retargeted = clip };
    return fit;
}

const test_clip_key = refs.AssetRef(.animation).init("walk.clip.zon").key();

test "a replaced clip is what get returns until it is forgotten" {
    const gpa = std.testing.allocator;
    var cache = ClipCache{ .gpa = gpa };
    defer cache.deinit();
    const tracks = [_]assets.clip.Track{.{ .target = "", .property = .position, .keys = &.{.{ .time_s = 1, .value = .{ 1, 2, 3 } }} }};
    try cache.replace(test_clip_key, .{ .duration_s = 1, .tracks = &tracks });
    try std.testing.expectEqual(@as(f32, 1), cache.get(test_clip_key).?.duration_s());
    try cache.replace(test_clip_key, .{ .duration_s = 4, .tracks = &tracks });
    try std.testing.expectEqual(@as(f32, 4), cache.authored(test_clip_key).?.duration_s);
    cache.forget(test_clip_key);
    try std.testing.expectEqual(@as(usize, 0), cache.entries.count());
}

const Source = struct {
    bytes: []const u8,

    fn read(context: *anyopaque, gpa: std.mem.Allocator, key: []const u8) ![:0]u8 {
        _ = key;
        const self: *Source = @ptrCast(@alignCast(context));
        return gpa.dupeSentinel(u8, self.bytes, 0);
    }
    fn model(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !assets.Model {
        return error.Unsupported;
    }
    fn image(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !assets.Texture {
        return error.Unsupported;
    }
};

test "an imported clip loads from its binary, and plays on models with its bones" {
    const gpa = std.testing.allocator;
    var times = [_]f32{ 0, 1 };
    var values = [_]f32{ 0, 0, 0, 1, 2, 3 };
    var tracks = [_]assets.model.Track{.{ .channel = .translation, .target = 0, .stride = 3, .times = &times, .values = &values }};
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try assets.imported_clip.write(&bytes.writer, .{ .source_model = 42, .node_names = &.{"root"}, .clip = .{ .name = "walk", .duration_s = 1, .tracks = &tracks } });

    var source = Source{ .bytes = bytes.written() };
    var cache = ClipCache{ .gpa = gpa, .resources = Resources.from(&source, Source.read, Source.model, Source.image) };
    defer cache.deinit();
    const nodes = [_]assets.model.Node{.{ .name = "root", .parent = null }};
    const skeleton = assets.Model{ .vertices = &.{}, .indices = &.{}, .parts = &.{}, .textures = &.{}, .rig = .{ .nodes = @constCast(&nodes) } };

    try std.testing.expectEqual(@as(f32, 1), cache.get(test_clip_key).?.duration_s());
    try std.testing.expect(cache.authored(test_clip_key) == null);
    try std.testing.expectEqualStrings("walk", cache.importedFor(test_clip_key, 42, skeleton).?.name);

    // Another model plays it on its bone of the same name, and not at all without one.
    const other_nodes = [_]assets.model.Node{ .{ .name = "armature", .parent = null }, .{ .name = "root", .parent = 0 } };
    const other = assets.Model{ .vertices = &.{}, .indices = &.{}, .parts = &.{}, .textures = &.{}, .rig = .{ .nodes = @constCast(&other_nodes) } };
    try std.testing.expectEqual(@as(u32, 1), cache.importedFor(test_clip_key, 43, other).?.tracks[0].target);
    const stranger_nodes = [_]assets.model.Node{.{ .name = "tail", .parent = null }};
    const stranger = assets.Model{ .vertices = &.{}, .indices = &.{}, .parts = &.{}, .textures = &.{}, .rig = .{ .nodes = @constCast(&stranger_nodes) } };
    try std.testing.expect(cache.importedFor(test_clip_key, 44, stranger) == null);
}
