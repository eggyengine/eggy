//! Particle emission contracts with no simulation or collision integration.
const api = @import("support.zig");
pub const support: api.Support = .not_implemented;
pub const Emitter = enum(u32) { _ };
pub const Options = struct { position_m: [3]f32, count: u32 = 1, lifetime_s: f32 = 1, velocity_m_per_s: [3]f32 = @splat(0) };

// ponytail: particles have no simulation/render backend, implement both before emitting.
pub const Particles = struct {
    pub fn emit(_: Particles, options: Options) api.Error!Emitter {
        return api.notImplemented(options);
    }
    pub fn stop(_: Particles, emitter: Emitter) api.Error!void {
        return api.notImplemented(emitter);
    }
};
