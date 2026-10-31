//! Navigation request contracts independent of physics and collision.
const std = @import("std");
const api = @import("support.zig");
const ecs = @import("clutch");
const math = @import("eggenvector");
pub const support: api.Support = .not_implemented;

// ponytail: navigation has no data or pathfinder, implement explicit navigation data first.
pub const Navigation = struct {
    /// A successful backend would return caller-owned world-space points, freed with `gpa`.
    /// Start and goal positions are in metres. Currently returns `NotImplemented` without
    /// allocating, querying physics or validating navigation data.
    ///
    /// ```zig
    /// const points = try app.navigation.findPath(gpa, .zero, .init(10, 0, 5));
    /// defer gpa.free(points); // Only reached when a future backend succeeds.
    /// ```
    pub fn findPath(_: Navigation, gpa: std.mem.Allocator, start_m: math.Vec3, goal_m: math.Vec3) api.Error![]math.Vec3 {
        return api.notImplemented(.{ gpa, start_m, goal_m });
    }
    /// Request movement of `entity` toward a world-space goal in metres.
    /// Currently returns `NotImplemented`; this does not move a Transform or attach an agent.
    ///
    /// ```zig
    /// try app.navigation.setDestination(entity, .init(10, 0, 5)); // NotImplemented.
    /// ```
    pub fn setDestination(_: Navigation, entity: ecs.EntityId, goal_m: math.Vec3) api.Error!void {
        return api.notImplemented(.{ entity, goal_m });
    }
    /// Request cancellation of an entity's navigation request. Currently returns
    /// `NotImplemented`, without changing its destination, components or velocity.
    ///
    /// ```zig
    /// try app.navigation.cancel(entity); // Currently NotImplemented.
    /// ```
    pub fn cancel(_: Navigation, entity: ecs.EntityId) api.Error!void {
        return api.notImplemented(entity);
    }
};
