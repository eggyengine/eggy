//! Save an entity tree as a scene before replacing it with a positioned scene instance.
const std = @import("std");
const zon_file = @import("eggy").assets.zon;
const eggy = @import("eggy");
const ecs = eggy.ecs;
const file_ops = @import("../assets/file_ops.zig");
const ProjectAssets = @import("../assets/project_assets.zig").ProjectAssets;

/// A saved scene and prepared instance; the original remains alive until the host commits.
pub const Prepared = struct {
    path: []u8,
    instance: ecs.EntityId,
    assets: *ProjectAssets,

    /// Roll back an uncommitted extraction, retaining the original entity tree.
    pub fn rollback(self: Prepared, io: std.Io, project: std.Io.Dir, world: *ecs.World) void {
        world.despawnRecursive(self.instance);
        project.deleteFile(io, self.path) catch |err| if (err != error.FileNotFound) {
            std.log.err("cannot remove extracted scene {s}: {t}", .{ self.path, err });
        };
        _ = self.assets.sync() catch |err| std.log.err("cannot forget the extracted scene's id: {t}", .{err});
    }
};

/// Save to the Assets panel's unique-name convention, catalogued and with no overwrites; the
/// instance refers to the file by its asset id.
/// On failure, remove the staged instance and files; never destroy the source tree.
pub fn prepare(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, world: *ecs.World, access: eggy.scene.Access, source: ecs.EntityId, folder: []const u8, assets: *ProjectAssets) !Prepared {
    if (!world.isAlive(source)) return error.DeadEntity;
    var scene = try @import("snapshot.zig").capture(gpa, world, access, &.{source});
    defer scene.deinit();
    try validateReferences(gpa, world, access, scene.sources);
    const scene_type = eggy.scene_instance.typeIndex(access.types()) orelse return error.NoSceneInstance;
    const instance = try world.spawn(.{});
    errdefer world.despawnRecursive(instance);
    if (!access.add(world, instance, scene_type)) return error.CannotAddSceneInstance;
    try moveTransform(&scene, world, access, instance);
    const title = scene.entities[0].name;
    access.setName(world, instance, title);

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try scene.write(&text.writer);
    const file_title = if (title.len > 0 and std.mem.indexOfAny(u8, title, "/\\\x00") == null and !std.mem.eql(u8, title, ".") and !std.mem.eql(u8, title, "..")) title else "Extracted scene";
    const path = try file_ops.createFile(gpa, io, project, folder, .{
        .key = "eggy/scene",
        .title = try scene.arena.allocator().dupeSentinel(u8, file_title, 0),
        .extension = ".scene.zon",
        .contents = text.written(),
    });
    errdefer gpa.free(path);
    errdefer project.deleteFile(io, path) catch |err| std.log.err("cannot remove extracted scene {s}: {t}", .{ path, err });
    // The new file is given its id before the instance can name it.
    _ = try assets.sync();
    errdefer _ = assets.sync() catch |err| std.log.err("cannot forget the extracted scene's id: {t}", .{err});
    var key_buffer: [eggy.assets.id.key_len]u8 = undefined;
    const key = assets.keyOf(&key_buffer, path) orelse return error.NotCatalogued;
    const field = for (access.types()[scene_type].fields, 0..) |info, index| {
        if (std.mem.eql(u8, info.name, "scene")) break index;
    } else return error.NoSceneField;
    const value = try std.fmt.allocPrintSentinel(gpa, "\"{s}\"", .{key}, 0);
    defer gpa.free(value);
    if (!access.writeField(world, instance, scene_type, field, value)) return error.CannotSetScene;
    return .{ .path = path, .instance = instance, .assets = assets };
}

/// Move the saved root's local transform onto the wrapper, leaving an identity scene root.
fn moveTransform(scene: *eggy.scene.Scene, world: *ecs.World, access: eggy.scene.Access, instance: ecs.EntityId) !void {
    for (scene.entities[0].components) |component| {
        if (!std.mem.eql(u8, component.type, "Transform") or !std.mem.eql(u8, component.owner, "eggy")) continue;
        const index = for (access.types(), 0..) |info, index| {
            if (std.mem.eql(u8, info.name, component.type) and std.mem.eql(u8, info.owner, component.owner)) break index;
        } else return error.NoTransform;
        if (!access.has(world, instance, index) and !access.add(world, instance, index)) return error.CannotAddTransform;
        for (@constCast(component.fields)) |*field| {
            const field_index = for (access.types()[index].fields, 0..) |info, i| {
                if (std.mem.eql(u8, field.name, info.name)) break i;
            } else return error.NoTransformField;
            const identity = try access.readFieldAlloc(scene.arena.allocator(), world, instance, index, field_index);
            const original = try scene.arena.allocator().dupeSentinel(u8, field.value, 0);
            if (!access.writeField(world, instance, index, field_index, original)) return error.CannotSetTransform;
            field.value = identity;
        }
    }
}

/// Separate scene files cannot persist references across the extraction boundary.
fn validateReferences(gpa: std.mem.Allocator, world: *ecs.World, access: eggy.scene.Access, tree: []const ecs.EntityId) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    for (world.slots.items, 0..) |slot, id| {
        if (!slot.alive) continue;
        const entity = ecs.EntityId.init(@intCast(id), slot.generation);
        for (access.types(), 0..) |component, index| {
            if (!access.has(world, entity, index)) continue;
            for (component.fields, 0..) |field, field_index| {
                try @import("snapshot.zig").validateReferenceField(field);
                if (field.kind != .entity) continue;
                const text = try access.readFieldAlloc(arena.allocator(), world, entity, index, field_index);
                const source = try arena.allocator().dupeSentinel(u8, text, 0);
                const target = (try zon_file.parse(?ecs.EntityId, arena.allocator(), source, .{})) orelse continue;
                if (contains(tree, entity) != contains(tree, target)) return error.CrossSceneEntityReference;
            }
        }
    }
}

fn contains(tree: []const ecs.EntityId, entity: ecs.EntityId) bool {
    for (tree) |member| if (member.eql(entity)) return true;
    return false;
}
