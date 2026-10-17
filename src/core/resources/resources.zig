//! Owned resource reads through the executable's project or packaged-file provider.
const std = @import("std");
const builtin = @import("builtin");
const assets = @import("eggy_assets");
const refs = @import("../refs.zig");
const Files = @import("../scene_instances.zig").Files;
const ModelLoader = @import("../model_cache.zig").Loader;
const ImageLoader = @import("../texture_cache.zig").Loader;

/// A borrowed provider view. Results belong to the caller, not to the renderer's GPU caches.
pub const Resources = struct {
    files: ?Files = null,
    models: ?ModelLoader = null,
    images: ?ImageLoader = null,

    /// Read a typed file reference, allocating a sentinel-terminated byte slice with `gpa`.
    /// Free it with `gpa.free`. A reference alone never guarantees a file exists.
    pub fn read(self: Resources, gpa: std.mem.Allocator, file: anytype) ![:0]u8 {
        comptime {
            if (refs.refKind(@TypeOf(file)) != .asset) @compileError("read expects an AssetRef");
        }
        if (file.path().len == 0) return error.UnsetAsset;
        const files = self.files orelse return unavailable();
        return files.read(files.context, gpa, file.path());
    }

    /// Decode/import a model into caller-owned CPU memory; call `Model.deinit(gpa)`.
    /// Provider diagnostics describe the original import failure.
    pub fn loadModel(self: Resources, gpa: std.mem.Allocator, file: refs.AssetRef(.model)) !assets.Model {
        if (file.len == 0) return error.UnsetAsset;
        const loader = self.models orelse return unavailable();
        return loader.load(loader.context, gpa, file.path()) orelse error.AssetLoadFailed;
    }

    /// Decode an image into caller-owned pixels; call `Texture.deinit(gpa)`.
    pub fn loadImage(self: Resources, gpa: std.mem.Allocator, file: refs.AssetRef(.image)) !assets.Texture {
        if (file.len == 0) return error.UnsetAsset;
        const loader = self.images orelse return unavailable();
        return loader.load(loader.context, gpa, file.path()) orelse error.AssetLoadFailed;
    }
};

fn unavailable() error{ UnsupportedPlatform, NoResourceProvider } {
    return if (builtin.os.tag == .emscripten) error.UnsupportedPlatform else error.NoResourceProvider;
}

test "typed resource reads preserve provider errors and caller ownership" {
    const Provider = struct {
        fn read(_: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ![:0]u8 {
            if (!std.mem.eql(u8, path, "notes.txt")) return error.FileNotFound;
            return gpa.dupeZ(u8, "hello");
        }
    };
    var context: u8 = 0;
    const resources = Resources{ .files = .{ .context = &context, .read = Provider.read } };
    const text = try resources.read(std.testing.allocator, refs.AssetRef(.text).init("notes.txt"));
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
    try std.testing.expectError(error.FileNotFound, resources.read(std.testing.allocator, refs.AssetRef(.text).init("missing.txt")));
    try std.testing.expectError(error.UnsetAsset, resources.read(std.testing.allocator, refs.AssetRef(.text){}));
    try std.testing.expectError(error.NoResourceProvider, (Resources{}).read(std.testing.allocator, refs.AssetRef(.text).init("notes.txt")));
}
