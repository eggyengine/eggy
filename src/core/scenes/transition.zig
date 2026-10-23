//! Scene replacement staged until the host has finished every gameplay system.
const std = @import("std");
const ecs = @import("clutch");
const scene = @import("../scene.zig");
const SceneInstances = @import("../scene_instances.zig").SceneInstances;
const Resources = @import("../resources/resources.zig").Resources;
const AssetRef = @import("../refs.zig").AssetRef;

/// Owns at most one parsed replacement. Reset or destroy it before unloading game code.
pub const Transition = struct {
    pending: ?scene.Scene = null,

    pub fn deinit(self: *Transition) void {
        if (self.pending) |*pending| pending.deinit();
        self.* = .{};
    }

    /// Read and parse now, without changing entities. A second pending request is an error.
    pub fn request(self: *Transition, gpa: std.mem.Allocator, resources: Resources, file: AssetRef(.scene)) !void {
        if (self.pending != null) return error.SceneTransitionPending;
        const source = try resources.read(gpa, file);
        defer gpa.free(source);
        self.pending = try scene.Scene.parse(gpa, source);
    }

    /// Commit after gameplay hooks/systems finish. Failed instantiation keeps the old scene.
    /// Replaces entities only: plugin instances, schedules, world resources and UI survive.
    pub fn apply(self: *Transition, world: *ecs.World, access: scene.Access, instances: *SceneInstances) !bool {
        var replacement = self.pending orelse return false;
        self.pending = null;
        defer replacement.deinit();
        const gpa = world.allocator;
        var old_roots: std.ArrayList(ecs.EntityId) = .empty;
        defer old_roots.deinit(gpa);
        for (world.slots.items, 0..) |slot, i| {
            if (!slot.alive) continue;
            const entity = ecs.EntityId.init(@intCast(i), slot.generation);
            if (world.getParent(entity) == null) try old_roots.append(gpa, entity);
        }

        // Build the replacement before removing anything the current scene owns.
        const made = try replacement.instantiate(gpa, world, access, null);
        defer gpa.free(made.entities);
        if (made.skipped != 0) {
            for (made.entities) |entity| if (world.isAlive(entity)) world.despawnRecursive(entity);
            return error.InvalidSceneComponents;
        }
        instances.deinit();
        instances.* = .init(gpa);
        for (old_roots.items) |entity| if (world.isAlive(entity)) world.despawnRecursive(entity);
        return true;
    }
};

test "replacement is deferred and keeps resources while replacing the entity tree" {
    const components = @import("../components.zig");
    const Name = @import("../name.zig").Name;
    const Value = struct { number: u32 = 3 };
    const Registry = components.Registry(&.{Value}, &.{"game"});
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const root = try world.spawn(.{Name.init("old")});
    const child = try world.spawn(.{});
    try world.setParent(child, root);
    try world.insertResource(@as(u32, 42));
    var instances = SceneInstances.init(std.testing.allocator);
    defer instances.deinit();
    var transition = Transition{};
    defer transition.deinit();
    transition.pending = try scene.Scene.parse(std.testing.allocator,
        \\.{ .entities = .{
        \\.{ .name = "new", .components = .{
        \\.{ .type = "Value", .owner = "game", .fields = .{ .number = 9 } },
        \\} },
        \\} }
    );
    try std.testing.expect(world.isAlive(root));
    try std.testing.expect(try transition.apply(&world, scene.registryAccess(Registry), &instances));
    try std.testing.expect(!world.isAlive(root));
    try std.testing.expect(!world.isAlive(child));
    try std.testing.expectEqual(@as(u32, 42), world.getResource(u32).?.*);
    var values = world.query(.{*const Value});
    try std.testing.expectEqual(@as(u32, 9), values.next().?.get(*const Value).number);
    try std.testing.expect(values.next() == null);
    try std.testing.expect(!try transition.apply(&world, scene.registryAccess(Registry), &instances));
}

test "replacement reads fail without losing a pending or current scene" {
    const assets = @import("eggy_assets");
    const Source = struct {
        fn read(_: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ![:0]u8 {
            if (std.mem.eql(u8, path, AssetRef(.scene).init("missing.scene.zon").key())) return error.FileNotFound;
            if (std.mem.eql(u8, path, AssetRef(.scene).init("invalid.scene.zon").key())) return gpa.dupeSentinel(u8, "broken", 0);
            return gpa.dupeSentinel(u8, ".{ .entities = .{} }", 0);
        }
        fn model(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !assets.Model {
            return error.NotPackaged;
        }
        fn image(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !assets.Texture {
            return error.NotPackaged;
        }
    };
    var context: u8 = 0;
    const resources = Resources.from(&context, Source.read, Source.model, Source.image);
    var transition = Transition{};
    defer transition.deinit();
    try std.testing.expectError(error.FileNotFound, transition.request(std.testing.allocator, resources, .init("missing.scene.zon")));
    try std.testing.expectError(error.ParseZon, transition.request(std.testing.allocator, resources, .init("invalid.scene.zon")));
    try std.testing.expect(transition.pending == null);
    try transition.request(std.testing.allocator, resources, .init("next.scene.zon"));
    try std.testing.expectError(error.SceneTransitionPending, transition.request(std.testing.allocator, resources, .init("next.scene.zon")));
    try std.testing.expect(transition.pending != null);
}

test "invalid replacement leaves old entities alive and consumes the failed request" {
    const Registry = @import("../components.zig").Registry(&.{}, &.{});
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const old = try world.spawn(.{});
    var instances = SceneInstances.init(std.testing.allocator);
    defer instances.deinit();
    var transition = Transition{};
    defer transition.deinit();
    transition.pending = try scene.Scene.parse(std.testing.allocator,
        \\.{ .entities = .{.{ .components = .{
        \\.{ .type = "Missing", .owner = "game", .fields = .{} },
        \\} }} }
    );
    try std.testing.expectError(error.InvalidSceneComponents, transition.apply(&world, scene.registryAccess(Registry), &instances));
    try std.testing.expect(world.isAlive(old));
    try std.testing.expect(transition.pending == null);
    var alive: usize = 0;
    for (world.slots.items) |slot| if (slot.alive) {
        alive += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), alive);
}
