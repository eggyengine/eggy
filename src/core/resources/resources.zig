//! Owned resource reads across the executable/game-library boundary.
const std = @import("std");
const builtin = @import("builtin");
const assets = @import("eggy_assets");
const refs = @import("../refs.zig");
const Files = @import("../scene_instances.zig").Files;
const ModelLoader = @import("../model_cache.zig").Loader;
const ImageLoader = @import("../texture_cache.zig").Loader;
const Read = *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![:0]u8;
const support = @import("../support.zig");
pub const async_support: support.Support = .available;
pub const Request = enum(u64) { _ };
pub const LoadKind = enum(u32) { bytes, model, image };
pub const Progress = enum(u32) { queued, loading, cancelling, complete };

/// An independently owned asynchronous result. Free it with `deinit`, not through the queue.
pub const Result = struct {
    gpa: std.mem.Allocator,
    value: union(LoadKind) { bytes: [:0]u8, model: assets.Model, image: assets.Texture },

    pub fn deinit(self: *Result) void {
        switch (self.value) {
            .bytes => |bytes| self.gpa.free(bytes),
            .model => |*model| model.deinit(self.gpa),
            .image => |*image| image.deinit(self.gpa),
        }
        self.* = undefined;
    }
};

/// Host-owned callbacks; no worker ever retains code supplied by a game library.
pub const AsyncProvider = struct {
    context: *anyopaque,
    submit: *const fn (*anyopaque, *const anyopaque, LoadKind, [*]const u8, usize, *u64) callconv(.c) Status,
    poll: *const fn (*anyopaque, u64, *anyopaque) callconv(.c) Status,
    cancel: *const fn (*anyopaque, u64) callconv(.c) Status,
    progress: *const fn (*anyopaque, u64, *Progress) callconv(.c) Status,
};

/// Stable error codes: Zig error numbers are local to each compilation.
pub const Status = enum(u32) { ok, not_found, not_packaged, invalid_data, invalid_path, out_of_memory, failed, pending, cancelled, invalid_request, too_many_requests };
const Bytes = extern struct { ptr: [*]u8, len: usize };
const Provider = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, *const anyopaque, [*]const u8, usize, *Bytes) callconv(.c) Status,
    model: *const fn (*anyopaque, *const anyopaque, [*]const u8, usize, *anyopaque) callconv(.c) Status,
    image: *const fn (*anyopaque, *const anyopaque, [*]const u8, usize, *anyopaque) callconv(.c) Status,
};

/// A borrowed, C-safe provider view. Results belong to the caller, never GPU caches.
pub const Resources = struct {
    provider: ?Provider = null,
    async_provider: ?AsyncProvider = null,

    /// Install host-local loaders. Instantiate in the executable that owns `context` and the
    /// callbacks, which must outlive this view. Only generated C callbacks cross the boundary.
    /// Host-only: callbacks allocate results with the supplied caller allocator, including a
    /// trailing zero for reads. Both sides must use matching Eggy/asset layouts.
    ///
    /// ```zig
    /// // Host with context pointer and correctly typed read/model/image callbacks:
    /// const resources = Resources.from(context, readSource, loadModelSource, loadImageSource);
    /// ```
    pub fn from(context: *anyopaque, comptime read_source: Read, comptime model_source: @FieldType(ModelLoader, "load"), comptime image_source: @FieldType(ImageLoader, "load")) Resources {
        const Bridge = struct {
            fn readBytes(raw: *anyopaque, allocator: *const anyopaque, path: [*]const u8, len: usize, out: *Bytes) callconv(.c) Status {
                const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(allocator));
                const bytes = read_source(raw, gpa.*, path[0..len]) catch |err| return status(err, path[0..len]);
                out.* = .{ .ptr = bytes.ptr, .len = bytes.len };
                return .ok;
            }
            fn loadModel(raw: *anyopaque, allocator: *const anyopaque, path: [*]const u8, len: usize, output: *anyopaque) callconv(.c) Status {
                const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(allocator));
                const out: *assets.Model = @ptrCast(@alignCast(output));
                out.* = model_source(raw, gpa.*, path[0..len]) catch |err| return status(err, path[0..len]);
                return .ok;
            }
            fn loadImage(raw: *anyopaque, allocator: *const anyopaque, path: [*]const u8, len: usize, output: *anyopaque) callconv(.c) Status {
                const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(allocator));
                const out: *assets.Texture = @ptrCast(@alignCast(output));
                out.* = image_source(raw, gpa.*, path[0..len]) catch |err| return status(err, path[0..len]);
                return .ok;
            }
        };
        return .{ .provider = .{ .context = context, .read = Bridge.readBytes, .model = Bridge.loadModel, .image = Bridge.loadImage } };
    }

    /// Read an AssetRef into caller-owned sentinel-terminated bytes; free with `gpa.free`.
    /// Only copied resources support raw reads; converted models/images return
    /// `ConvertedResource`. Unset paths, missing providers and provider failures are errors.
    ///
    /// ```zig
    /// // In a game hook, with gpa:
    /// const text = try app.resources().read(gpa, eggy.AssetRef(.text).init("resources/story.txt"));
    /// defer gpa.free(text);
    /// ```
    pub fn read(self: Resources, gpa: std.mem.Allocator, file: anytype) ![:0]u8 {
        comptime {
            if (refs.refKind(@TypeOf(file)) != .asset) @compileError("read expects an AssetRef");
        }
        if (file.path().len == 0) return error.UnsetAsset;
        if (assets.manifest.Packaged.of(file.path()) != .copy) return error.ConvertedResource;
        const provider = self.provider orelse return unavailable();
        var bytes: Bytes = undefined;
        try check(provider.read(provider.context, &gpa, file.path().ptr, file.path().len, &bytes));
        return bytes.ptr[0..bytes.len :0];
    }

    /// Import/decode caller-owned CPU geometry; call `Model.deinit(gpa)` afterwards.
    /// Does not populate GPU caches. An unset reference, absent provider or loader failure
    /// returns an error without transferring a model to the caller.
    ///
    /// ```zig
    /// // In a game hook, with gpa:
    /// var model = try app.resources().loadModel(gpa, .init("resources/ship.glb"));
    /// defer model.deinit(gpa);
    /// ```
    pub fn loadModel(self: Resources, gpa: std.mem.Allocator, file: refs.AssetRef(.model)) !assets.Model {
        if (file.len == 0) return error.UnsetAsset;
        const provider = self.provider orelse return unavailable();
        var result: assets.Model = undefined;
        try check(provider.model(provider.context, &gpa, file.path().ptr, file.path().len, &result));
        return result;
    }

    /// Decode caller-owned pixels; call `Texture.deinit(gpa)` afterwards.
    /// Does not upload a GPU texture. Rejects unset references and unsupported image formats;
    /// allocation, provider and decode failures propagate through stable error codes.
    ///
    /// ```zig
    /// // In a game hook, with gpa:
    /// var image = try app.resources().loadImage(gpa, .init("resources/ship.png"));
    /// defer image.deinit(gpa);
    /// ```
    pub fn loadImage(self: Resources, gpa: std.mem.Allocator, file: refs.AssetRef(.image)) !assets.Texture {
        if (file.len == 0) return error.UnsetAsset;
        if (!assets.Kind.isTexture(file.path())) return error.UnsupportedImageFormat;
        const provider = self.provider orelse return unavailable();
        var result: assets.Texture = undefined;
        try check(provider.image(provider.context, &gpa, file.path().ptr, file.path().len, &result));
        return result;
    }

    /// Queue copied-file I/O without blocking native gameplay. `gpa` must remain alive until
    /// cancellation/reset or completion; results use it only when polled on the caller thread.
    pub fn readAsync(self: Resources, gpa: std.mem.Allocator, file: anytype) !Request {
        comptime {
            if (refs.refKind(@TypeOf(file)) != .asset) @compileError("readAsync expects an AssetRef");
        }
        if (assets.manifest.Packaged.of(file.path()) != .copy) return error.ConvertedResource;
        return self.submit(gpa, .bytes, file.path());
    }

    /// Import/decode CPU model data on a native worker. GPU upload remains on the render thread.
    pub fn loadModelAsync(self: Resources, gpa: std.mem.Allocator, file: refs.AssetRef(.model)) !Request {
        return self.submit(gpa, .model, file.path());
    }

    /// Decode CPU pixels on a native worker, without creating GPU resources.
    pub fn loadImageAsync(self: Resources, gpa: std.mem.Allocator, file: refs.AssetRef(.image)) !Request {
        if (!assets.Kind.isTexture(file.path())) return error.UnsupportedImageFormat;
        return self.submit(gpa, .image, file.path());
    }

    fn submit(self: Resources, gpa: std.mem.Allocator, kind: LoadKind, path: []const u8) !Request {
        if (path.len == 0) return error.UnsetAsset;
        try refs.validatePath(path);
        const provider = self.async_provider orelse return error.NoAsyncResourceProvider;
        var id: u64 = undefined;
        try check(provider.submit(provider.context, &gpa, kind, path.ptr, path.len, &id));
        return @enumFromInt(id);
    }

    /// Take a completed result once; null means pending. Failures/cancellation consume the
    /// request and propagate explicitly. Browser preloads decode when polled, without threads.
    pub fn poll(self: Resources, request: Request) !?Result {
        const provider = self.async_provider orelse return error.NoAsyncResourceProvider;
        var result: Result = undefined;
        const outcome = provider.poll(provider.context, @intFromEnum(request), &result);
        if (outcome == .pending) return null;
        try check(outcome);
        return result;
    }

    /// Request cooperative cancellation. Already-running imports finish but their result is
    /// discarded; poll until `ResourceCancelled`. Cancellation itself does not block.
    pub fn cancel(self: Resources, request: Request) !void {
        const provider = self.async_provider orelse return error.NoAsyncResourceProvider;
        try check(provider.cancel(provider.context, @intFromEnum(request)));
    }

    /// Observe queued/loading/cancelling/complete state without taking the result.
    pub fn progress(self: Resources, request: Request) !Progress {
        const provider = self.async_provider orelse return error.NoAsyncResourceProvider;
        var result: Progress = undefined;
        try check(provider.progress(provider.context, @intFromEnum(request), &result));
        return result;
    }

    /// Adapt to a local scene reader. This callback and its caller must be in the same
    /// compilation; `self` must outlive the synchronous scene operation.
    /// Host-only: the returned adapter borrows this Resources value, not just its provider.
    ///
    /// ```zig
    /// // Host with resources, scene_instances, world, access and a scene reference:
    /// const root = try scene_instances.create(resources.sceneFiles(), world, access, file, null);
    /// ```
    pub fn sceneFiles(self: *Resources) Files {
        return .{ .context = self, .read = readScene };
    }
    fn readScene(raw: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ![:0]u8 {
        const self: *Resources = @ptrCast(@alignCast(raw));
        return self.read(gpa, try refs.AssetRef(.scene).parse(path));
    }
};

/// Host-only conversion of local errors to stable resource-bridge status codes.
pub fn status(err: anyerror, path: []const u8) Status {
    return switch (err) {
        error.FileNotFound => .not_found,
        error.NotPackaged => .not_packaged,
        error.UnexpectedData, error.ParseZon, error.InvalidAssetData => .invalid_data,
        error.InvalidPath, error.PathTooLong, error.WrongAssetKind => .invalid_path,
        error.OutOfMemory => .out_of_memory,
        error.ResourceCancelled => .cancelled,
        error.InvalidResourceRequest => .invalid_request,
        error.TooManyResourceRequests => .too_many_requests,
        else => {
            std.log.err("resource {s} failed: {t}", .{ path, err });
            return .failed;
        },
    };
}

fn check(result: Status) !void {
    return switch (result) {
        .ok => {},
        .not_found => error.FileNotFound,
        .not_packaged => error.NotPackaged,
        .invalid_data => error.InvalidAssetData,
        .invalid_path => error.InvalidPath,
        .out_of_memory => error.OutOfMemory,
        .failed => error.AssetLoadFailed,
        .pending => error.ResourcePending,
        .cancelled => error.ResourceCancelled,
        .invalid_request => error.InvalidResourceRequest,
        .too_many_requests => error.TooManyResourceRequests,
    };
}

fn unavailable() error{ UnsupportedPlatform, NoResourceProvider } {
    return if (builtin.os.tag == .emscripten) error.UnsupportedPlatform else error.NoResourceProvider;
}

test "C-safe resource reads preserve stable failures and caller ownership" {
    const Source = struct {
        fn read(_: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ![:0]u8 {
            if (!std.mem.eql(u8, path, "notes.txt")) return error.FileNotFound;
            return gpa.dupeZ(u8, "hello");
        }
        fn model(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !assets.Model {
            return error.NotPackaged;
        }
        fn image(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !assets.Texture {
            return error.OutOfMemory;
        }
    };
    var context: u8 = 0;
    const resources = Resources.from(&context, Source.read, Source.model, Source.image);
    const text = try resources.read(std.testing.allocator, refs.AssetRef(.text).init("notes.txt"));
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
    try std.testing.expectError(error.FileNotFound, resources.read(std.testing.allocator, refs.AssetRef(.text).init("missing.txt")));
    try std.testing.expectError(error.UnsetAsset, resources.read(std.testing.allocator, refs.AssetRef(.text){}));
    try std.testing.expectError(error.NoResourceProvider, (Resources{}).read(std.testing.allocator, refs.AssetRef(.text).init("notes.txt")));
    try std.testing.expectError(error.NotPackaged, resources.loadModel(std.testing.allocator, .init("ship.glb")));
    try std.testing.expectError(error.OutOfMemory, resources.loadImage(std.testing.allocator, .init("ship.png")));
    try std.testing.expectError(error.ConvertedResource, resources.read(std.testing.allocator, refs.AssetRef(.image).init("ship.png")));
    try std.testing.expectError(error.UnsupportedImageFormat, resources.loadImage(std.testing.allocator, .init("ship.svg")));
}
