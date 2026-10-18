//! Model and image files as the editor draws them: imported straight from the project's files
//! (models through assimp, with their descriptors' settings; images through stb_image, both in
//! `eggy_model_import`) whenever the scene's caches ask for one. (The runtime loads what
//! packaging made of them instead.)
const std = @import("std");
const eggy = @import("eggy");
const model_import = @import("eggy_model_import");
const log = std.log.scoped(.assets);

pub const ProjectAssets = struct {
    /// The project's folder; the files' paths are relative to it.
    project_dir: []const u8,

    /// C-callable providers safe for a separately compiled game library.
    /// Editor-only: `self` and its project directory string must outlive every provider call.
    /// Reads/imports allocate caller-owned results with the allocator passed to the provider.
    ///
    /// ```zig
    /// // Given a long-lived ProjectAssets named project_assets:
    /// const providers = project_assets.resources();
    /// _ = providers; // Pass to the editor's game/resource host.
    /// ```
    pub fn resources(self: *ProjectAssets) eggy.resources.Resources {
        return eggy.resources.Resources.from(self, readFile, loadModel, loadImage);
    }

    /// Read project-relative files while keeping no open directory or transient I/O pointer.
    /// The borrowed provider retains `self`; reads validate paths and return caller-owned,
    /// zero-terminated bytes (at most 64 MiB), propagating filesystem/allocation failures.
    ///
    /// ```zig
    /// // Given long-lived project_assets, allocator gpa, and a scene path:
    /// const provider = project_assets.files();
    /// const source = try provider.read(provider.context, gpa, path);
    /// defer gpa.free(source);
    /// ```
    pub fn files(self: *ProjectAssets) eggy.scene_instances.Files {
        return .{ .context = self, .read = readFile };
    }

    fn readFile(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ![:0]u8 {
        try eggy.refs.validatePath(path);
        const self: *ProjectAssets = @ptrCast(@alignCast(context));
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer dir.close(io);
        return dir.readFileAllocOptions(io, path, gpa, .limited(64 << 20), .of(u8), 0);
    }

    /// A loader for `eggy.model_cache.ModelCache`; `self` must outlive it.
    /// Editor-only: imports project files with descriptor settings; errors reach the cache.
    /// Loaded model storage belongs to the requesting allocator/cache, not this adapter.
    ///
    /// ```zig
    /// // Given a long-lived ProjectAssets:
    /// const loader = project_assets.models();
    /// _ = loader; // Supply to the graphics model cache.
    /// ```
    pub fn models(self: *ProjectAssets) eggy.model_cache.Loader {
        return .{ .context = self, .load = loadModel };
    }

    /// A loader for `eggy.texture_cache.TextureCache`; `self` must outlive it.
    /// Editor-only: decodes project images on demand; the requesting allocator/cache owns
    /// decoded pixels, and file/decode/allocation failures propagate through the loader.
    ///
    /// ```zig
    /// // Given a long-lived ProjectAssets:
    /// const loader = project_assets.textures();
    /// _ = loader; // Supply to the graphics texture cache.
    /// ```
    pub fn textures(self: *ProjectAssets) eggy.texture_cache.Loader {
        return .{ .context = self, .load = loadImage };
    }

    fn loadModel(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) !eggy.assets.Model {
        const self: *ProjectAssets = @ptrCast(@alignCast(context));
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        // Its import settings, from its descriptor (the defaults until it has one).
        var project = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer project.close(io);
        const found = eggy.assets.descriptor.read(arena.allocator(), io, project, path) catch |err| blk: {
            log.warn("{s}'s descriptor doesn't read ({t}): importing it as it is", .{ path, err });
            break :blk null;
        };
        const settings = if (found) |descriptor| descriptor.model else eggy.assets.descriptor.ModelImport{};

        const full_path = try std.fs.path.joinZ(arena.allocator(), &.{ self.project_dir, path });
        return model_import.import(gpa, full_path, settings) catch |err| {
            log.err("cannot import {s}: {s} ({t})", .{ path, model_import.lastError(), err });
            return err;
        };
    }

    fn loadImage(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) !eggy.assets.Texture {
        const self: *ProjectAssets = @ptrCast(@alignCast(context));
        const full_path = try std.fs.path.joinZ(gpa, &.{ self.project_dir, path });
        defer gpa.free(full_path);
        return model_import.decodeImage(gpa, full_path) catch |err| {
            log.err("cannot read the image {s}: {s} ({t})", .{ path, model_import.lastError(), err });
            return err;
        };
    }
};
