//! Transient runtime debug-drawing contracts, independent of editor scene tools.
const api = @import("support.zig");
pub const support: api.Support = .not_implemented;

// ponytail: runtime debug drawing has no renderer, implement a frame-owned debug pass first.
pub const DebugDraw = struct {
    pub fn line(_: DebugDraw, from_m: [3]f32, to_m: [3]f32, color: [4]f32) api.Error!void {
        return api.notImplemented(.{ from_m, to_m, color });
    }
    pub fn box(_: DebugDraw, min_m: [3]f32, max_m: [3]f32, color: [4]f32) api.Error!void {
        return api.notImplemented(.{ min_m, max_m, color });
    }
    pub fn text(_: DebugDraw, position_m: [3]f32, message: []const u8) api.Error!void {
        return api.notImplemented(.{ position_m, message });
    }
};
