//! Runtime profiling contracts, separate from working std.log and editor UI DevTools.
const api = @import("support.zig");
pub const support: api.Support = .not_implemented;
pub const Sample = enum(u32) { _ };

// ponytail: runtime profiling has no collector, implement sample ownership and export first.
pub const Profiling = struct {
    pub fn begin(_: Profiling, name: []const u8) api.Error!Sample {
        return api.notImplemented(name);
    }
    pub fn end(_: Profiling, sample: Sample) api.Error!void {
        return api.notImplemented(sample);
    }
    pub fn counter(_: Profiling, name: []const u8, value: f64) api.Error!void {
        return api.notImplemented(.{ name, value });
    }
};
