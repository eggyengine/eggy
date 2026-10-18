//! The game's resources as packaging installed them in `data/` beside its `bin/` (see
//! `addGame`): each named after its id, found by its path in the project through
//! `data/manifest.zon`. Models and images come as the `.eggmodel`s and `.eggtexture`s made of
//! them, read with no importer or decoder; every other file (scenes...) as it was.
// ponytail: the web build has no `data/` to read; embed or fetch its resources once web games need them.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const manifest = eggy.assets.manifest;

pub const Data = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded = .init_single_threaded,
    dir: std.Io.Dir,
    arena: std.heap.ArenaAllocator,
    files: manifest.Manifest,

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

    /// The game's `data/` folder and its manifest. On the heap, as the loaders keep a pointer to
    /// it.
    /// Host-only, desktop layout `<executable>/../data/`. Owns a directory, parsed manifest
    /// arena and heap allocation; pair with `close`. Filesystem, manifest parse and allocation
    /// failures propagate without leaving a partially initialized owner.
    ///
    /// ```zig
    /// const data = try Data.open(gpa);
    /// defer data.close();
    /// ```
    pub fn open(gpa: std.mem.Allocator) !*Data {
        const self = try gpa.create(Data);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .dir = undefined, .arena = .init(gpa), .files = .{} };
        errdefer self.arena.deinit();
        const io = self.threaded.io();
        const base = try sdl3.filesystem.getBasePath();
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        self.dir = try std.Io.Dir.cwd().openDir(io, try std.fmt.bufPrint(&path_buffer, "{s}../data", .{base}), .{});
        errdefer self.dir.close(io);
        const text = try self.dir.readFileAllocOptions(io, manifest.file_name, self.arena.allocator(), .limited(16 << 20), .of(u8), 0);
        self.files = try manifest.parse(self.arena.allocator(), text);
        return self;
    }

    /// Close the data directory and destroy this heap owner, including its manifest arena.
    /// Call once, after all providers/caches using it have stopped; borrowed views become invalid.
    ///
    /// ```zig
    /// const data = try Data.open(gpa);
    /// defer data.close(); // Must run after users of data.resources()/models()/textures().
    /// ```
    pub fn close(self: *Data) void {
        self.dir.close(self.threaded.io());
        self.arena.deinit();
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

    /// The files packaging copied as they were (scenes...), by their paths in the project.
    /// Borrows `self`; each successful read allocates null-terminated bytes with the supplied
    /// allocator. Paths absent from the manifest fail with `NotPackaged`; read/size errors propagate.
    ///
    /// ```zig
    /// const files = data.copies();
    /// const source = try files.read(files.context, gpa, "resources/scene/main.scene.zon");
    /// defer gpa.free(source);
    /// ```
    pub fn copies(self: *Data) eggy.scene_instances.Files {
        return .{ .context = self, .read = readCopy };
    }

    /// The file packaging made of the project's file at `path`, opened.
    fn openPackaged(self: *Data, path: []const u8) !std.Io.File {
        const entry = self.files.find(path) orelse return error.NotPackaged;
        var name: [32]u8 = undefined;
        return self.dir.openFile(self.threaded.io(), manifest.packagedName(&name, entry), .{});
    }

    fn loadModel(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) !eggy.assets.Model {
        const self: *Data = @ptrCast(@alignCast(context));
        return self.readPackaged(eggy.assets.Model, eggy.assets.model, gpa, path);
    }

    fn loadTexture(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) !eggy.assets.Texture {
        const self: *Data = @ptrCast(@alignCast(context));
        return self.readPackaged(eggy.assets.Texture, eggy.assets.texture, gpa, path);
    }

    fn readCopy(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![:0]u8 {
        const self: *Data = @ptrCast(@alignCast(context));
        const io = self.threaded.io();
        var file = try self.openPackaged(path);
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &buffer);
        return reader.interface.allocRemainingAlignedSentinel(gpa, .limited(64 << 20), .of(u8), 0);
    }

    /// What packaging made of the project's file at `path`, read by `format`'s `read`.
    fn readPackaged(self: *Data, comptime T: type, comptime format: type, gpa: std.mem.Allocator, path: []const u8) !T {
        const io = self.threaded.io();
        var file = try self.openPackaged(path);
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &buffer);
        return format.read(gpa, &reader.interface);
    }
};

test "packaged input maps are copied resources readable through the runtime bridge" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const entry = manifest.Entry{ .path = "resources/input/player.inmap.zon", .id = 0x2a };
    try std.testing.expectEqual(manifest.Packaged.copy, manifest.Packaged.of(entry.path));
    var name: [32]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = manifest.packagedName(&name, entry),
        .data = ".{ .controls = .{ .{ .name = \"jump\", .bindings = .{ .{ .key = .space } } } } }",
    });
    var data = Data{
        .gpa = gpa,
        .dir = tmp.dir,
        .arena = .init(gpa),
        .files = .{ .files = &.{entry} },
    };
    defer data.arena.deinit();
    const source = try data.resources().read(gpa, eggy.AssetRef(.input_map).init("resources/input/player.inmap.zon"));
    defer gpa.free(source);
    const file = try eggy.input.asset.File.parse(data.arena.allocator(), source);
    try std.testing.expectEqualStrings("jump", file.controls[0].name);
    try std.testing.expectEqual(eggy.Key.space, file.controls[0].bindings[0].key);
}
