//! Sprite and world-text request contracts, separate from working Weeoui UI.
const api = @import("support.zig");
const AssetRef = @import("refs.zig").AssetRef;
pub const support: api.Support = .not_implemented;
pub const Sprite = struct { image: AssetRef(.image), position: [2]f32 = .{ 0, 0 }, size: [2]f32 = .{ 1, 1 }, tint: [4]f32 = @splat(1) };

/// Transient drawing requests; borrowed text lasts only for the call.
// ponytail: there is no sprite/world-text renderer, implement one before accepting requests.
pub const Draw2d = struct {
    pub fn sprite(_: Draw2d, request: Sprite) api.Error!void {
        return api.notImplemented(request);
    }
    pub fn worldText(_: Draw2d, text: []const u8, position_m: [3]f32, height_m: f32) api.Error!void {
        return api.notImplemented(.{ text, position_m, height_m });
    }
};
