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
