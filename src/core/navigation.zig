//! Navigation request contracts independent of physics and collision.
const std = @import("std");
const api = @import("support.zig");
const ecs = @import("clutch");
pub const support: api.Support = .not_implemented;

// ponytail: navigation has no data or pathfinder, implement explicit navigation data first.
pub const Navigation = struct {
    /// A successful backend would return caller-owned world-space points, freed with `gpa`.
    pub fn findPath(_: Navigation, gpa: std.mem.Allocator, start_m: [3]f32, goal_m: [3]f32) api.Error![][3]f32 {
        return api.notImplemented(.{ gpa, start_m, goal_m });
    }
    pub fn setDestination(_: Navigation, entity: ecs.EntityId, goal_m: [3]f32) api.Error!void {
        return api.notImplemented(.{ entity, goal_m });
    }
    pub fn cancel(_: Navigation, entity: ecs.EntityId) api.Error!void {
        return api.notImplemented(entity);
    }
};
