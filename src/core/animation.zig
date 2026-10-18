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
    /// Request a named model clip for `entity`; options use seconds and a speed multiplier.
    /// `clip.name` is borrowed only for this call. Currently returns `NotImplemented`;
    /// packaged static models have no skeleton/clip data and the entity is not modified.
    ///
    /// ```zig
    /// try app.animation.play(entity, .{
    ///     .model = .init("resources/models/player.glb"), .name = "walk",
    /// }, .{ .repeat = .loop }); // Currently NotImplemented.
    /// ```
    pub fn play(_: Animation, entity: ecs.EntityId, clip: Clip, options: PlayOptions) api.Error!void {
        return api.notImplemented(.{ entity, clip, options });
    }
    /// Request transition to `clip` over `duration_s` seconds for an existing entity.
    /// Borrows the clip name during the call. Currently returns `NotImplemented`, without
    /// validating the duration, loading a model or allocating a blend.
    ///
    /// ```zig
    /// try app.animation.blendTo(entity, .{
    ///     .model = .init("resources/models/player.glb"), .name = "idle",
    /// }, 0.2, .{ .repeat = .loop }); // Currently NotImplemented.
    /// ```
    pub fn blendTo(_: Animation, entity: ecs.EntityId, clip: Clip, duration_s: f32, options: PlayOptions) api.Error!void {
        return api.notImplemented(.{ entity, clip, duration_s, options });
    }
    /// Request that `entity` retain its pose without advancing its clip.
    /// Currently returns `NotImplemented` and changes no components.
    ///
    /// ```zig
    /// try app.animation.pause(entity); // Currently NotImplemented.
    /// ```
    pub fn pause(_: Animation, entity: ecs.EntityId) api.Error!void {
        return api.notImplemented(entity);
    }
    /// Request that `entity` stop playing animation. Currently returns `NotImplemented`;
    /// no clip state or entity ownership changes.
    ///
    /// ```zig
    /// try app.animation.stop(entity); // Currently NotImplemented.
    /// ```
    pub fn stop(_: Animation, entity: ecs.EntityId) api.Error!void {
        return api.notImplemented(entity);
    }
    /// Request an absolute playback position in seconds for `entity`'s clip.
    /// Currently returns `NotImplemented`, without validating time or changing a pose.
    ///
    /// ```zig
    /// try app.animation.seek(entity, 1.5); // Currently NotImplemented.
    /// ```
    pub fn seek(_: Animation, entity: ecs.EntityId, time_s: f32) api.Error!void {
        return api.notImplemented(.{ entity, time_s });
    }
};
