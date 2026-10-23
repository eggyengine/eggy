//! The project's open scene on disk (see `eggy.scene`). The editor reopens the scene that was
//! open last, which `.eggy/scene.zon` remembers; with none, the world starts empty until one is
//! opened from the Assets panel. File > Save writes the open scene, or a new one when none is.
const std = @import("std");
const zon_file = @import("eggy").assets.zon;
const eggy = @import("eggy");
const log = std.log.scoped(.scene);

/// Where the open scene is remembered, relative to the project.
const memory_path = ".eggy" ++ std.fs.path.sep_str ++ "scene.zon";
/// Where new scenes go, relative to the project.
const scenes_dir = eggy.project.scenes_dir;
pub const extension = ".scene.zon";

/// The scene open in the editor, if any: its path relative to the project. Owned.
pub const OpenScene = struct {
    gpa: std.mem.Allocator,
    project_dir: []const u8,
    path: ?[]u8 = null,
    /// A hash of the world as last saved or opened, to tell when it has changed since.
    saved_hash: ?u64 = null,

    /// Free the editor's owned scene path, not the borrowed project folder or world.
    /// Does not save changes; the value must not be reused without reinitializing it.
    ///
    /// ```zig
    /// var open_scene = OpenScene{ .gpa = gpa, .project_dir = project_dir };
    /// defer open_scene.deinit();
    /// ```
    pub fn deinit(self: *OpenScene) void {
        if (self.path) |path| self.gpa.free(path);
    }

    /// Its file name, for the status bar; null with none open.
    /// Returns a borrowed basename valid until the open path changes or this state is destroyed.
    ///
    /// ```zig
    /// if (open_scene.name()) |name| context.text(name);
    /// ```
    pub fn name(self: *const OpenScene) ?[]const u8 {
        return std.fs.path.basename(self.path orelse return null);
    }

    /// Reopen the scene that was open last into `world`, if it still exists.
    /// Editor startup helper; `access` must match this world's game's component registry.
    /// Missing/invalid memory is ignored; open failures log. A successful open replaces entities.
    ///
    /// ```zig
    /// open_scene.reopen(&app.world, game.sceneAccess());
    /// // Start editor-mode plugins after restoring the remembered scene.
    /// ```
    pub fn reopen(self: *OpenScene, world: *eggy.ecs.World, access: eggy.scene.Access) void {
        const remembered = self.readMemory() orelse return;
        defer self.gpa.free(remembered);
        self.open(remembered, world, access) catch |err| log.err("cannot reopen {s}: {t}", .{ remembered, err });
    }

    /// Replace `world`'s entities with the scene at `path` (relative to the project), and
    /// remember it as the open one.
    /// Borrows `path`; `access` must match the loaded game/world. Rejects unsafe lexical paths
    /// with `BadPathName`; read/parse/allocation/instantiate errors propagate. Parsing occurs
    /// before clearing, but later failures may leave a changed/partial world; the host should
    /// snapshot history first. Scene-memory write failures log rather than abort.
    ///
    /// ```zig
    /// // Host has already dealt with unsaved changes and captured undo state.
    /// try open_scene.open("resources/scene/main.scene.zon", &app.world, game.sceneAccess());
    /// ```
    pub fn open(self: *OpenScene, path: []const u8, world: *eggy.ecs.World, access: eggy.scene.Access) !void {
        if (!isProjectPath(path)) return error.BadPathName;
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer project.close(io);
        const source = try project.readFileAllocOptions(io, path, self.gpa, .limited(64 << 20), .of(u8), 0);
        defer self.gpa.free(source);
        var scene = try eggy.scene.Scene.parse(self.gpa, source);
        defer scene.deinit();

        world.clear();
        const made = try scene.instantiate(self.gpa, world, access, null);
        defer self.gpa.free(made.entities);
        if (made.skipped > 0) log.warn("opened {s}: {d} entities, {d} components or fields left out (see above)", .{ path, made.entities.len, made.skipped }) else log.info("opened {s}: {d} entities", .{ path, made.entities.len });
        try self.setPath(path);
        self.saved_hash = hashOf(self.gpa, world, access) catch null;
    }

    /// Whether `world` has changes not saved to the open scene: it differs from what was last
    /// saved or opened, or (with no scene open) it has entities at all.
    /// Captures/serializes with the matching game registry; allocation failures return false.
    /// Does not write or modify the world; the hash comparison uses top-level ID order.
    ///
    /// ```zig
    /// const dirty = open_scene.unsaved(&app.world, game.sceneAccess());
    /// _ = dirty; // Host shows the status-bar asterisk.
    /// ```
    pub fn unsaved(self: *const OpenScene, world: *eggy.ecs.World, access: eggy.scene.Access) bool {
        const now = hashOf(self.gpa, world, access) catch return false;
        return self.unsavedHash(now, world);
    }

    /// `unsaved`, for the world whose scene text hashes (Wyhash, seed 0) to `hash`.
    /// Caller must supply the same serialization hash used by save/open.
    /// Without a saved hash, checks only whether the borrowed world has any entities.
    ///
    /// ```zig
    /// const dirty = open_scene.unsavedHash(std.hash.Wyhash.hash(0, scene_text), &app.world);
    /// _ = dirty;
    /// ```
    pub fn unsavedHash(self: *const OpenScene, hash: u64, world: *eggy.ecs.World) bool {
        const saved = self.saved_hash orelse return world.entityCount() > 0;
        return hash != saved;
    }

    /// Write `world`, from its top-level entities `roots` in order, to the open scene; with none
    /// open, to a new one in `resources/scene/`, which becomes the open one.
    /// `access` must match `world`; null roots uses the capture's default ordering.
    /// Writes the project file, creating parent folders, and updates the saved hash on success.
    /// I/O/capture/allocation errors propagate; a fresh path may already be selected on failure.
    ///
    /// ```zig
    /// try open_scene.save(&app.world, game.sceneAccess(), root_ids);
    /// // null instead of root_ids captures with the registry's default root ordering.
    /// ```
    pub fn save(self: *OpenScene, world: *eggy.ecs.World, access: eggy.scene.Access, roots: ?[]const eggy.ecs.EntityId) !void {
        if (self.path == null) {
            const fresh = try self.freshPath();
            defer self.gpa.free(fresh);
            try self.setPath(fresh);
        }
        const path = self.path.?;
        var scene = try eggy.scene.Scene.capture(self.gpa, world, access, roots);
        defer scene.deinit();
        var text: std.Io.Writer.Allocating = .init(self.gpa);
        defer text.deinit();
        try scene.write(&text.writer);

        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer project.close(io);
        if (std.fs.path.dirname(path)) |parent| try project.createDirPath(io, parent);
        try project.writeFile(io, .{ .sub_path = path, .data = text.written() });
        self.saved_hash = std.hash.Wyhash.hash(0, text.written());
        log.info("saved {d} entities to {s}", .{ scene.entities.len, path });
    }

    /// Start a new, empty scene in `folder` (relative to the project; "" for the project
    /// itself), written at once, and open it: `world` empties.
    /// Rejects non-project folder paths; capture/allocation/I/O failures propagate.
    /// Clearing happens before file creation, so the host must capture undo/confirm leaving
    /// first. Borrows the folder and matching component access only during this call.
    ///
    /// ```zig
    /// // Host already captured the previous world for an open_scene history step.
    /// try open_scene.create(eggy.project.scenes_dir, &app.world, game.sceneAccess());
    /// ```
    pub fn create(self: *OpenScene, folder: []const u8, world: *eggy.ecs.World, access: eggy.scene.Access) !void {
        if (folder.len > 0 and !isProjectPath(folder)) return error.BadPathName;
        world.clear();
        const fresh = try self.freshPathIn(folder);
        defer self.gpa.free(fresh);
        try self.setPath(fresh);
        try self.save(world, access, null);
    }

    /// Make `path` (none: no scene) the open scene again, its file holding what hashes to
    /// `saved_hash`, as undoing or redoing opening a scene does; the world is the caller's.
    /// Copies a non-null path with `self.gpa` and attempts to remember it on disk;
    /// allocation errors propagate. Accepts trusted history paths without validation and does
    /// not load/save scene contents; the host restores the world separately.
    ///
    /// ```zig
    /// // After restoring the corresponding world's history snapshot:
    /// try open_scene.reopenAs(previous_path, previous_saved_hash);
    /// ```
    pub fn reopenAs(self: *OpenScene, path: ?[]const u8, saved_hash: ?u64) !void {
        if (path) |chosen| try self.setPath(chosen) else if (self.path) |old| {
            self.gpa.free(old);
            self.path = null;
        }
        self.saved_hash = saved_hash;
    }

    fn setPath(self: *OpenScene, path: []const u8) !void {
        const copy = try self.gpa.dupe(u8, path);
        if (self.path) |old| self.gpa.free(old);
        self.path = copy;
        self.writeMemory() catch |err| log.warn("cannot remember the open scene: {t}", .{err});
    }

    /// The open scene's file moved from `from` to `to` (or a folder holding it did): follow it.
    /// Paths are trusted project-relative asset paths, borrowed for this call.
    /// Updates/copies the matching path and scene memory; allocation/write failures are ignored
    /// or logged. It does not move files or change the world's saved hash.
    ///
    /// ```zig
    /// open_scene.moved("resources/scene", "resources/levels"); // After the actual rename.
    /// ```
    pub fn moved(self: *OpenScene, from: []const u8, to: []const u8) void {
        const path = self.path orelse return;
        if (!std.mem.startsWith(u8, path, from)) return;
        const rest = path[from.len..];
        if (rest.len > 0 and rest[0] != '/' and rest[0] != std.fs.path.sep) return;
        const updated = std.fmt.allocPrint(self.gpa, "{s}{s}", .{ to, rest }) catch return;
        defer self.gpa.free(updated);
        self.setPath(updated) catch {};
    }

    /// The open scene's file (or a folder holding it) was deleted: it stays in the world, unsaved,
    /// with no scene open.
    /// Borrows a project-relative file/folder path and clears matching path/hash state only.
    /// Does not delete files, clear the world, or rewrite remembered scene memory.
    ///
    /// ```zig
    /// open_scene.deleted("resources/scene/main.scene.zon"); // After moving it to trash.
    /// ```
    pub fn deleted(self: *OpenScene, path: []const u8) void {
        const current_path = self.path orelse return;
        if (!std.mem.startsWith(u8, current_path, path)) return;
        const rest = current_path[path.len..];
        if (rest.len > 0 and rest[0] != '/' and rest[0] != std.fs.path.sep) return;
        self.gpa.free(current_path);
        self.path = null;
        self.saved_hash = null;
    }

    /// `untitled.scene.zon` in the scenes folder, or `untitled-2` and so on when that is taken.
    /// Caller-owned.
    fn freshPath(self: *const OpenScene) ![]u8 {
        return self.freshPathIn(scenes_dir);
    }

    /// `untitled.scene.zon` in `folder`, or `untitled-2` and so on. Caller-owned.
    fn freshPathIn(self: *const OpenScene, folder: []const u8) ![]u8 {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer project.close(io);
        var n: usize = 1;
        while (true) : (n += 1) {
            const separator: []const u8 = if (folder.len > 0) "/" else "";
            const path = if (n == 1)
                try std.fmt.allocPrint(self.gpa, "{s}{s}untitled{s}", .{ folder, separator, extension })
            else
                try std.fmt.allocPrint(self.gpa, "{s}{s}untitled-{d}{s}", .{ folder, separator, n, extension });
            project.access(io, path, .{}) catch return path;
            self.gpa.free(path);
        }
    }

    fn readMemory(self: *const OpenScene) ?[]u8 {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = std.Io.Dir.cwd().openDir(io, self.project_dir, .{}) catch return null;
        defer project.close(io);
        const source = project.readFileAllocOptions(io, memory_path, self.gpa, .limited(4096), .of(u8), 0) catch return null;
        defer self.gpa.free(source);
        const Memory = struct { scene: []const u8 };
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const memory = zon_file.parse(Memory, arena.allocator(), source, .{ .ignore_unknown_fields = true }) catch return null;
        if (!isProjectPath(memory.scene)) return null;
        project.access(io, memory.scene, .{}) catch return null;
        return self.gpa.dupe(u8, memory.scene) catch null;
    }

    fn writeMemory(self: *const OpenScene) !void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer project.close(io);
        try project.createDirPath(io, ".eggy");
        const text = try std.fmt.allocPrint(self.gpa, "// The scene the editor has open, reopened when it starts.\n.{{ .scene = \"{f}\" }}\n", .{std.zig.fmtString(self.path.?)});
        defer self.gpa.free(text);
        try project.writeFile(io, .{ .sub_path = memory_path, .data = text });
    }
};

/// A hash of `world` as a scene file would hold it, its top-level entities in id order (as a
/// world just loaded has them).
fn hashOf(gpa: std.mem.Allocator, world: *eggy.ecs.World, access: eggy.scene.Access) !u64 {
    var scene = try eggy.scene.Scene.capture(gpa, world, access, null);
    defer scene.deinit();
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try scene.write(&text.writer);
    return std.hash.Wyhash.hash(0, text.written());
}

/// Whether `path` stays inside the project: relative, with no `..`.
/// Pure lexical check for editor asset paths; empty/absolute paths are rejected and either
/// slash is recognized. Does not resolve symlinks or guarantee filesystem containment.
///
/// ```zig
/// std.debug.assert(scene_file.isProjectPath("resources/scene/main.scene.zon"));
/// std.debug.assert(!scene_file.isProjectPath("../main.scene.zon"));
/// ```
pub fn isProjectPath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

test "scene paths stay inside the project" {
    try std.testing.expect(isProjectPath("scenes/main.scene.zon"));
    try std.testing.expect(!isProjectPath("../elsewhere.scene.zon"));
    try std.testing.expect(!isProjectPath("scenes/../../x.scene.zon"));
    try std.testing.expect(!isProjectPath("/etc/passwd"));
}

test "a saved scene is remembered, and a new one gets a free name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const access = eggy.scene.registryAccess(eggy.components.Registry(&.{}, &.{}));
    var world = eggy.ecs.World.init(gpa);
    defer world.deinit();

    var first = OpenScene{ .gpa = gpa, .project_dir = dir };
    defer first.deinit();
    try std.testing.expect(first.readMemory() == null);
    const named = try world.spawn(.{});
    access.setName(&world, named, "Sun");
    try std.testing.expect(first.unsaved(&world, access)); // an entity, and nowhere saved
    try first.save(&world, access, null);
    try std.testing.expectEqualStrings("untitled.scene.zon", first.name().?);
    try std.testing.expect(!first.unsaved(&world, access));
    access.setName(&world, named, "Sol");
    try std.testing.expect(first.unsaved(&world, access));
    try first.create(eggy.project.scenes_dir, &world, access);
    try std.testing.expectEqualStrings("untitled-2.scene.zon", first.name().?);

    // A later editor reopens the last one, and opening the first brings its entity back.
    var second = OpenScene{ .gpa = gpa, .project_dir = dir };
    defer second.deinit();
    second.reopen(&world, access);
    try std.testing.expectEqualStrings("untitled-2.scene.zon", second.name().?);
    try second.open(eggy.project.scenes_dir ++ "/untitled.scene.zon", &world, access);
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());
}
