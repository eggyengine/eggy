//! The images a scene paints its meshes with, on the GPU: each image file loaded through
//! `loader` the first time a `Mesh` shows it, then kept, and the textures inside model files
//! (`model_cache.zig` makes those here). Uploads include their mip chain and finish before
//! sampling; every mesh without a texture is painted with plain white. The
//! editor's loader decodes image files; the runtime's reads what packaging made of them
//! (`.eggtexture`).
const std = @import("std");
const vit = @import("vitellus");
const assets = @import("eggy_assets");
const settings_zig = @import("render_settings.zig");
const mipmaps = @import("mipmaps.zig");
const log = std.log.scoped(.textures);

/// How an asset's canonical identity key becomes CPU pixels.
pub const Loader = struct {
    context: *anyopaque,
    /// Host-local loader; author code uses `Resources`' C-safe provider bridge.
    load: *const fn (context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror!assets.Texture,
};

/// A texture on the GPU, and the bind group that paints with it (see `TextureCache.layout`).
pub const Gpu = struct {
    texture: vit.Texture,
    view: vit.TextureView,
    group: vit.BindGroup,

    /// Destroy owned host GPU handles once, after the GPU finishes using them.
    /// Never destroy a borrowed result of `TextureCache.get`.
    ///
    /// ```zig
    /// try graphics.queue.waitIdle();
    /// owned_gpu.deinit();
    /// ```
    pub fn deinit(self: Gpu) void {
        self.group.deinit();
        self.view.deinit();
        self.texture.deinit();
    }
};

pub const TextureCache = struct {
    gpa: std.mem.Allocator,
    device: vit.Device,
    queue: vit.Queue,
    settings: settings_zig.Settings,
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

    /// Allocate a host texture cache, shared sampler/layout and a one-pixel white fallback.
    /// Borrows `device`, retains `gpa`, and propagates allocation/GPU errors.
    ///
    /// ```zig
    /// var textures = try TextureCache.init(gpa, graphics.device, graphics.queue, graphics.render_settings);
    /// defer textures.deinit(); // Finish GPU use and release model caches first.
    /// textures.loader = image_loader;
    /// ```
    pub fn init(gpa: std.mem.Allocator, device: vit.Device, queue: vit.Queue, settings: settings_zig.Settings) !TextureCache {
        const layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
            .{ .binding = 1, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
        } });
        errdefer layout.deinit();
        // Repeating, so a texture can tile.
        const filter: vit.hal.resource.FilterMode = if (settings.texture_filter == .linear) .linear else .nearest;
        const sampler = try vit.Sampler.init(device, .{
            .address_u = .repeat,
            .address_v = .repeat,
            .mag_filter = filter,
            .min_filter = filter,
            .mipmap_filter = filter,
            .max_anisotropy = settings.anisotropy,
        });
        errdefer sampler.deinit();
        var self = TextureCache{ .gpa = gpa, .device = device, .queue = queue, .settings = settings, .layout = layout, .sampler = sampler, .white = undefined };
        var white = [_]u8{ 255, 255, 255, 255 };
        self.white = try self.make(.{ .width = 1, .height = 1, .pixels = &white }, "white");
        return self;
    }

    /// Free every texture. The GPU must be done with them (`Graphics.queue.waitIdle`).
    /// Host teardown: release caller-owned `make` results and dependent model caches first.
    /// Invalidates cached handles, white fallback, layout and sampler; call once.
    ///
    /// ```zig
    /// try graphics.queue.waitIdle();
    /// textures.deinit();
    /// ```
    pub fn deinit(self: *TextureCache) void {
        self.forgetAll();
        self.entries.deinit(self.gpa);
        self.white.deinit();
        self.sampler.deinit();
        self.layout.deinit();
    }

    /// The image at `path`, loading it the first time; null when it can't be painted with.
    /// Host lookup by canonical asset key: returns cache-owned handles, not ownership.
    /// Do not release the result. Failures are logged/cached until `forgetAll`; configure
    /// `loader` before use.
    ///
    /// ```zig
    /// const paint = textures.get(wood.key()) orelse textures.white;
    /// ```
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
    /// ready to sample when this returns.
    /// Host upload: input is borrowed RGBA8 data with positive dimensions and a matching
    /// byte count. Does not free input pixels or add a path entry. Invalid pixels and
    /// GPU/allocation errors propagate. Release with this cache's `release` after GPU use.
    ///
    /// ```zig
    /// const paint = try textures.make(decoded_texture, "generated paint");
    /// // After submitting this command buffer and waiting for its completion:
    /// try graphics.queue.waitIdle();
    /// textures.release(paint);
    /// ```
    pub fn make(self: *TextureCache, texture: assets.Texture, label: []const u8) !Gpu {
        var chain = try mipmaps.Chain.init(self.gpa, texture.width, texture.height, texture.pixels, self.settings.mipmaps);
        defer chain.deinit(self.gpa);
        const made = try vit.Texture.init(self.device, .{
            .label = label,
            .width = texture.width,
            .height = texture.height,
            .mip_levels = chain.count,
            .format = .rgba8_unorm,
            .usage = .{ .sampled = true, .transfer_dst = true },
        });
        errdefer made.deinit();
        try self.upload(made, chain);
        const view = try vit.TextureView.init(self.device, .{ .texture = made });
        errdefer view.deinit();
        const group = try vit.BindGroup.init(self.device, .{ .layout = self.layout, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = view } },
            .{ .binding = 1, .resource = .{ .sampler = self.sampler } },
        } });
        errdefer group.deinit();
        return .{ .texture = made, .view = view, .group = group };
    }

    fn upload(self: *TextureCache, texture: vit.Texture, chain: mipmaps.Chain) !void {
        const staging = try vit.Buffer.init(self.device, .{ .label = "texture mip upload", .size = chain.bytes.len, .usage = .{ .transfer_src = true }, .memory = .upload, .initial_data = chain.bytes });
        defer staging.deinit();
        const pool = try vit.CommandPool.init(self.device, .{ .label = "texture mip upload" });
        defer pool.deinit();
        const cmd = try vit.CommandBuffer.init(pool, .{});
        defer cmd.deinit();
        try cmd.barrier(&.{.{ .texture = .{ .texture = texture, .before = .common, .after = .copy_destination } }});
        for (chain.levels[0..chain.count], 0..) |level, index| try cmd.copyBufferToTexture(.{
            .buffer = staging,
            .buffer_offset = level.offset,
            .bytes_per_row = level.row_bytes,
            .texture = .{ .texture = texture, .mip_level = @intCast(index) },
            .extent = .{ .width = level.width, .height = level.height },
        });
        try cmd.barrier(&.{.{ .texture = .{ .texture = texture, .before = .copy_destination, .after = .sampled } }});
        try cmd.finish();
        try self.queue.submit(.{ .command_buffers = &.{cmd} });
        // ponytail: one synchronous upload per new image, batch uploads when import latency warrants it.
        try self.queue.waitIdle();
    }

    /// Forget every image file's texture, so each loads again when next drawn (its file may
    /// have changed). The GPU must be done with them.
    /// Host invalidation: clears path entries and failures, but retains the white fallback,
    /// map capacity, loader and caller-owned `make` textures. Invalidates borrowed `get`
    /// results; does not wait for GPU completion itself.
    ///
    /// ```zig
    /// try graphics.queue.waitIdle();
    /// textures.forgetAll();
    /// ```
    pub fn forgetAll(self: *TextureCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |gpu| self.release(gpu);
            self.gpa.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Free `gpu`, one this cache made.
    /// Host-only: use for caller-owned `make` results, never a cached `get` result or white.
    /// The GPU and any recorded commands must no longer reference it; call exactly once.
    ///
    /// ```zig
    /// // After all commands referencing owned_paint have completed:
    /// try graphics.queue.waitIdle();
    /// textures.release(owned_paint);
    /// ```
    pub fn release(self: *TextureCache, gpu: Gpu) void {
        _ = self;
        gpu.deinit();
    }

    /// Load the image at `path` and put it on the GPU.
    fn load(self: *TextureCache, path: []const u8) ?Gpu {
        const loader = self.loader orelse return null;
        var texture = loader.load(loader.context, self.gpa, path) catch |err| {
            log.err("cannot load image {s}: {t}", .{ path, err });
            return null;
        };
        defer texture.deinit(self.gpa);
        return self.make(texture, path) catch |err| {
            log.err("cannot upload {s}: {t}", .{ path, err });
            return null;
        };
    }
};
