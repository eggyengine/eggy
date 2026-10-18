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
pub const async_support: support.Support = .not_implemented;
pub const Request = enum(u32) { _ };

/// Stable error codes: Zig error numbers are local to each compilation.
pub const Status = enum(u32) { ok, not_found, not_packaged, invalid_data, invalid_path, out_of_memory, failed };
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

    // ponytail: resource providers are synchronous, add request ownership and completion before async reads.
    /// Reserved asynchronous read API; always returns `NotImplemented`, allocates nothing,
    /// and never starts a request. Use `read` for supported synchronous reads.
    ///
    /// ```zig
    /// // Capability check, with resources and gpa:
    /// try std.testing.expectError(error.NotImplemented,
    ///     resources.readAsync(gpa, refs.AssetRef(.text).init("notes.txt")));
    /// ```
    pub fn readAsync(_: Resources, gpa: std.mem.Allocator, file: anytype) support.Error!Request {
        comptime {
            if (refs.refKind(@TypeOf(file)) != .asset) @compileError("readAsync expects an AssetRef");
        }
        return support.notImplemented(.{ gpa, file });
    }
    /// Reserved cancellation API; always returns `NotImplemented` and changes no state.
    /// No supported operation currently produces a `Request`.
    ///
    /// ```zig
    /// // Given a future/externally supplied request token:
    /// try std.testing.expectError(error.NotImplemented, resources.cancel(request));
    /// ```
    pub fn cancel(_: Resources, request: Request) support.Error!void {
        return support.notImplemented(request);
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

fn status(err: anyerror, path: []const u8) Status {
    return switch (err) {
        error.FileNotFound => .not_found,
        error.NotPackaged => .not_packaged,
        error.UnexpectedData, error.ParseZon => .invalid_data,
        error.InvalidPath, error.PathTooLong, error.WrongAssetKind => .invalid_path,
        error.OutOfMemory => .out_of_memory,
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
