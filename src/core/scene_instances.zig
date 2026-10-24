//! The entities each `SceneInstance` stands for, made in the world under it from its scene file
//! (see `scene_instance.zig`), in the editor and the runtime alike. They are made again when the instance's file is picked or
//! changes, after the world is rebuilt (they aren't saved, so a scene opened, undone or carried
//! across a reload comes back without them), and once files change on disk; they go when the
//! instance does, or loses the component. An instance inside its own scene, however deep, is
//! left empty rather than made forever. Each instance can change fields of the entities its
//! file makes, for itself alone: those changes are worked out against what the file made
//! (`hooks`, which `Scene.capture` saves them through) and put back when it is made again.
const std = @import("std");
const zon_file = @import("eggy_assets").zon;
const ecs = @import("clutch");
const components = @import("components.zig");
const scene_zig = @import("scene.zig");
const scene_instance = @import("scene_instance.zig");
const refs = @import("refs.zig");
const log = std.log.scoped(.scene_instances);

/// Scene source bytes addressed by canonical asset identity, independent of source paths.
pub const Files = struct {
    context: *anyopaque,
    /// The file identified by `path` (a canonical asset key), allocated with `gpa`.
    read: *const fn (context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![:0]u8,
};

/// `Files` from a folder whose filenames are canonical asset identities.
pub const FolderFiles = struct {
    io: std.Io,
    dir: std.Io.Dir,

    /// Borrow this folder as a scene-file provider; `self`, its directory and I/O must
    /// outlive uses of the result. Reads are caller-owned, sentinel-terminated, and
    /// limited to 64 MiB; source project folders need the editor's catalog-backed provider.
    ///
    /// ```zig
    /// var folder = FolderFiles{ .io = io, .dir = packaged_dir };
    /// const provider = folder.files();
    /// ```
    pub fn files(self: *FolderFiles) Files {
        return .{ .context = self, .read = read };
    }

    fn read(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![:0]u8 {
        const self: *FolderFiles = @ptrCast(@alignCast(context));
        _ = try @import("eggy_assets").id.parse(path);
        return self.dir.readFileAllocOptions(self.io, path, gpa, .limited(64 << 20), .of(u8), 0);
    }
};

pub const SceneInstances = struct {
    gpa: std.mem.Allocator,
    /// By the instance's entity id: what was made under it.
    made: std.AutoHashMapUnmanaged(u32, Made) = .empty,
    /// By the instance's entity id: changes to put back once its entities are made.
    kept: std.AutoHashMapUnmanaged(u32, Kept) = .empty,

    const Made = struct {
        generation: u32,
        /// The scene file it was made from, owned.
        path: []u8,
        /// The scene's top-level entities, made under the instance; owned.
        roots: []ecs.EntityId,
        /// Its file may have changed: make it again.
        stale: bool = false,
        /// What the file made, to tell the instance's changes from; null when nothing was.
        base: ?*Base = null,
    };

    /// Every entity a file made, in the file's order, by its name path, and every field of
    /// theirs as it was made.
    const Base = struct {
        arena: std.heap.ArenaAllocator,
        entities: []ecs.EntityId,
        paths: []const []const u8,
        fields: []const BaseField,
    };
    const BaseField = struct { entity: u32, component: u32, field: u32, value: []const u8 };

    const Kept = struct {
        generation: u32,
        arena: std.heap.ArenaAllocator,
        overrides: []const scene_zig.Scene.Override,
    };

    /// Create an empty host-side tracker; retains `gpa` for tracked paths and child lists.
    /// Pair with `deinit`; no world entities are created yet.
    ///
    /// ```zig
    /// var instances = SceneInstances.init(gpa);
    /// defer instances.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator) SceneInstances {
        return .{ .gpa = gpa };
    }

    /// Free tracking allocations once; does not despawn any world entities.
    /// The tracker must no longer be used after this call.
    ///
    /// ```zig
    /// var instances = SceneInstances.init(gpa);
    /// defer instances.deinit();
    /// ```
    pub fn deinit(self: *SceneInstances) void {
        var it = self.made.valueIterator();
        while (it.next()) |made| self.free(made.*);
        self.made.deinit(self.gpa);
        var kept = self.kept.valueIterator();
        while (kept.next()) |entry| entry.arena.deinit();
        self.kept.deinit(self.gpa);
    }

    /// The `Scene.Access.Instances` that saves and restores these instances' changes, for the
    /// access of whatever captures or makes this world's scenes. `self` must outlive it.
    pub fn hooks(self: *SceneInstances) scene_zig.Access.Instances {
        return .{ .context = self, .changes = changesOf, .keep = keepFor };
    }

    fn changesOf(context: *anyopaque, arena: std.mem.Allocator, world: *ecs.World, access: scene_zig.Access, instance: ecs.EntityId) anyerror![]const scene_zig.Scene.Override {
        const self: *SceneInstances = @ptrCast(@alignCast(context));
        return self.changes(arena, world, access, instance);
    }

    fn keepFor(context: *anyopaque, world: *ecs.World, instance: ecs.EntityId, overrides: []const scene_zig.Scene.Override) void {
        _ = world;
        const self: *SceneInstances = @ptrCast(@alignCast(context));
        self.keep(instance, overrides) catch |err| log.err("cannot keep a scene instance's changes: {t}", .{err});
    }

    /// The fields `instance`'s entities have now that differ from what its file made, in
    /// `arena`; none when it made nothing. A field that can't be read is left out.
    pub fn changes(self: *const SceneInstances, arena: std.mem.Allocator, world: *ecs.World, access: scene_zig.Access, instance: ecs.EntityId) ![]const scene_zig.Scene.Override {
        // Changes not put back yet (its entities aren't made) are still its changes.
        if (self.kept.get(instance.id)) |kept| if (kept.generation == instance.generation) return copyOverrides(arena, kept.overrides);
        const made = self.made.get(instance.id) orelse return &.{};
        if (made.generation != instance.generation) return &.{};
        const base = made.base orelse return &.{};
        const types = access.types();
        var found: std.ArrayList(scene_zig.Scene.Override) = .empty;
        var buffer: [components.max_field_bytes]u8 = undefined;
        for (base.fields) |field| {
            const entity = base.entities[field.entity];
            if (!world.isAlive(entity) or !access.has(world, entity, field.component)) continue;
            const now = access.readField(world, entity, field.component, field.field, &buffer) orelse continue;
            if (std.mem.eql(u8, now, field.value)) continue;
            const info = types[field.component];
            try found.append(arena, .{
                .entity = try arena.dupe(u8, base.paths[field.entity]),
                .type = try arena.dupe(u8, info.name),
                .owner = try arena.dupe(u8, info.owner),
                .field = try arena.dupe(u8, info.fields[field.field].name),
                .value = try arena.dupe(u8, now),
            });
        }
        return found.items;
    }

    /// Keep `overrides` (copied) for `instance`, put back the next time its entities are made.
    pub fn keep(self: *SceneInstances, instance: ecs.EntityId, overrides: []const scene_zig.Scene.Override) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const copied = try copyOverrides(arena.allocator(), overrides);
        if (try self.kept.fetchPut(self.gpa, instance.id, .{ .generation = instance.generation, .arena = arena, .overrides = copied })) |old| old.value.arena.deinit();
    }

    /// Make an instance synchronously and register its children so `sync` does not duplicate
    /// them. On failure the instance and every entity it created are removed.
    /// Host operation: `files` and `access` must describe this world's project/registry.
    /// Reads/parses the file immediately and propagates errors; returns the world-owned
    /// instance root ID. `parent`, when supplied, must be a valid parent in this world.
    ///
    /// ```zig
    /// const root = try instances.create(
    ///     provider, world, access, .init("resources/scene/enemy.scene.zon"), null,
    /// );
    /// ```
    pub fn create(self: *SceneInstances, files: Files, world: *ecs.World, access: scene_zig.Access, file: refs.AssetRef(.scene), parent: ?ecs.EntityId) !ecs.EntityId {
        const root = try world.spawn(.{ Transform{}, SceneInstance{ .scene = file } });
        errdefer world.despawnRecursive(root);
        if (parent) |up| try world.setParent(root, up);
        const path = try self.gpa.dupe(u8, file.key());
        errdefer self.gpa.free(path);
        const made = try self.instantiate(files, world, access, root, path);
        errdefer self.freeMade(made);
        try self.made.put(self.gpa, root.id, .{ .generation = root.generation, .path = path, .roots = made.roots, .base = made.base });
        return root;
    }

    /// Make every instance's entities again on the next `sync`, as their files may have changed.
    /// Only marks tracking entries stale; does not read files or mutate the world now.
    ///
    /// ```zig
    /// instances.remakeAll();
    /// ```
    pub fn remakeAll(self: *SceneInstances) void {
        var it = self.made.valueIterator();
        while (it.next()) |made| made.stale = true;
    }

    /// Bring each instance in `world` up to date: make the entities of one whose file is new,
    /// changed or whose entities are gone, from the scene files in `files`, and take away
    /// those of instances that are gone. `open_scene` is the edited scene's identity key;
    /// it is never instantiated inside itself.
    /// Host update: mutates/spawns/despawns ECS entities, invalidating borrowed component
    /// pointers. File failures are logged and remembered until another remake/change;
    /// nested instances newly created here are considered by a later call. Pass null
    /// for `open_scene` outside the editor.
    ///
    /// ```zig
    /// instances.sync(provider, world, access, null);
    /// ```
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
                const same_file = made.generation == entity.generation and std.mem.eql(u8, made.path, path);
                if (same_file and !made.stale and allUnder(world, made.roots, entity)) continue;
                // Made again from the same file, it keeps what it changed there.
                if (same_file and !self.kept.contains(entity.id)) self.keepChanges(world, access, entity);
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

    /// Keep what `instance` changed in its entities, for when they are made again.
    fn keepChanges(self: *SceneInstances, world: *ecs.World, access: scene_zig.Access, instance: ecs.EntityId) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const found = self.changes(arena.allocator(), world, access, instance) catch return;
        if (found.len > 0) self.keep(instance, found) catch |err| log.err("cannot keep a scene instance's changes: {t}", .{err});
    }

    /// Make the scene at `path` under `instance`, with the changes kept for it, and remember
    /// what was made (nothing, if it can't be, so it isn't tried again every frame).
    fn make(self: *SceneInstances, files: Files, world: *ecs.World, access: scene_zig.Access, instance: ecs.EntityId, path: []const u8, open_scene: ?[]const u8) void {
        const owned_path = self.gpa.dupe(u8, path) catch return;
        var made = Instantiated{};
        if (path.len > 0) if (self.isInsideItself(world, instance, path, open_scene)) {
            log.warn("{s} is instanced inside itself: that instance is left empty", .{path});
        } else {
            made = self.instantiate(files, world, access, instance, path) catch |err| blk: {
                log.err("cannot make the entities of {s}: {t}", .{ path, err });
                break :blk .{};
            };
        };
        self.made.put(self.gpa, instance.id, .{ .generation = instance.generation, .path = owned_path, .roots = made.roots, .base = made.base }) catch {
            self.gpa.free(owned_path);
            self.freeMade(made);
        };
    }

    const Instantiated = struct { roots: []ecs.EntityId = &.{}, base: ?*Base = null };

    /// The scene at `path` read and made under `instance`, with the changes kept for it put
    /// back: its top-level entities and what it made, caller-owned.
    fn instantiate(self: *SceneInstances, files: Files, world: *ecs.World, access: scene_zig.Access, instance: ecs.EntityId, path: []const u8) !Instantiated {
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

        // What the file made, then the instance's own changes over it.
        const base = try self.gpa.create(Base);
        errdefer self.gpa.destroy(base);
        base.* = try baseOf(self.gpa, world, access, scene, made.entities);
        errdefer base.arena.deinit();
        if (self.kept.fetchRemove(instance.id)) |kept| {
            defer kept.value.arena.deinit();
            if (kept.value.generation == instance.generation) applyOverrides(world, access, base, kept.value.overrides);
        }
        return .{ .roots = try roots.toOwnedSlice(self.gpa), .base = base };
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
        self.freeMade(.{ .roots = made.roots, .base = made.base });
    }

    fn freeMade(self: *SceneInstances, made: Instantiated) void {
        self.gpa.free(made.roots);
        if (made.base) |base| {
            base.arena.deinit();
            self.gpa.destroy(base);
        }
    }
};

/// What `scene` made as `entities`: their name paths, and each of their fields as it is now.
fn baseOf(gpa: std.mem.Allocator, world: *ecs.World, access: scene_zig.Access, scene: scene_zig.Scene, entities: []const ecs.EntityId) !SceneInstances.Base {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    var fields: std.ArrayList(SceneInstances.BaseField) = .empty;
    var buffer: [components.max_field_bytes]u8 = undefined;
    for (entities, 0..) |entity, index| for (access.types(), 0..) |info, component| {
        if (!access.has(world, entity, component)) continue;
        for (0..info.fields.len) |field| {
            const value = access.readField(world, entity, component, field, &buffer) orelse continue;
            try fields.append(arena, .{ .entity = @intCast(index), .component = @intCast(component), .field = @intCast(field), .value = try arena.dupe(u8, value) });
        }
    };
    // Allocated before the arena's state is copied out with them.
    const kept_entities = try arena.dupe(ecs.EntityId, entities);
    const paths = try namePaths(arena, scene);
    return .{ .arena = arena_state, .entities = kept_entities, .paths = paths, .fields = fields.items };
}

/// Each of `scene`'s entities by the names from its top-level one down, "/" between them; a
/// later sibling with the same name gets "#2", "#3" and on, so every path is one entity's.
fn namePaths(arena: std.mem.Allocator, scene: scene_zig.Scene) ![]const []const u8 {
    const paths = try arena.alloc([]const u8, scene.entities.len);
    for (scene.entities, 0..) |entity, index| {
        var occurrence: usize = 1;
        for (scene.entities[0..index]) |before| {
            if (std.meta.eql(before.parent, entity.parent) and std.mem.eql(u8, before.name, entity.name)) occurrence += 1;
        }
        const own = if (occurrence > 1) try std.fmt.allocPrint(arena, "{s}#{d}", .{ entity.name, occurrence }) else try arena.dupe(u8, entity.name);
        paths[index] = if (entity.parent) |parent| try std.fmt.allocPrint(arena, "{s}/{s}", .{ paths[parent], own }) else own;
    }
    return paths;
}

/// Write each of `overrides` into the entity `base` made at its path; one whose entity,
/// component or field is gone, or whose value no longer parses, is left out (logged).
fn applyOverrides(world: *ecs.World, access: scene_zig.Access, base: *const SceneInstances.Base, overrides: []const scene_zig.Scene.Override) void {
    const types = access.types();
    for (overrides) |override| {
        const at = for (base.paths, 0..) |path, i| {
            if (std.mem.eql(u8, path, override.entity)) break i;
        } else {
            log.warn("{s} isn't in the scene any more: its change to {s}.{s} is left out", .{ override.entity, override.type, override.field });
            continue;
        };
        const component = scene_zig.findType(types, override.type, override.owner) orelse continue;
        const field = for (types[component].fields, 0..) |known, i| {
            if (std.mem.eql(u8, known.name, override.field)) break i;
        } else continue;
        const entity = base.entities[at];
        if (!access.has(world, entity, component) and !access.add(world, entity, component)) continue;
        var buffer: [components.max_field_bytes + 1]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buffer, "{s}", .{override.value}, 0) catch continue;
        if (!access.writeField(world, entity, component, field, text)) log.warn("{s}: {s}.{s} = {s} doesn't parse: it keeps the scene's value", .{ override.entity, override.type, override.field, override.value });
    }
}

fn copyOverrides(arena: std.mem.Allocator, overrides: []const scene_zig.Scene.Override) ![]const scene_zig.Scene.Override {
    const copied = try arena.alloc(scene_zig.Scene.Override, overrides.len);
    for (copied, overrides) |*out, override| out.* = .{
        .entity = try arena.dupe(u8, override.entity),
        .type = try arena.dupe(u8, override.type),
        .owner = try arena.dupe(u8, override.owner),
        .field = try arena.dupe(u8, override.field),
        .value = try arena.dupe(u8, override.value),
    };
    return copied;
}

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
    const path = zon_file.parse([]const u8, fba.allocator(), source[0..zon.len :0], .{}) catch return null;
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
    const rat_scene = refs.AssetRef(.scene).init("rat.scene.zon");
    try tmp.dir.writeFile(io, .{ .sub_path = rat_scene.key(), .data =
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
    instances.sync(files, &world, access, rat_scene.key());
    try std.testing.expectEqual(@as(usize, 2), aliveCount(&world));
}

test "explicit instances synchronize without duplicate children and failed reads roll back" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    var made = SceneInstances.init(std.testing.allocator);
    defer made.deinit();
    const Registry = components.Registry(&.{ Transform, SceneInstance }, &.{ "eggy", "eggy" });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const one = refs.AssetRef(.scene).init("one.scene.zon");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = one.key(), .data = ".{ .entities = .{ .{ .name = \"One\", .components = .{} } } }" });
    var folder = FolderFiles{ .io = std.testing.io, .dir = tmp.dir };
    const root = try made.create(folder.files(), &world, scene_zig.registryAccess(Registry), .init("one.scene.zon"), null);
    try std.testing.expect(firstChild(&world, root) != null);
    made.sync(folder.files(), &world, scene_zig.registryAccess(Registry), null);
    try std.testing.expectEqual(@as(usize, 2), aliveCount(&world));
    try std.testing.expectError(error.FileNotFound, made.create(folder.files(), &world, scene_zig.registryAccess(Registry), .init("missing.scene.zon"), null));
    try std.testing.expectEqual(@as(usize, 2), aliveCount(&world));
}

test "a change to one instance's entities is saved on it alone, and put back when the scene opens" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Tuning = struct { speed: f32 = 1, jump: f32 = 2 };
    const Registry = components.Registry(&.{ Transform, SceneInstance, Tuning }, &.{ "eggy", "eggy", "game" });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const player = refs.AssetRef(.scene).init("player.scene.zon");
    try tmp.dir.writeFile(io, .{ .sub_path = player.key(), .data =
        \\.{ .entities = .{
        \\    .{ .name = "Player", .parent = null, .components = .{ .{ .type = "Tuning", .owner = "game", .fields = .{ .speed = 4 } } } },
        \\} }
    });
    var folder = FolderFiles{ .io = io, .dir = tmp.dir };
    const files = folder.files();

    // The garden has two players; only the first is tuned.
    var saved_text: std.Io.Writer.Allocating = .init(gpa);
    defer saved_text.deinit();
    {
        var world = ecs.World.init(gpa);
        defer world.deinit();
        var instances = SceneInstances.init(gpa);
        defer instances.deinit();
        var access = scene_zig.registryAccess(Registry);
        access.instances = instances.hooks();
        const first = try world.spawn(.{ Transform{}, SceneInstance{ .scene = player } });
        const second = try world.spawn(.{ Transform{}, SceneInstance{ .scene = player } });
        instances.sync(files, &world, access, null);
        world.get(firstChild(&world, first).?, Tuning).?.speed = 9;
        try std.testing.expectEqual(@as(f32, 4), world.get(firstChild(&world, second).?, Tuning).?.speed);

        var garden = try scene_zig.Scene.capture(gpa, &world, access, null);
        defer garden.deinit();
        try std.testing.expectEqual(@as(usize, 1), garden.entities[0].overrides.len);
        try std.testing.expectEqualStrings("Player", garden.entities[0].overrides[0].entity);
        try std.testing.expectEqualStrings("speed", garden.entities[0].overrides[0].field);
        try std.testing.expectEqual(@as(usize, 0), garden.entities[1].overrides.len);
        try garden.write(&saved_text.writer);
    }

    // Opened again, the first player is tuned and the second is as its file says.
    var world = ecs.World.init(gpa);
    defer world.deinit();
    var instances = SceneInstances.init(gpa);
    defer instances.deinit();
    var access = scene_zig.registryAccess(Registry);
    access.instances = instances.hooks();
    const source = try gpa.dupeSentinel(u8, saved_text.written(), 0);
    defer gpa.free(source);
    var garden = try scene_zig.Scene.parse(gpa, source);
    defer garden.deinit();
    const made = try garden.instantiate(gpa, &world, access, null);
    defer gpa.free(made.entities);
    instances.sync(files, &world, access, null);
    try std.testing.expectEqual(@as(f32, 9), world.get(firstChild(&world, made.entities[0]).?, Tuning).?.speed);
    try std.testing.expectEqual(@as(f32, 4), world.get(firstChild(&world, made.entities[1]).?, Tuning).?.speed);

    // Made again from a changed file, the first keeps its own speed.
    instances.remakeAll();
    instances.sync(files, &world, access, null);
    try std.testing.expectEqual(@as(f32, 9), world.get(firstChild(&world, made.entities[0]).?, Tuning).?.speed);
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
