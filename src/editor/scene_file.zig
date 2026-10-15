//! The project's open scene on disk (see `eggy.scene`). The editor reopens the scene that was
//! open last, which `.eggy/scene.zon` remembers; with none, the world starts empty until one is
//! opened from the Assets panel. File > Save writes the open scene, or a new one when none is.
const std = @import("std");
const eggy = @import("eggy");
const log = std.log.scoped(.scene);

/// Where the open scene is remembered, relative to the project.
const memory_path = ".eggy" ++ std.fs.path.sep_str ++ "scene.zon";
/// Where new scenes go, relative to the project.
const scenes_dir = "scenes";
pub const extension = ".scene.zon";

/// The scene open in the editor, if any: its path relative to the project. Owned.
pub const OpenScene = struct {
    gpa: std.mem.Allocator,
    project_dir: []const u8,
    path: ?[]u8 = null,
    /// A hash of the world as last saved or opened, to tell when it has changed since.
    saved_hash: ?u64 = null,

    pub fn deinit(self: *OpenScene) void {
        if (self.path) |path| self.gpa.free(path);
    }

    /// Its file name, for the status bar; null with none open.
    pub fn name(self: *const OpenScene) ?[]const u8 {
        return std.fs.path.basename(self.path orelse return null);
    }

    /// Reopen the scene that was open last into `world`, if it still exists.
    pub fn reopen(self: *OpenScene, world: *eggy.ecs.World, access: eggy.scene.Access) void {
        const remembered = self.readMemory() orelse return;
        defer self.gpa.free(remembered);
        self.open(remembered, world, access) catch |err| log.err("cannot reopen {s}: {t}", .{ remembered, err });
    }

    /// Replace `world`'s entities with the scene at `path` (relative to the project), and
    /// remember it as the open one.
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
    pub fn unsaved(self: *const OpenScene, world: *eggy.ecs.World, access: eggy.scene.Access) bool {
        const now = hashOf(self.gpa, world, access) catch return false;
        return self.unsavedHash(now, world);
    }

    /// `unsaved`, for the world whose scene text hashes (Wyhash, seed 0) to `hash`.
    pub fn unsavedHash(self: *const OpenScene, hash: u64, world: *eggy.ecs.World) bool {
        const saved = self.saved_hash orelse return world.entityCount() > 0;
        return hash != saved;
    }

    /// Write `world`, from its top-level entities `roots` in order, to the open scene; with none
    /// open, to a new one in `scenes/`, which becomes the open one.
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
    pub fn create(self: *OpenScene, folder: []const u8, world: *eggy.ecs.World, access: eggy.scene.Access) !void {
        if (folder.len > 0 and !isProjectPath(folder)) return error.BadPathName;
        world.clear();
        const fresh = try self.freshPathIn(folder);
        defer self.gpa.free(fresh);
        try self.setPath(fresh);
        try self.save(world, access, null);
    }

    fn setPath(self: *OpenScene, path: []const u8) !void {
        const copy = try self.gpa.dupe(u8, path);
        if (self.path) |old| self.gpa.free(old);
        self.path = copy;
        self.writeMemory() catch |err| log.warn("cannot remember the open scene: {t}", .{err});
    }

    /// The open scene's file moved from `from` to `to` (or a folder holding it did): follow it.
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
    pub fn deleted(self: *OpenScene, path: []const u8) void {
        const current_path = self.path orelse return;
        if (!std.mem.startsWith(u8, current_path, path)) return;
        const rest = current_path[path.len..];
        if (rest.len > 0 and rest[0] != '/' and rest[0] != std.fs.path.sep) return;
        self.gpa.free(current_path);
        self.path = null;
        self.saved_hash = null;
    }

    /// `scenes/untitled.scene.zon`, or `untitled-2` and so on when that is taken. Caller-owned.
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
        const memory = std.zon.parse.fromSliceAlloc(Memory, arena.allocator(), source, null, .{ .ignore_unknown_fields = true }) catch return null;
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
    try first.create("scenes", &world, access);
    try std.testing.expectEqualStrings("untitled-2.scene.zon", first.name().?);

    // A later editor reopens the last one, and opening the first brings its entity back.
    var second = OpenScene{ .gpa = gpa, .project_dir = dir };
    defer second.deinit();
    second.reopen(&world, access);
    try std.testing.expectEqualStrings("untitled-2.scene.zon", second.name().?);
    try second.open("scenes" ++ std.fs.path.sep_str ++ "untitled.scene.zon", &world, access);
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());
}
