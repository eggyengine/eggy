//! Transient runtime debug-drawing contracts, independent of editor scene tools.
const api = @import("support.zig");
pub const support: api.Support = .not_implemented;

// ponytail: runtime debug drawing has no renderer, implement a frame-owned debug pass first.
pub const DebugDraw = struct {
    /// Request a transient line between world-space positions in metres, with RGBA color.
    /// Currently returns `NotImplemented`, without recording geometry or allocating GPU data.
    ///
    /// ```zig
    /// try app.debug_draw.line(.{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 0, 0, 1 });
    /// // Currently returns NotImplemented.
    /// ```
    pub fn line(_: DebugDraw, from_m: [3]f32, to_m: [3]f32, color: [4]f32) api.Error!void {
        return api.notImplemented(.{ from_m, to_m, color });
    }
    /// Request a transient axis-aligned world-space box from minimum/maximum metre coordinates.
    /// Currently returns `NotImplemented`, without validating bounds or queuing a draw.
    ///
    /// ```zig
    /// try app.debug_draw.box(.{ -1, -1, -1 }, .{ 1, 1, 1 }, .{ 0, 1, 0, 1 });
    /// // Currently returns NotImplemented.
    /// ```
    pub fn box(_: DebugDraw, min_m: [3]f32, max_m: [3]f32, color: [4]f32) api.Error!void {
        return api.notImplemented(.{ min_m, max_m, color });
    }
    /// Request a transient world-space label in metres, borrowing `message` only for the call.
    /// Currently returns `NotImplemented`; no text or geometry is retained.
    ///
    /// ```zig
    /// try app.debug_draw.text(.{ 0, 2, 0 }, "Spawn"); // Currently NotImplemented.
    /// ```
    pub fn text(_: DebugDraw, position_m: [3]f32, message: []const u8) api.Error!void {
        return api.notImplemented(.{ position_m, message });
    }
};
