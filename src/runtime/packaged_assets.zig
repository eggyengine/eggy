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
    pub fn resources(self: *Data) eggy.resources.Resources {
        return eggy.resources.Resources.from(self, readCopy, loadModel, loadTexture);
    }

    /// The game's `data/` folder and its manifest. On the heap, as the loaders keep a pointer to
    /// it.
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

    pub fn close(self: *Data) void {
        self.dir.close(self.threaded.io());
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// A loader for `eggy.model_cache.ModelCache` reading packaged models.
    pub fn models(self: *Data) eggy.model_cache.Loader {
        return .{ .context = self, .load = loadModel };
    }

    /// A loader for `eggy.texture_cache.TextureCache` reading packaged textures.
    pub fn textures(self: *Data) eggy.texture_cache.Loader {
        return .{ .context = self, .load = loadTexture };
    }

    /// The files packaging copied as they were (scenes...), by their paths in the project.
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
