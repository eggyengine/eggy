//! The editor's view of a project's assets: the hidden catalog (`.eggy/assets.zon`) that gives
//! every file in `resources/` its identity, and the providers that load by identity what the
//! scene's caches ask for, straight from the project's files (models through assimp with the
//! import settings the catalog keeps, images through stb_image, both in `eggy_model_import`).
//! A model file opens into virtual children (`eggy.assets.subassets`): its geometry, one
//! entry for each animation clip it holds and one image for each texture its materials use, which exist only as identities and are read by
//! importing the model again. (The runtime loads what packaging made of them instead.)
const std = @import("std");
const eggy = @import("eggy");
const model_import = @import("eggy_model_import");
const assets = eggy.assets;
const Catalog = assets.catalog.Catalog;
const fixtures = @import("project_fixtures.zig");
const log = std.log.scoped(.assets);
pub const Reference = @import("reference.zig").Reference;

/// A catalogued model or image, owned: what a load needs once the catalog may change.
const Source = struct {
    id: assets.Id,
    path: []u8,
    settings: assets.descriptor.ModelImport,

    fn deinit(self: Source, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
    }
};

pub const ProjectAssets = struct {
    gpa: std.mem.Allocator,
    /// The project's folder; the files' paths are relative to it.
    project_dir: []const u8,
    /// Guards `catalog` and `expanded`: the editor changes them while a provider may be reading.
    lock: std.atomic.Mutex = .unlocked,
    catalog: Catalog,
    /// Each model file's children by its id, filled when it is expanded in the dock or a clip is
    /// looked for. A model that doesn't import has none. Forgotten when the files change.
    expanded: std.AutoHashMapUnmanaged(assets.Id, []assets.subassets.Child) = .empty,
    /// Counts how often the files changed under `expanded`, so a model imported while they did
    /// is not remembered under what is now the wrong path.
    generation: u32 = 0,

    /// Open the catalog of the project in `project_dir` and bring it up to date with its files
    /// (an unreadable catalog is an error, never replaced). `project_dir` must outlive the result.
    /// Editor-only: may create `.eggy/assets.zon` and migrate legacy `.eggy` descriptors.
    ///
    /// ```zig
    /// var project_assets = try ProjectAssets.init(gpa, io, opened.dir);
    /// defer project_assets.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator, io: std.Io, project_dir: []const u8) !ProjectAssets {
        var project = try std.Io.Dir.cwd().openDir(io, project_dir, .{});
        defer project.close(io);
        var catalog = try Catalog.open(gpa, io, project);
        errdefer catalog.deinit();
        const changes = try catalog.sync(io, project);
        if (changes.made + changes.removed + changes.migrated > 0) log.debug("catalog: {d} made, {d} removed, {d} migrated", .{ changes.made, changes.removed, changes.migrated });
        return .{ .gpa = gpa, .project_dir = project_dir, .catalog = catalog };
    }

    /// Release the catalog and every cached child. No provider may be running: cancel and join
    /// the app's resource jobs first (`Queue.clear`), as they read through this.
    pub fn deinit(self: *ProjectAssets) void {
        self.forgetChildren();
        self.expanded.deinit(self.gpa);
        self.catalog.deinit();
    }

    fn acquire(self: *ProjectAssets) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn release(self: *ProjectAssets) void {
        self.lock.unlock();
    }

    fn forgetChildren(self: *ProjectAssets) void {
        var it = self.expanded.valueIterator();
        while (it.next()) |held| assets.subassets.free(self.gpa, held.*);
        self.expanded.clearRetainingCapacity();
        self.generation +%= 1;
    }

    /// Make the catalog match the files of `resources/` (new files get ids, gone files lose
    /// theirs) and forget the models' children, which may have changed with them.
    /// Editor-only: call after files change. The catalog is unchanged if it can't be written.
    ///
    /// ```zig
    /// const changes = try project_assets.sync();
    /// if (changes.any()) std.log.debug("assets changed", .{});
    /// ```
    pub fn sync(self: *ProjectAssets) !assets.catalog.Changes {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer project.close(io);
        self.acquire();
        defer self.release();
        self.forgetChildren();
        return self.catalog.sync(io, project);
    }

    /// Record that the files at `from` now live at `to` (after they moved), keeping their ids.
    /// A move the catalog can't follow (into or out of `resources/`) is caught up by `sync`
    /// instead; a failure is logged, and the files' ids are then settled by the next sync.
    ///
    /// ```zig
    /// try project.rename(from, project, to, io);
    /// project_assets.moved(from, to);
    /// ```
    pub fn moved(self: *ProjectAssets, from: []const u8, to: []const u8) void {
        self.follow(from, to, .move);
    }

    /// Record that `from` was copied to `to`: every copy is a new asset with new ids.
    pub fn copied(self: *ProjectAssets, from: []const u8, to: []const u8) void {
        self.follow(from, to, .copy);
    }

    fn follow(self: *ProjectAssets, from: []const u8, to: []const u8, how: enum { move, copy }) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = std.Io.Dir.cwd().openDir(io, self.project_dir, .{}) catch |err| return log.err("cannot open the project to update its assets: {t}", .{err});
        defer project.close(io);
        self.acquire();
        defer self.release();
        self.forgetChildren();
        const result = switch (how) {
            .move => self.catalog.move(io, project, from, to),
            .copy => self.catalog.copy(io, project, from, to),
        };
        result catch |err| {
            log.debug("catalog could not follow {s} to {s} ({t}): syncing instead", .{ from, to, err });
            _ = self.catalog.sync(io, project) catch |sync_err| log.err("cannot update the asset catalog: {t}", .{sync_err});
        };
    }

    /// The identity of the catalogued file or folder at `path`, if it has one.
    ///
    /// ```zig
    /// const id = project_assets.idOf("resources/ship.glb") orelse return;
    /// ```
    pub fn idOf(self: *ProjectAssets, path: []const u8) ?assets.Id {
        self.acquire();
        defer self.release();
        return if (self.catalog.view().findPath(path)) |entry| entry.id else null;
    }

    /// The key (see `Reference`) of the catalogued file at `path` in `buffer`, null without one.
    pub fn keyOf(self: *ProjectAssets, buffer: *[assets.id.key_len]u8, path: []const u8) ?[]const u8 {
        return assets.id.key(buffer, self.idOf(path) orelse return null);
    }

    /// What a field holds for the entry at `path`: a file's own identity, a model file's
    /// geometry child, or an expanded model's child by the virtual path the dock shows. Null for
    /// folders, files outside `resources/` and children not expanded. The name borrows `path`.
    ///
    /// ```zig
    /// const reference = project_assets.referenceAt("resources/ship.glb/Skeletal") orelse return;
    /// ```
    pub fn referenceAt(self: *ProjectAssets, path: []const u8) ?Reference {
        self.acquire();
        defer self.release();
        const name = std.fs.path.basename(path);
        if (self.catalog.view().findPath(path)) |entry| {
            if (entry.kind == .folder) return null;
            return if (entry.kind == .model) Reference.of(assets.id.model(entry.id), .model, name) else Reference.of(entry.id, entry.kind, name);
        }
        var it = self.expanded.iterator();
        while (it.next()) |found| for (found.value_ptr.*) |child| {
            if (!std.mem.eql(u8, child.path, path)) continue;
            return Reference.of(child.id, child.kind, if (child.kind == .model) std.fs.path.basename(std.fs.path.dirname(path) orelse path) else name);
        };
        return null;
    }

    /// A key as people read it, in `arena`: the path of the file or virtual child it names, else
    /// the key itself.
    ///
    /// ```zig
    /// const shown = project_assets.label(arena, key); // "resources/ship.glb/Walk"
    /// ```
    pub fn label(self: *ProjectAssets, arena: std.mem.Allocator, key: []const u8) []const u8 {
        const id = assets.id.parse(key) catch return key;
        self.acquire();
        defer self.release();
        if (self.catalog.view().findId(id)) |entry| return arena.dupe(u8, entry.path) catch key;
        for (self.catalog.view().entries) |entry| {
            if (entry.kind == .model and assets.id.model(entry.id) == id) return arena.dupe(u8, entry.path) catch key;
        }
        var it = self.expanded.valueIterator();
        while (it.next()) |held| for (held.*) |child| {
            if (child.id == id) return arena.dupe(u8, child.path) catch key;
        };
        return key;
    }

    /// The virtual children of the model file at `path` (geometry first, then one per clip), with
    /// paths in `arena`, importing the model the first time to learn its clips. A path that isn't
    /// a catalogued model has none. Import failures are logged and also give none.
    ///
    /// ```zig
    /// const children = try project_assets.children(arena, "resources/ship.glb");
    /// ```
    pub fn children(self: *ProjectAssets, arena: std.mem.Allocator, path: []const u8) ![]const assets.subassets.Child {
        const source = (try self.modelAt(path)) orelse return &.{};
        defer source.deinit(self.gpa);
        self.expand(source) catch |err| if (err != error.FilesChanged) log.err("cannot list what {s} holds: {t}", .{ path, err });
        self.acquire();
        defer self.release();
        const found = self.expanded.get(source.id) orelse return &.{};
        const copy = try arena.alloc(assets.subassets.Child, found.len);
        for (found, copy) |child, *out| {
            out.* = child;
            out.path = try arena.dupe(u8, child.path);
        }
        return copy;
    }

    /// The paths, in `arena`, of every catalogued file of `kind`.
    ///
    /// ```zig
    /// const scenes = try project_assets.pathsOfKind(arena, .scene);
    /// ```
    pub fn pathsOfKind(self: *ProjectAssets, arena: std.mem.Allocator, kind: assets.Kind) ![]const []const u8 {
        self.acquire();
        defer self.release();
        var found: std.ArrayList([]const u8) = .empty;
        for (self.catalog.view().entries) |entry| {
            if (entry.kind == kind and std.mem.startsWith(u8, entry.path, "resources/")) try found.append(arena, try arena.dupe(u8, entry.path));
        }
        return found.items;
    }

    fn modelAt(self: *ProjectAssets, path: []const u8) !?Source {
        self.acquire();
        defer self.release();
        const entry = self.catalog.view().findPath(path) orelse return null;
        if (entry.kind != .model) return null;
        return try self.own(entry);
    }

    fn own(self: *ProjectAssets, entry: *const assets.catalog.Entry) !Source {
        return .{ .id = entry.id, .path = try self.gpa.dupe(u8, entry.path), .settings = entry.model_import };
    }

    /// Import `source` to learn its children and remember them (none when it doesn't import).
    fn expand(self: *ProjectAssets, source: Source) !void {
        self.acquire();
        const known = self.expanded.contains(source.id);
        const started = self.generation;
        self.release();
        if (known) return;

        var failure: ?anyerror = null;
        const listed: []assets.subassets.Child = blk: {
            var imported = self.importModel(self.gpa, source) catch |err| {
                failure = err;
                break :blk &.{};
            };
            defer imported.deinit(self.gpa);
            break :blk assets.subassets.list(self.gpa, source.id, source.path, imported.rig.clips, imported.textures.len) catch |err| {
                failure = err;
                break :blk &.{};
            };
        };
        self.acquire();
        defer self.release();
        if (self.generation != started) {
            assets.subassets.free(self.gpa, listed);
            return error.FilesChanged;
        }
        const slot = self.expanded.getOrPut(self.gpa, source.id) catch |err| {
            assets.subassets.free(self.gpa, listed);
            return err;
        };
        if (slot.found_existing) return assets.subassets.free(self.gpa, listed);
        slot.value_ptr.* = listed;
        if (failure) |err| return err;
    }

    /// The model file that holds the child `id`, expanding model files until one does.
    fn holder(self: *ProjectAssets, id: assets.Id) !Source {
        while (true) {
            self.acquire();
            var it = self.expanded.iterator();
            while (it.next()) |found| for (found.value_ptr.*) |child| if (child.id == id) {
                defer self.release();
                const entry = self.catalog.view().findId(found.key_ptr.*) orelse return error.FileNotFound;
                return self.own(entry);
            };
            var next: ?Source = null;
            for (self.catalog.view().entries) |entry| {
                if (entry.kind != .model or self.expanded.contains(entry.id)) continue;
                next = self.own(&entry) catch |err| {
                    self.release();
                    return err;
                };
                break;
            }
            self.release();
            const source = next orelse return error.FileNotFound;
            defer source.deinit(self.gpa);
            self.expand(source) catch |err| if (err != error.FilesChanged) log.warn("cannot list what {s} holds: {t}", .{ source.path, err });
        }
    }

    /// The model file whose geometry child is `id`.
    fn geometryOf(self: *ProjectAssets, id: assets.Id) !?Source {
        self.acquire();
        defer self.release();
        for (self.catalog.view().entries) |*entry| {
            if (entry.kind == .model and assets.id.model(entry.id) == id) return try self.own(entry);
        }
        return null;
    }

    /// C-callable providers safe for a separately compiled game library.
    /// Editor-only: `self` and its project directory string must outlive every provider call.
    /// Reads/imports allocate caller-owned results with the allocator passed to the provider.
    /// Keys are asset identities; models and images are converted, so `read` refuses them.
    ///
    /// ```zig
    /// // Given a long-lived ProjectAssets named project_assets:
    /// const providers = project_assets.resources();
    /// _ = providers; // Pass to the editor's game/resource host.
    /// ```
    pub fn resources(self: *ProjectAssets) eggy.resources.Resources {
        return eggy.resources.Resources.from(self, readAsset, loadModel, loadImage);
    }

    /// Scene text by the scene file's identity: the provider scene instances read their files
    /// through. The borrowed provider retains `self`; reads are caller-owned and zero-terminated.
    ///
    /// ```zig
    /// // Given long-lived project_assets, allocator gpa, and a scene's key:
    /// const provider = project_assets.files();
    /// const source = try provider.read(provider.context, gpa, key);
    /// defer gpa.free(source);
    /// ```
    pub fn files(self: *ProjectAssets) eggy.scene_instances.Files {
        return .{ .context = self, .read = readAsset };
    }

    /// A loader for `eggy.model_cache.ModelCache`; `self` must outlive it.
    /// Editor-only: keys are a model's geometry identity. Models import like packaging does, so
    /// their clips are separate assets, and loaded storage belongs to the requesting allocator.
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
    /// Editor-only: decodes project images by identity; the requesting allocator/cache owns
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

    /// A loader for `eggy.shader_cache.ShaderCache`; `self` must outlive it.
    /// Editor-only: each `.slang` is made whole (`eggy.shader_compose`) and compiled to SPIR-V
    /// as it is first used; Slang's diagnostics are logged and the error returned.
    ///
    /// ```zig
    /// app.graphics.shaders.loader = project_assets.shaders();
    /// ```
    pub fn shaders(self: *ProjectAssets) eggy.shader_cache.Loader {
        return .{ .context = self, .load = loadShader };
    }

    fn loadShader(context: *anyopaque, gpa: std.mem.Allocator, key: []const u8) !eggy.shader_cache.Compiled {
        const self: *ProjectAssets = @ptrCast(@alignCast(context));
        const found = try self.fileOf(gpa, try assets.id.parse(key)) orelse return error.FileNotFound;
        defer gpa.free(found.path);
        if (found.kind != .shader) return error.WrongAssetKind;
        const source = try readAsset(context, gpa, key);
        defer gpa.free(source);
        const whole = try eggy.shader_compose.compose(gpa, source, std.fs.path.basename(found.path));
        defer gpa.free(whole);
        const role = try eggy.shader_compose.roleOf(source);
        return .{ .bytes = try eggy.slangc.compileSource(gpa, whole, eggy.shader_compose.Role.entry_point, .fragment, .spirv), .role = role };
    }

    fn readAsset(context: *anyopaque, gpa: std.mem.Allocator, key: []const u8) ![:0]u8 {
        const self: *ProjectAssets = @ptrCast(@alignCast(context));
        const id = try assets.id.parse(key);
        // A file: copied as it is, unless packaging converts it.
        if (try self.fileOf(gpa, id)) |found| {
            defer gpa.free(found.path);
            if (found.kind == .folder) return error.IsDir;
            if (assets.package.Conversion.of(found.path) != .copy) return error.ConvertedResource;
            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.io();
            var dir = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
            defer dir.close(io);
            return dir.readFileAllocOptions(io, found.path, gpa, .limited(64 << 20), .of(u8), 0);
        }
        // A model's geometry is converted; a clip is serialized as packaging does.
        if (try self.geometryOf(id)) |source| {
            source.deinit(self.gpa);
            return error.ConvertedResource;
        }
        return self.readClip(gpa, id);
    }

    const Found = struct { path: []u8, kind: assets.Kind };

    fn fileOf(self: *ProjectAssets, gpa: std.mem.Allocator, id: assets.Id) !?Found {
        self.acquire();
        defer self.release();
        const entry = self.catalog.view().findId(id) orelse return null;
        return .{ .path = try gpa.dupe(u8, entry.path), .kind = entry.kind };
    }

    /// The imported clip `id` as the bytes packaging installs: the clip, and the geometry it moves.
    fn readClip(self: *ProjectAssets, gpa: std.mem.Allocator, id: assets.Id) ![:0]u8 {
        const source = try self.holder(id);
        defer source.deinit(self.gpa);
        var imported = try self.importModel(gpa, source);
        defer imported.deinit(gpa);
        // The file may have changed since it was expanded: find the clip by identity again.
        const listed = try assets.subassets.list(gpa, source.id, source.path, imported.rig.clips, imported.textures.len);
        defer assets.subassets.free(gpa, listed);
        const index = for (listed) |child| {
            if (child.id == id) break child.clip_index orelse return error.ConvertedResource;
        } else return error.FileNotFound;
        var bytes: std.Io.Writer.Allocating = .init(gpa);
        defer bytes.deinit();
        try assets.imported_clip.write(&bytes.writer, .{ .source_model = assets.id.model(source.id), .clip = imported.rig.clips[index] });
        return gpa.dupeSentinel(u8, bytes.written(), 0);
    }

    fn loadModel(context: *anyopaque, gpa: std.mem.Allocator, key: []const u8) !assets.Model {
        const self: *ProjectAssets = @ptrCast(@alignCast(context));
        // A tilemap is drawn as the model its tiles make.
        if (try self.fileOf(gpa, try assets.id.parse(key))) |found| {
            defer gpa.free(found.path);
            if (found.kind == .tilemap) {
                const text = try readAsset(context, gpa, key);
                defer gpa.free(text);
                const map = try assets.tilemap.parse(gpa, text);
                defer map.deinit(gpa);
                return map.buildModel(gpa);
            }
        }
        const source = (try self.geometryOf(try assets.id.parse(key))) orelse return error.FileNotFound;
        defer source.deinit(self.gpa);
        var imported = try self.importModel(gpa, source);
        // Clips are assets of their own, as in the packaged model.
        var clips: assets.model.Rig = .{ .clips = imported.rig.clips };
        clips.deinit(gpa);
        imported.rig.clips = &.{};
        return imported;
    }

    /// The texture child `id` of a model, imported again; the caller owns it.
    pub fn modelTexture(self: *ProjectAssets, gpa: std.mem.Allocator, id: assets.Id) !assets.Texture {
        const source = try self.holder(id);
        defer source.deinit(self.gpa);
        var imported = try self.importModel(gpa, source);
        defer imported.deinit(gpa);
        // The file may have changed since it was expanded: find the texture by identity again.
        const listed = try assets.subassets.list(gpa, source.id, source.path, imported.rig.clips, imported.textures.len);
        defer assets.subassets.free(gpa, listed);
        const index = for (listed) |child| {
            if (child.id == id) break child.texture_index orelse return error.UnsupportedImageFormat;
        } else return error.FileNotFound;
        // Hand this one over, leaving an empty texture for `deinit` to free.
        const texture = imported.textures[index];
        imported.textures[index] = .{ .width = 0, .height = 0, .pixels = &.{} };
        return texture;
    }

    fn importModel(self: *ProjectAssets, gpa: std.mem.Allocator, source: Source) !assets.Model {
        const full_path = try std.fs.path.joinZ(gpa, &.{ self.project_dir, source.path });
        defer gpa.free(full_path);
        return model_import.import(gpa, full_path, source.settings) catch |err| {
            log.err("cannot import {s}: {s} ({t})", .{ source.path, model_import.lastError(), err });
            return err;
        };
    }

    fn loadImage(context: *anyopaque, gpa: std.mem.Allocator, key: []const u8) !assets.Texture {
        const self: *ProjectAssets = @ptrCast(@alignCast(context));
        const id = try assets.id.parse(key);
        const found = (try self.fileOf(gpa, id)) orelse return self.modelTexture(gpa, id);
        defer gpa.free(found.path);
        if (assets.package.Conversion.of(found.path) != .texture) return error.UnsupportedImageFormat;
        const full_path = try std.fs.path.joinZ(gpa, &.{ self.project_dir, found.path });
        defer gpa.free(full_path);
        return model_import.decodeImage(gpa, full_path) catch |err| {
            log.err("cannot read the image {s}: {s} ({t})", .{ found.path, model_import.lastError(), err });
            return err;
        };
    }
};

test "a model opens into its geometry and clips, whose ids survive a move but not a copy" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try fixtures.Fixture.open(gpa, io);
    defer fixture.close(gpa, io);
    try fixture.dir.createDirPath(io, "resources");
    try fixture.dir.writeFile(io, .{ .sub_path = "resources/face.gltf", .data = fixtures.smiling_triangle });
    var project = try ProjectAssets.init(gpa, io, fixture.path);
    defer project.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A model with a clip opens into a Skeletal model and the clip, both without files.
    const opened = try project.children(arena, "resources/face.gltf");
    try std.testing.expectEqual(@as(usize, 2), opened.len);
    try std.testing.expectEqualStrings("resources/face.gltf/Skeletal", opened[0].path);
    try std.testing.expectEqualStrings("resources/face.gltf/smile", opened[1].path);
    const skeleton = project.referenceAt("resources/face.gltf/Skeletal").?;
    try std.testing.expectEqual(assets.Kind.model, skeleton.kind);
    const smile = project.referenceAt("resources/face.gltf/smile").?;
    try std.testing.expectEqual(assets.Kind.animation, smile.kind);
    try std.testing.expectEqualStrings("resources/face.gltf/smile", project.label(arena, smile.key()));

    // The clip reads as an imported clip that fits only its own geometry, which carries no clips.
    const bytes = try project.readClip(gpa, try assets.id.parse(smile.key()));
    defer gpa.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var file = try assets.imported_clip.read(gpa, &reader);
    defer file.deinit(gpa);
    try std.testing.expectEqualStrings("smile", file.clip.name);
    var geometry = try ProjectAssets.loadModel(&project, gpa, skeleton.key());
    defer geometry.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), geometry.rig.clips.len);
    try file.validateFor(try assets.id.parse(skeleton.key()), geometry);
    try std.testing.expectError(error.IncompatibleAnimationModel, file.validateFor(7, geometry));
    try std.testing.expectError(error.ConvertedResource, ProjectAssets.readAsset(&project, gpa, skeleton.key()));

    // A move keeps the file's, geometry's and clip's ids; a copy makes new ones.
    try fixture.dir.rename("resources/face.gltf", fixture.dir, "resources/head.gltf", io);
    project.moved("resources/face.gltf", "resources/head.gltf");
    const moved = try project.children(arena, "resources/head.gltf");
    try std.testing.expectEqual(opened[0].id, moved[0].id);
    try std.testing.expectEqual(opened[1].id, moved[1].id);
    try fixture.dir.copyFile("resources/head.gltf", fixture.dir, "resources/copy.gltf", io, .{});
    project.copied("resources/head.gltf", "resources/copy.gltf");
    const copied = try project.children(arena, "resources/copy.gltf");
    try std.testing.expect(copied[0].id != moved[0].id and copied[1].id != moved[1].id);
}

test "a file's key is its catalogued identity, and folders have none" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try fixtures.Fixture.open(gpa, io);
    defer fixture.close(gpa, io);
    try fixture.dir.createDirPath(io, "resources/art");
    try fixture.dir.writeFile(io, .{ .sub_path = "resources/art/note.txt", .data = "hi" });
    var project = try ProjectAssets.init(gpa, io, fixture.path);
    defer project.deinit();

    var buffer: [assets.id.key_len]u8 = undefined;
    const key = project.keyOf(&buffer, "resources/art/note.txt").?;
    try std.testing.expectEqual(project.idOf("resources/art/note.txt").?, try assets.id.parse(key));
    try std.testing.expect(project.referenceAt("resources/art") == null);
    try std.testing.expect(project.keyOf(&buffer, "resources/missing.txt") == null);
    const text = try ProjectAssets.readAsset(&project, gpa, key);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("hi", text);
}

test "providers read on other threads while files move and the catalog syncs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try fixtures.Fixture.open(gpa, io);
    defer fixture.close(gpa, io);
    try fixture.dir.createDirPath(io, "resources");
    try fixture.dir.writeFile(io, .{ .sub_path = "resources/face.gltf", .data = fixtures.smiling_triangle });
    try fixture.dir.writeFile(io, .{ .sub_path = "resources/note.txt", .data = "hello" });
    var project = try ProjectAssets.init(gpa, io, fixture.path);
    defer project.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const smile = (try project.children(arena, "resources/face.gltf"))[1];
    var note_key: [assets.id.key_len]u8 = undefined;
    _ = project.keyOf(&note_key, "resources/note.txt").?;
    var clip_key: [assets.id.key_len]u8 = undefined;
    _ = assets.id.key(&clip_key, smile.id);

    const Reader = struct {
        fn run(owner: *ProjectAssets, key: []const u8, done: *std.atomic.Value(bool), wrong: *std.atomic.Value(u32)) void {
            while (!done.load(.acquire)) {
                const bytes = ProjectAssets.readAsset(owner, std.heap.page_allocator, key) catch |err| {
                    // A file caught mid-move is the only failure a reader may see.
                    if (err != error.FileNotFound) _ = wrong.fetchAdd(1, .monotonic);
                    continue;
                };
                std.heap.page_allocator.free(bytes);
            }
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    var wrong: std.atomic.Value(u32) = .init(0);
    const note_reader = try std.Thread.spawn(.{}, Reader.run, .{ &project, @as([]const u8, &note_key), &done, &wrong });
    const clip_reader = try std.Thread.spawn(.{}, Reader.run, .{ &project, @as([]const u8, &clip_key), &done, &wrong });

    // Move the files back and forth, and sync, as the editor does while jobs run.
    for (0..20) |round| {
        const note_from: []const u8 = if (round % 2 == 0) "resources/note.txt" else "resources/memo.txt";
        const note_to: []const u8 = if (round % 2 == 0) "resources/memo.txt" else "resources/note.txt";
        try fixture.dir.rename(note_from, fixture.dir, note_to, io);
        project.moved(note_from, note_to);
        _ = try project.sync();
        _ = try project.children(arena, "resources/face.gltf");
    }
    done.store(true, .release);
    note_reader.join();
    clip_reader.join();
    try std.testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
    try std.testing.expectEqualStrings(&note_key, project.keyOf(&note_key, "resources/note.txt").?);
}

test "composed post and surface shaders compile with Slang" {
    const compose = eggy.shader_compose;
    const slangc = eggy.slangc;
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{
        \\#include "eggy.slang"
        \\float4 post(PostInput input) {
        \\    float3 color = sceneColor(input.uv);
        \\    return float4(lerp(color, luminance(color).xxx, input.values.x), 1.0);
        \\}
        ,
        \\#include "eggy.slang"
        \\Surface surface(SurfaceInput input) {
        \\    Surface shown = defaultSurface(input);
        \\    shown.emissive += shown.base_color * (0.5 + 0.5 * sin(input.time_s));
        \\    return shown;
        \\}
        ,
    };
    for (sources) |source| {
        const whole = try compose.compose(gpa, source, "test.slang");
        defer gpa.free(whole);
        const spirv = slangc.compileSource(gpa, whole, compose.Role.entry_point, .fragment, .spirv) catch |err| switch (err) {
            error.ShaderCompilerUnavailable => return error.SkipZigTest,
            else => return err,
        };
        defer gpa.free(spirv);
        try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, spirv[0..4]);
    }
}
