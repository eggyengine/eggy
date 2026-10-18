//! Particle emission contracts with no simulation or collision integration.
const api = @import("support.zig");
pub const support: api.Support = .not_implemented;
pub const Emitter = enum(u32) { _ };
pub const Options = struct { position_m: [3]f32, count: u32 = 1, lifetime_s: f32 = 1, velocity_m_per_s: [3]f32 = @splat(0) };

// ponytail: particles have no simulation/render backend, implement both before emitting.
pub const Particles = struct {
    /// Request `count` particles with position in metres, lifetime in seconds and velocity
    /// in metres/second. Currently returns `NotImplemented`, without validating parameters,
    /// spawning particles or allocating a fake emitter.
    ///
    /// ```zig
    /// const emitter = try app.particles.emit(.{
    ///     .position_m = .{ 0, 1, 0 }, .count = 20, .lifetime_s = 0.5,
    /// }); // Currently NotImplemented.
    /// ```
    pub fn emit(_: Particles, options: Options) api.Error!Emitter {
        return api.notImplemented(options);
    }
    /// Request that a backend-issued emitter stop emitting. Currently returns
    /// `NotImplemented`, without releasing a handle or changing any simulated particles.
    ///
    /// ```zig
    /// try app.particles.stop(emitter); // Currently NotImplemented.
    /// ```
    pub fn stop(_: Particles, emitter: Emitter) api.Error!void {
        return api.notImplemented(emitter);
    }
};
