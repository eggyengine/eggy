//! The entities each `SceneInstance` stands for, made in the world under it from its scene file
//! (see `scene_instance.zig`), in the editor and the runtime alike. They are made again when the instance's file is picked or
//! changes, after the world is rebuilt (they aren't saved, so a scene opened, undone or carried
//! across a reload comes back without them), and once files change on disk; they go when the
//! instance does, or loses the component. An instance inside its own scene, however deep, is
//! left empty rather than made forever.
const std = @import("std");
const ecs = @import("clutch");
const components = @import("components.zig");
const scene_zig = @import("scene.zig");
const scene_instance = @import("scene_instance.zig");
const refs = @import("refs.zig");
const log = std.log.scoped(.scene_instances);

/// Where scene files come from, by their paths in the project: the project's folder in the
/// editor (`FolderFiles`), what packaging made of them in the runtime.
pub const Files = struct {
    context: *anyopaque,
    /// The file at `path`, allocated with `gpa`.
    read: *const fn (context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![:0]u8,
};

/// `Files` from a folder: paths are relative to it.
pub const FolderFiles = struct {
    io: std.Io,
    dir: std.Io.Dir,

    pub fn files(self: *FolderFiles) Files {
        return .{ .context = self, .read = read };
    }

    fn read(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![:0]u8 {
        const self: *FolderFiles = @ptrCast(@alignCast(context));
        return self.dir.readFileAllocOptions(self.io, path, gpa, .limited(64 << 20), .of(u8), 0);
    }
};

pub const SceneInstances = struct {
    gpa: std.mem.Allocator,
    /// By the instance's entity id: what was made under it.
    made: std.AutoHashMapUnmanaged(u32, Made) = .empty,

    const Made = struct {
        generation: u32,
        /// The scene file it was made from, owned.
        path: []u8,
        /// The scene's top-level entities, made under the instance; owned.
        roots: []ecs.EntityId,
        /// Its file may have changed: make it again.
        stale: bool = false,
    };

    pub fn init(gpa: std.mem.Allocator) SceneInstances {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *SceneInstances) void {
        var it = self.made.valueIterator();
        while (it.next()) |made| self.free(made.*);
        self.made.deinit(self.gpa);
    }

    /// Make every instance's entities again on the next `sync`, as their files may have changed.
    pub fn remakeAll(self: *SceneInstances) void {
        var it = self.made.valueIterator();
        while (it.next()) |made| made.stale = true;
    }

    /// Bring each instance in `world` up to date: make the entities of one whose file is new,
    /// changed or whose entities are gone, from the scene files in `files`, and take away
    /// those of instances that are gone. `open_scene` (the scene being edited, relative to the
    /// project) is never made inside itself.
    pub fn sync(self: *SceneInstances, files: Files, world: *ecs.World, access: scene_zig.Access, open_scene: ?[]const u8) void {
        const component = scene_instance.typeIndex(access.types()) orelse return;
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(self.gpa);

        // Only the entities there now: those made here are synced on the next call.
        const count = world.slots.items.len;
        for (0..count) |i| {
            const slot = world.slots.items[i];
            if (!slot.alive) continue;
            const entity = ecs.EntityId.init(@intCast(i), slot.generation);
            if (!access.has(world, entity, component)) continue;
            seen.put(self.gpa, entity.id, {}) catch return;
            var zon_buffer: [refs.max_path_len + 8]u8 = undefined;
            var path_buffer: [refs.max_path_len + 8]u8 = undefined;
            const path = scenePath(access.readField(world, entity, component, 0, &zon_buffer) orelse continue, &path_buffer) orelse continue;
            if (self.made.get(entity.id)) |made| {
                if (made.generation == entity.generation and !made.stale and std.mem.eql(u8, made.path, path) and allUnder(world, made.roots, entity)) continue;
                self.unmake(world, entity.id);
            }
            self.make(files, world, access, entity, path, open_scene);
        }

        // Instances gone, or no longer instances: their entities go too.
        var gone: std.ArrayList(u32) = .empty;
        defer gone.deinit(self.gpa);
        var keys = self.made.keyIterator();
        while (keys.next()) |id| if (!seen.contains(id.*)) gone.append(self.gpa, id.*) catch return;
        for (gone.items) |id| self.unmake(world, id);
    }

    /// Make the scene at `path` under `instance`, and remember what was made (nothing, if it
    /// can't be, so it isn't tried again every frame).
    fn make(self: *SceneInstances, files: Files, world: *ecs.World, access: scene_zig.Access, instance: ecs.EntityId, path: []const u8, open_scene: ?[]const u8) void {
        const owned_path = self.gpa.dupe(u8, path) catch return;
        var roots: []ecs.EntityId = &.{};
        if (path.len > 0) if (self.isInsideItself(world, instance, path, open_scene)) {
            log.warn("{s} is instanced inside itself: that instance is left empty", .{path});
        } else {
            roots = self.instantiate(files, world, access, instance, path) catch |err| blk: {
                log.err("cannot make the entities of {s}: {t}", .{ path, err });
                break :blk &.{};
            };
        };
        self.made.put(self.gpa, instance.id, .{ .generation = instance.generation, .path = owned_path, .roots = roots }) catch {
            self.gpa.free(owned_path);
            self.gpa.free(roots);
        };
    }

    /// The scene at `path` read and made under `instance`; its top-level entities, caller-owned.
    fn instantiate(self: *SceneInstances, files: Files, world: *ecs.World, access: scene_zig.Access, instance: ecs.EntityId, path: []const u8) ![]ecs.EntityId {
        const source = try files.read(files.context, self.gpa, path);
        defer self.gpa.free(source);
        var scene = try scene_zig.Scene.parse(self.gpa, source);
        defer scene.deinit();
        const made = try scene.instantiate(self.gpa, world, access, instance);
        defer self.gpa.free(made.entities);
        if (made.skipped > 0) log.warn("{s}: {d} components or fields left out (see above)", .{ path, made.skipped });
        var roots: std.ArrayList(ecs.EntityId) = .empty;
        errdefer roots.deinit(self.gpa);
        for (scene.entities, made.entities) |saved, entity| if (saved.parent == null) try roots.append(self.gpa, entity);
        return roots.toOwnedSlice(self.gpa);
    }

    /// Whether `path` is the scene being edited, or one an instance above `instance` was made from.
    fn isInsideItself(self: *const SceneInstances, world: *ecs.World, instance: ecs.EntityId, path: []const u8, open_scene: ?[]const u8) bool {
        if (open_scene) |open| if (std.mem.eql(u8, open, path)) return true;
        var above = world.getParent(instance);
        while (above) |entity| : (above = world.getParent(entity)) {
            const made = self.made.get(entity.id) orelse continue;
            if (made.generation == entity.generation and std.mem.eql(u8, made.path, path)) return true;
        }
        return false;
    }

    /// Take away what was made under the instance with entity id `id`, and forget it.
    fn unmake(self: *SceneInstances, world: *ecs.World, id: u32) void {
        const removed = self.made.fetchRemove(id) orelse return;
        const instance = ecs.EntityId.init(id, removed.value.generation);
        // Only what is still under it: the world may have been rebuilt since.
        for (removed.value.roots) |root| {
            const parent = world.getParent(root) orelse continue;
            if (world.isAlive(root) and parent.eql(instance)) world.despawnRecursive(root);
        }
        self.free(removed.value);
    }

    fn free(self: *SceneInstances, made: Made) void {
        self.gpa.free(made.path);
        self.gpa.free(made.roots);
    }
};

/// Whether every one of `roots` is alive and still a child of `instance`.
fn allUnder(world: *ecs.World, roots: []const ecs.EntityId, instance: ecs.EntityId) bool {
    for (roots) |root| {
        if (!world.isAlive(root)) return false;
        const parent = world.getParent(root) orelse return false;
        if (!parent.eql(instance)) return false;
    }
    return true;
}

/// The path in `zon` (an `AssetRef`'s field, a string literal), in `buffer`; null if it isn't one.
fn scenePath(zon: []const u8, buffer: []u8) ?[]const u8 {
    var source: [refs.max_path_len + 8:0]u8 = undefined;
    if (zon.len > source.len) return null;
    @memcpy(source[0..zon.len], zon);
    source[zon.len] = 0;
    // The parse's own scratch.
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const path = std.zon.parse.fromSliceAlloc([]const u8, fba.allocator(), source[0..zon.len :0], null, .{}) catch return null;
    if (path.len > buffer.len) return null;
    @memcpy(buffer[0..path.len], path);
    return buffer[0..path.len];
}

const Transform = @import("transform.zig").Transform;
const SceneInstance = scene_instance.SceneInstance;

test "an instance gets its scene's entities, again when they go, and none inside itself" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Spin = struct { speed: f32 = 1 };
    const Registry = components.Registry(&.{ Transform, SceneInstance, Spin }, &.{ "eggy", "eggy", "game" });
    const access = scene_zig.registryAccess(Registry);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A rat with a hat on it.
    try tmp.dir.writeFile(io, .{ .sub_path = "rat.scene.zon", .data =
        \\.{ .entities = .{
        \\    .{ .name = "Rat", .parent = null, .components = .{ .{ .type = "Spin", .owner = "game", .fields = .{ .speed = 3 } } } },
        \\    .{ .name = "Hat", .parent = 0, .components = .{} },
        \\} }
    });

    var world = ecs.World.init(gpa);
    defer world.deinit();
    var instances = SceneInstances.init(gpa);
    defer instances.deinit();
    var folder = FolderFiles{ .io = io, .dir = tmp.dir };
    const files = folder.files();
    const sewer_rat = try world.spawn(.{ Transform{}, SceneInstance{ .scene = .init("rat.scene.zon") } });
    instances.sync(files, &world, access, null);
    const rat = firstChild(&world, sewer_rat).?;
    try std.testing.expectEqual(@as(f32, 3), world.get(rat, Spin).?.speed);
    try std.testing.expect(firstChild(&world, rat) != null);

    // In sync, nothing changes; once the rat is gone, it is made again.
    instances.sync(files, &world, access, null);
    try std.testing.expect(firstChild(&world, sewer_rat).?.eql(rat));
    world.despawnRecursive(rat);
    instances.sync(files, &world, access, null);
    try std.testing.expect(firstChild(&world, sewer_rat) != null);

    // Without the component, its entities go.
    world.remove(sewer_rat, SceneInstance);
    instances.sync(files, &world, access, null);
    try std.testing.expect(firstChild(&world, sewer_rat) == null);

    // The rat scene, being edited, doesn't get a rat inside it.
    _ = try world.spawn(.{ Transform{}, SceneInstance{ .scene = .init("rat.scene.zon") } });
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    instances.sync(files, &world, access, "rat.scene.zon");
    try std.testing.expectEqual(@as(usize, 2), aliveCount(&world));
}

fn firstChild(world: *ecs.World, entity: ecs.EntityId) ?ecs.EntityId {
    var children = world.children(entity);
    return children.next();
}

fn aliveCount(world: *ecs.World) usize {
    var count: usize = 0;
    for (world.slots.items) |slot| count += @intFromBool(slot.alive);
    return count;
}
