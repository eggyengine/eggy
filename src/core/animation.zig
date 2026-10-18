//! Animation playback contracts; packaged models currently contain static geometry only.
const api = @import("support.zig");
const ecs = @import("clutch");
const AssetRef = @import("refs.zig").AssetRef;
pub const support: api.Support = .not_implemented;
/// A requested named clip in a model. The name is borrowed for the duration of the call.
pub const Clip = struct { model: AssetRef(.model), name: []const u8 };
pub const PlayOptions = struct { speed: f32 = 1, repeat: enum { once, loop } = .once, start_s: f32 = 0 };

/// No skeleton, clip importer, or skinning backend is implied by these requests.
// ponytail: static models have no animation data, add a versioned clip format and backend first.
pub const Animation = struct {
    pub fn play(_: Animation, entity: ecs.EntityId, clip: Clip, options: PlayOptions) api.Error!void {
        return api.notImplemented(.{ entity, clip, options });
    }
    pub fn blendTo(_: Animation, entity: ecs.EntityId, clip: Clip, duration_s: f32, options: PlayOptions) api.Error!void {
        return api.notImplemented(.{ entity, clip, duration_s, options });
    }
    pub fn pause(_: Animation, entity: ecs.EntityId) api.Error!void {
        return api.notImplemented(entity);
    }
    pub fn stop(_: Animation, entity: ecs.EntityId) api.Error!void {
        return api.notImplemented(entity);
    }
    pub fn seek(_: Animation, entity: ecs.EntityId, time_s: f32) api.Error!void {
        return api.notImplemented(.{ entity, time_s });
    }
};
