//! The model files a scene draws, on the GPU: each one's triangles and the textures its parts
//! are painted with, loaded through `loader` the first time a `Mesh` shows it, then kept. The
//! editor's loader imports model files with assimp; the runtime's reads what packaging made of
//! them (`.eggmodel`).
const std = @import("std");
const vit = @import("vitellus");
const assets = @import("eggy_assets");
const texture_cache = @import("texture_cache.zig");
const TextureCache = texture_cache.TextureCache;
const log = std.log.scoped(.models);

/// How a model file (by its path in the project) becomes triangles.
pub const Loader = struct {
    context: *anyopaque,
    /// Host-local loader; author code uses `Resources`' C-safe provider bridge.
    load: *const fn (context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror!assets.Model,
};

/// A model's triangles on the GPU, in parts each painted with its own texture (or not).
pub const Gpu = struct {
    vertices: vit.Buffer,
    indices: vit.Buffer,
    /// Owned by the cache.
    parts: []const Part,
    /// The box round its vertices, in its own space.
    min: [3]f32,
    max: [3]f32,

    pub const Part = struct {
        first_index: u32,
        index_count: u32,
        /// One of `textures`; null to paint it with the `Mesh`'s texture, or white.
        texture: ?texture_cache.Gpu,
    };

    fn deinit(self: Gpu, gpa: std.mem.Allocator, textures: *TextureCache) void {
        // Each texture once, though several parts may share it.
        for (self.parts, 0..) |part, i| if (part.texture) |texture| {
            const shared = for (self.parts[0..i]) |earlier| {
                if (earlier.texture) |seen| if (std.meta.eql(seen.texture, texture.texture)) break true;
            } else false;
            if (!shared) textures.release(texture);
        };
        gpa.free(self.parts);
        self.indices.deinit();
        self.vertices.deinit();
    }
};

pub const ModelCache = struct {
    gpa: std.mem.Allocator,
    device: vit.Device,
    /// Where models come from; none (every model file draws nothing) until set.
    loader: ?Loader = null,
    /// By path, which the map owns; null for a model that didn't load, so it isn't tried again.
    entries: std.StringHashMapUnmanaged(?Gpu) = .empty,

    /// Create an empty host model cache borrowing `device` and retaining `gpa`.
    /// Configure `loader` before first use; no model can load without one.
    /// Destroy with `deinit` before the texture cache and device.
    ///
    /// ```zig
    /// var models = ModelCache.init(gpa, graphics.device);
    /// defer models.deinit(&textures); // Finish GPU use before this host scope ends.
    /// models.loader = model_loader;
    /// ```
    pub fn init(gpa: std.mem.Allocator, device: vit.Device) ModelCache {
        return .{ .gpa = gpa, .device = device };
    }

    /// Free every model, and its textures from `textures`. The GPU must be done with them
    /// (`Graphics.queue.waitIdle`).
    /// Host teardown: use the same texture cache used by `get`; invalidates all returned
    /// `Gpu` values and borrowed part slices. Call once.
    ///
    /// ```zig
    /// try graphics.queue.waitIdle();
    /// models.deinit(&textures);
    /// ```
    pub fn deinit(self: *ModelCache, textures: *TextureCache) void {
        self.forgetAll(textures);
        self.entries.deinit(self.gpa);
    }

    /// The model at `path`, loading it the first time (its textures into `textures`); null when
    /// it can't be drawn.
    /// Host lookup: `path` is project-relative. Returns cache-owned GPU handles and parts;
    /// do not free them or retain them past invalidation. Load/upload failures are logged
    /// and cached until `forgetAll`; allocation failure can also return null.
    /// Embedded textures are ready for sampling when loading finishes.
    ///
    /// ```zig
    /// const gpu_model = models.get("resources/ship.glb", &textures) orelse return;
    /// ```
    pub fn get(self: *ModelCache, path: []const u8, textures: *TextureCache) ?Gpu {
        if (self.entries.get(path)) |known| return known;
        const key = self.gpa.dupe(u8, path) catch return null;
        const loaded = self.upload(path, textures);
        self.entries.put(self.gpa, key, loaded) catch {
            self.gpa.free(key);
            if (loaded) |gpu| gpu.deinit(self.gpa, textures);
            return null;
        };
        return loaded;
    }

    /// The box round the model at `path`, in its own space, if it is loaded (this doesn't
    /// load it).
    /// Returns `{ minimum, maximum }` by value in model-space units, or null for missing
    /// and failed entries; does not transform the box to world space.
    ///
    /// ```zig
    /// const box = models.bounds("resources/ship.glb") orelse return;
    /// const minimum = box[0];
    /// const maximum = box[1];
    /// ```
    pub fn bounds(self: *const ModelCache, path: []const u8) ?[2][3]f32 {
        const known = self.entries.get(path) orelse return null;
        const gpu = known orelse return null;
        return .{ gpu.min, gpu.max };
    }

    /// Forget every model, so each loads again when next drawn (its file or import settings may
    /// have changed). The GPU must be done with them.
    /// Host-only: releases embedded textures through the same `textures` cache used for
    /// loading, clears failures too, and retains map capacity and loader configuration.
    /// Invalidates all previously returned handles/parts.
    ///
    /// ```zig
    /// try graphics.queue.waitIdle();
    /// models.forgetAll(&textures);
    /// ```
    pub fn forgetAll(self: *ModelCache, textures: *TextureCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |gpu| gpu.deinit(self.gpa, textures);
            self.gpa.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Load the model at `path` and put it, and its textures, on the GPU.
    fn upload(self: *ModelCache, path: []const u8, textures: *TextureCache) ?Gpu {
        const loader = self.loader orelse return null;
        var model = loader.load(loader.context, self.gpa, path) catch |err| {
            log.err("cannot load model {s}: {t}", .{ path, err });
            return null;
        };
        defer model.deinit(self.gpa);
        if (model.indices.len == 0) {
            log.warn("{s} has no triangles", .{path});
            return null;
        }
        return self.uploadModel(path, model, textures) catch |err| {
            log.err("cannot upload {s}: {t}", .{ path, err });
            return null;
        };
    }

    fn uploadModel(self: *ModelCache, path: []const u8, model: assets.Model, textures: *TextureCache) !Gpu {
        const vertices = try vit.Buffer.init(self.device, .{ .label = "model vertices", .size = model.vertices.len * @sizeOf(assets.model.Vertex), .usage = .{ .vertex = true }, .initial_data = std.mem.sliceAsBytes(model.vertices) });
        errdefer vertices.deinit();
        const indices = try vit.Buffer.init(self.device, .{ .label = "model indices", .size = model.indices.len * @sizeOf(u32), .usage = .{ .index = true }, .initial_data = std.mem.sliceAsBytes(model.indices) });
        errdefer indices.deinit();

        // Its textures, then its parts painted with them; a model without parts is one.
        const made = try self.gpa.alloc(?texture_cache.Gpu, model.textures.len);
        defer self.gpa.free(made);
        @memset(made, null);
        errdefer for (made) |texture| if (texture) |gpu| textures.release(gpu);
        for (model.textures, made) |texture, *gpu| gpu.* = try textures.make(texture, path);
        const whole = [_]assets.model.Part{.{ .first_index = 0, .index_count = @intCast(model.indices.len) }};
        const source = if (model.parts.len > 0) model.parts else &whole;
        const parts = try self.gpa.alloc(Gpu.Part, source.len);
        for (source, parts) |part, *gpu| gpu.* = .{ .first_index = part.first_index, .index_count = part.index_count, .texture = if (part.texture) |at| made[at] else null };
        // A texture no part paints with goes now: the parts are what free them.
        for (made, 0..) |texture, at| if (texture) |gpu| {
            const used = for (source) |part| {
                if (part.texture == @as(u32, @intCast(at))) break true;
            } else false;
            if (!used) textures.release(gpu);
        };
        var min: [3]f32 = @splat(std.math.inf(f32));
        var max: [3]f32 = @splat(-std.math.inf(f32));
        for (model.vertices) |vertex| for (&min, &max, vertex.position) |*low, *high, at| {
            low.* = @min(low.*, at);
            high.* = @max(high.*, at);
        };
        return .{ .vertices = vertices, .indices = indices, .parts = parts, .min = min, .max = max };
    }
};
