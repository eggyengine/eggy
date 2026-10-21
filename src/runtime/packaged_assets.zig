//! The game's resources in desktop `data/`, Android assets or a browser preload (see
//! `addGame`): every payload is named only by its canonical identity. Models, textures and
//! independent animation clips are decoded without importers or an external runtime index.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const android = @import("builtin").abi.isAndroid();
const bundled = android or @import("builtin").os.tag == .emscripten;

pub const Data = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,

    /// C-callable providers, matching the editor provider's author-facing results.
    /// Borrows `self` until `close`; returned CPU assets/bytes use the caller's allocator.
    /// Host setup installs this view before plugin initialization; games use `app.resources()`.
    ///
    /// ```zig
    /// app.resource_provider = data.resources(); // data remains open until App shutdown.
    /// ```
    pub fn resources(self: *Data) eggy.resources.Resources {
        return eggy.resources.Resources.from(self, readCopy, loadModel, loadTexture);
    }

    /// The game's `data/` folder, heap-owned because loaders retain its address.
    /// Uses `<executable>/../data/` on desktop and SDL's bundled filesystem on Android/Web.
    /// Borrows `io` through `close`; owns the desktop directory.
    /// Pair with `close`. Filesystem and allocation
    /// failures propagate without leaving a partially initialized owner.
    ///
    /// ```zig
    /// const data = try Data.open(gpa, process.io);
    /// defer data.close();
    /// ```
    pub fn open(gpa: std.mem.Allocator, io: std.Io) !*Data {
        const self = try gpa.create(Data);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .dir = undefined };
        if (!bundled) {
            const base = try sdl3.filesystem.getBasePath();
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            self.dir = try std.Io.Dir.cwd().openDir(io, try std.fmt.bufPrint(&path_buffer, "{s}../data", .{base}), .{});
        }
        return self;
    }

    /// Close the data directory and destroy this heap owner.
    /// Call once, after all providers/caches using it have stopped; borrowed views become invalid.
    ///
    /// ```zig
    /// const data = try Data.open(gpa, process.io);
    /// defer data.close(); // Must run after users of data.resources()/models()/textures().
    /// ```
    pub fn close(self: *Data) void {
        if (!bundled) self.dir.close(self.io);
        self.gpa.destroy(self);
    }

    /// A loader for `eggy.model_cache.ModelCache` reading packaged models.
    /// Borrows `self`; load calls return caller-owned CPU models and propagate missing/corrupt
    /// packaged-file errors. Does not allocate or preload a model when creating the view.
    ///
    /// ```zig
    /// app.graphics.models.loader = data.models();
    /// ```
    pub fn models(self: *Data) eggy.model_cache.Loader {
        return .{ .context = self, .load = loadModel };
    }

    /// A loader for `eggy.texture_cache.TextureCache` reading packaged textures.
    /// Borrows `self`; `data` must remain open while the GPU cache can request images.
    /// Creating the view performs no I/O; individual loads report their errors.
    ///
    /// ```zig
    /// app.graphics.textures.loader = data.textures();
    /// ```
    pub fn textures(self: *Data) eggy.texture_cache.Loader {
        return .{ .context = self, .load = loadTexture };
    }

    /// The files packaging copied unchanged (scenes...), addressed by identity.
    /// Borrows `self`; each successful read allocates null-terminated bytes with the supplied
    /// allocator. Invalid identities, missing files and read/size errors propagate.
    ///
    /// ```zig
    /// const files = data.copies();
    /// const source = try files.read(files.context, gpa, scene_ref.key());
    /// defer gpa.free(source);
    /// ```
    pub fn copies(self: *Data) eggy.scene_instances.Files {
        return .{ .context = self, .read = readCopy };
    }

    /// Open an identity directly, rejecting paths and traversal at the filesystem boundary.
    fn openPackaged(self: *Data, path: []const u8) !std.Io.File {
        var name: [eggy.assets.id.key_len]u8 = undefined;
        return self.dir.openFile(self.io, eggy.assets.id.key(&name, try eggy.assets.id.parse(path)), .{});
    }

    fn loadModel(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) !eggy.assets.Model {
        const self: *Data = @ptrCast(@alignCast(context));
        return self.readPackaged(eggy.assets.Model, eggy.assets.model, gpa, path);
    }

    fn loadTexture(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) !eggy.assets.Texture {
        const self: *Data = @ptrCast(@alignCast(context));
        const root = @import("root");
        if (comptime @hasDecl(root, "eggy_asset_ids")) {
            if (root.eggy_asset_ids.findId(try eggy.assets.id.parse(path))) |entry| {
                if (entry.kind != @intFromEnum(eggy.assets.Kind.image)) return error.WrongAssetKind;
                if (!entry.converted) return error.UnsupportedImageFormat;
            }
        }
        return self.readPackaged(eggy.assets.Texture, eggy.assets.texture, gpa, path);
    }

    fn readCopy(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![:0]u8 {
        const self: *Data = @ptrCast(@alignCast(context));
        const identity = try eggy.assets.id.parse(path);
        const root = @import("root");
        if (comptime @hasDecl(root, "eggy_asset_ids")) {
            if (root.eggy_asset_ids.findId(identity)) |entry| {
                if (entry.converted) return error.ConvertedResource;
            }
        }
        if (bundled) {
            return self.readBundled(gpa, path);
        }
        const io = self.io;
        var file = try self.openPackaged(path);
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &buffer);
        return reader.interface.allocRemainingAlignedSentinel(gpa, .limited(64 << 20), .of(u8), 0);
    }

    /// Decode an identity-addressed payload using the requested format.
    fn readPackaged(self: *Data, comptime T: type, comptime format: type, gpa: std.mem.Allocator, path: []const u8) !T {
        if (bundled) {
            const bytes = try self.readBundled(gpa, path);
            defer gpa.free(bytes);
            var reader: std.Io.Reader = .fixed(bytes);
            return format.read(gpa, &reader);
        }
        const io = self.io;
        var file = try self.openPackaged(path);
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &buffer);
        return format.read(gpa, &reader.interface);
    }

    fn readBundled(_: *Data, gpa: std.mem.Allocator, name: []const u8) ![:0]u8 {
        var key: [eggy.assets.id.key_len]u8 = undefined;
        const canonical = eggy.assets.id.key(&key, try eggy.assets.id.parse(name));
        var path_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "data/{s}", .{canonical});
        // SDL reads Android's AssetManager or Emscripten's preloaded filesystem.
        const stream = sdl3.c.SDL_IOFromFile(path, "rb") orelse return error.AssetNotFound;
        defer _ = sdl3.c.SDL_CloseIO(stream);
        const size = sdl3.c.SDL_GetIOSize(stream);
        // ponytail: bundled assets are read whole (up to 256 MiB); stream SDL IO for larger assets.
        if (size < 0 or size > 256 << 20) return error.AssetTooLarge;
        const bytes = try gpa.allocSentinel(u8, @intCast(size), 0);
        errdefer gpa.free(bytes);
        if (sdl3.c.SDL_ReadIO(stream, bytes.ptr, bytes.len) != bytes.len) return error.AssetReadFailed;
        return bytes;
    }
};

test "packaged input maps are copied resources readable through the runtime bridge" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "000000000000002a",
        .data = ".{ .controls = .{ .{ .name = \"jump\", .bindings = .{ .{ .key = .space } } } } }",
    });
    var data = Data{
        .gpa = gpa,
        .io = std.testing.io,
        .dir = tmp.dir,
    };
    const source = try data.resources().read(gpa, eggy.AssetRef(.input_map).fromId(42));
    defer gpa.free(source);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const file = try eggy.input.asset.File.parse(arena.allocator(), source);
    try std.testing.expectEqualStrings("jump", file.controls[0].name);
    try std.testing.expectEqual(eggy.Key.space, file.controls[0].bindings[0].key);
    try std.testing.expectError(error.InvalidAssetId, data.copies().read(&data, gpa, "../manifest.zon"));
}
