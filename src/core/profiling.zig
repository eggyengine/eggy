//! Runtime profiling contracts, separate from working std.log and editor UI DevTools.
const api = @import("support.zig");
pub const support: api.Support = .not_implemented;
pub const Sample = enum(u32) { _ };

// ponytail: runtime profiling has no collector, implement sample ownership and export first.
pub const Profiling = struct {
    /// Request the start of a named timing sample, borrowing the name during the call.
    /// Currently returns `NotImplemented`, without starting a timer or fabricating a handle.
    ///
    /// ```zig
    /// const sample = try app.profiling.begin("AI"); // Currently NotImplemented.
    /// ```
    pub fn begin(_: Profiling, name: []const u8) api.Error!Sample {
        return api.notImplemented(name);
    }
    /// Request completion of a sample returned by a future profiling backend.
    /// Currently returns `NotImplemented`; no timing record is produced.
    ///
    /// ```zig
    /// try app.profiling.end(sample); // Backend-issued sample; currently NotImplemented.
    /// ```
    pub fn end(_: Profiling, sample: Sample) api.Error!void {
        return api.notImplemented(sample);
    }
    /// Request a named numeric measurement; `name` is borrowed, and units are caller-defined.
    /// Currently returns `NotImplemented`, without storing a sample or validating its value.
    ///
    /// ```zig
    /// try app.profiling.counter("visible_entities", @floatFromInt(visible_count));
    /// // Currently returns NotImplemented.
    /// ```
    pub fn counter(_: Profiling, name: []const u8, value: f64) api.Error!void {
        return api.notImplemented(.{ name, value });
    }
};
