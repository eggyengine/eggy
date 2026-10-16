//! The images a scene paints its meshes with, on the GPU: each image file loaded through
//! `loader` the first time a `Mesh` shows it, then kept, and the textures inside model files
//! (`model_cache.zig` makes those here). A texture is new until `prepare` readies it for
//! sampling, outside a render pass; every mesh without one is painted with plain white. The
//! editor's loader decodes image files; the runtime's reads what packaging made of them
//! (`.eggtexture`).
const std = @import("std");
const vit = @import("vitellus");
const assets = @import("eggy_assets");
const log = std.log.scoped(.textures);

/// How an image file (by its path in the project) becomes pixels.
pub const Loader = struct {
    context: *anyopaque,
    /// The image at `path`, allocated with `gpa`; null when it can't be loaded (having said why).
    load: *const fn (context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ?assets.Texture,
};

/// A texture on the GPU, and the bind group that paints with it (see `TextureCache.layout`).
pub const Gpu = struct {
    texture: vit.Texture,
    view: vit.TextureView,
    group: vit.BindGroup,

    pub fn deinit(self: Gpu) void {
        self.group.deinit();
        self.view.deinit();
        self.texture.deinit();
    }
};

pub const TextureCache = struct {
    gpa: std.mem.Allocator,
    device: vit.Device,
    /// What a texture's bind group holds: the texture, then the sampler (set 1 of the meshes'
    /// pipelines).
    layout: vit.BindGroupLayout,
    sampler: vit.Sampler,
    /// One white pixel, for meshes without a texture.
    white: Gpu,
    /// Where image files come from; none (every image file paints white) until set.
    loader: ?Loader = null,
    /// By path, which the map owns; null for one that didn't load, so it isn't tried again.
    entries: std.StringHashMapUnmanaged(?Gpu) = .empty,
    /// Textures made since the last `prepare`, not yet ready to sample.
    fresh: std.ArrayList(vit.Texture) = .empty,

    pub fn init(gpa: std.mem.Allocator, device: vit.Device) !TextureCache {
        const layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
            .{ .binding = 1, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
        } });
        errdefer layout.deinit();
        // Repeating, so a texture can tile.
        const sampler = try vit.Sampler.init(device, .{ .address_u = .repeat, .address_v = .repeat });
        errdefer sampler.deinit();
        var self = TextureCache{ .gpa = gpa, .device = device, .layout = layout, .sampler = sampler, .white = undefined };
        var white = [_]u8{ 255, 255, 255, 255 };
        self.white = try self.make(.{ .width = 1, .height = 1, .pixels = &white }, "white");
        return self;
    }

    /// Free every texture. The GPU must be done with them (`Graphics.queue.waitIdle`).
    pub fn deinit(self: *TextureCache) void {
        self.forgetAll();
        self.entries.deinit(self.gpa);
        self.fresh.deinit(self.gpa);
        self.white.deinit();
        self.sampler.deinit();
        self.layout.deinit();
    }

    /// The image at `path`, loading it the first time; null when it can't be painted with.
    pub fn get(self: *TextureCache, path: []const u8) ?Gpu {
        if (self.entries.get(path)) |known| return known;
        const key = self.gpa.dupe(u8, path) catch return null;
        const loaded = self.load(path);
        self.entries.put(self.gpa, key, loaded) catch {
            self.gpa.free(key);
            if (loaded) |gpu| gpu.deinit();
            return null;
        };
        return loaded;
    }

    /// `texture` on the GPU, labelled `label`, owned by the caller (see `Gpu.deinit`); it is
    /// ready to sample after the next `prepare`.
    pub fn make(self: *TextureCache, texture: assets.Texture, label: []const u8) !Gpu {
        const made = try vit.Texture.init(self.device, .{ .label = label, .width = texture.width, .height = texture.height, .format = .rgba8_unorm, .usage = .{ .sampled = true, .transfer_dst = true }, .initial_data = texture.pixels });
        errdefer made.deinit();
        const view = try vit.TextureView.init(self.device, .{ .texture = made });
        errdefer view.deinit();
        const group = try vit.BindGroup.init(self.device, .{ .layout = self.layout, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = view } },
            .{ .binding = 1, .resource = .{ .sampler = self.sampler } },
        } });
        errdefer group.deinit();
        try self.fresh.append(self.gpa, made);
        return .{ .texture = made, .view = view, .group = group };
    }

    /// Ready every texture made since the last call for sampling. Call outside a render pass,
    /// before drawing with them.
    pub fn prepare(self: *TextureCache, cmd: vit.CommandBuffer) !void {
        for (self.fresh.items) |texture| try cmd.barrier(&.{.{ .texture = .{ .texture = texture, .before = .common, .after = .sampled } }});
        self.fresh.clearRetainingCapacity();
    }

    /// Forget every image file's texture, so each loads again when next drawn (its file may
    /// have changed). The GPU must be done with them.
    pub fn forgetAll(self: *TextureCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |gpu| self.release(gpu);
            self.gpa.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Free `gpu`, one this cache made, also dropping it from those waiting for `prepare`.
    pub fn release(self: *TextureCache, gpu: Gpu) void {
        for (self.fresh.items, 0..) |texture, i| if (std.meta.eql(texture, gpu.texture)) {
            _ = self.fresh.swapRemove(i);
            break;
        };
        gpu.deinit();
    }

    /// Load the image at `path` and put it on the GPU.
    fn load(self: *TextureCache, path: []const u8) ?Gpu {
        const loader = self.loader orelse return null;
        var texture = loader.load(loader.context, self.gpa, path) orelse return null;
        defer texture.deinit(self.gpa);
        return self.make(texture, path) catch |err| {
            log.err("cannot upload {s}: {t}", .{ path, err });
            return null;
        };
    }
};
