//! The model files a scene draws, on the GPU: each one's triangles, loaded through `loader` the
//! first time a `Mesh` shows it, then kept. The editor's loader imports model files with assimp;
//! the runtime's reads what packaging made of them (`.eggmodel`).
const std = @import("std");
const vit = @import("vitellus");
const assets = @import("eggy_assets");
const log = std.log.scoped(.models);

/// How a model file (by its path in the project) becomes triangles.
pub const Loader = struct {
    context: *anyopaque,
    /// The model at `path`, allocated with `gpa`; null when it can't be loaded (having said why).
    load: *const fn (context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ?assets.Model,
};

/// A model's triangles on the GPU.
pub const Gpu = struct {
    vertices: vit.Buffer,
    indices: vit.Buffer,
    index_count: u32,

    fn deinit(self: Gpu) void {
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

    pub fn init(gpa: std.mem.Allocator, device: vit.Device) ModelCache {
        return .{ .gpa = gpa, .device = device };
    }

    /// Free every model. The GPU must be done with them (`Graphics.queue.waitIdle`).
    pub fn deinit(self: *ModelCache) void {
        self.forgetAll();
        self.entries.deinit(self.gpa);
    }

    /// The model at `path`, loading it the first time; null when it can't be drawn.
    pub fn get(self: *ModelCache, path: []const u8) ?Gpu {
        if (self.entries.get(path)) |known| return known;
        const key = self.gpa.dupe(u8, path) catch return null;
        const loaded = self.upload(path);
        self.entries.put(self.gpa, key, loaded) catch {
            self.gpa.free(key);
            if (loaded) |gpu| gpu.deinit();
            return null;
        };
        return loaded;
    }

    /// Forget every model, so each loads again when next drawn (its file or import settings may
    /// have changed). The GPU must be done with them.
    pub fn forgetAll(self: *ModelCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |gpu| gpu.deinit();
            self.gpa.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Load the model at `path` and put it on the GPU.
    fn upload(self: *ModelCache, path: []const u8) ?Gpu {
        const loader = self.loader orelse return null;
        var model = loader.load(loader.context, self.gpa, path) orelse return null;
        defer model.deinit(self.gpa);
        if (model.indices.len == 0) {
            log.warn("{s} has no triangles", .{path});
            return null;
        }
        const vertices = vit.Buffer.init(self.device, .{ .label = "model vertices", .size = model.vertices.len * @sizeOf(assets.model.Vertex), .usage = .{ .vertex = true }, .initial_data = std.mem.sliceAsBytes(model.vertices) }) catch |err| {
            log.err("cannot upload {s}: {t}", .{ path, err });
            return null;
        };
        const indices = vit.Buffer.init(self.device, .{ .label = "model indices", .size = model.indices.len * @sizeOf(u32), .usage = .{ .index = true }, .initial_data = std.mem.sliceAsBytes(model.indices) }) catch |err| {
            vertices.deinit();
            log.err("cannot upload {s}: {t}", .{ path, err });
            return null;
        };
        return .{ .vertices = vertices, .indices = indices, .index_count = @intCast(model.indices.len) };
    }
};
