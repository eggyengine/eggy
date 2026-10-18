//! Sprite and world-text request contracts, separate from working Weeoui UI.
const api = @import("support.zig");
const AssetRef = @import("refs.zig").AssetRef;
pub const support: api.Support = .not_implemented;
pub const Sprite = struct { image: AssetRef(.image), position: [2]f32 = .{ 0, 0 }, size: [2]f32 = .{ 1, 1 }, tint: [4]f32 = @splat(1) };

/// Transient drawing requests; borrowed text lasts only for the call.
// ponytail: there is no sprite/world-text renderer, implement one before accepting requests.
pub const Draw2d = struct {
    /// Request an image with 2D position/size and RGBA tint. The world-sprite coordinate
    /// convention is not implemented; this is not Weeoui or a screen-space UI command.
    /// Currently returns `NotImplemented`, without loading the image or queuing a draw.
    ///
    /// ```zig
    /// try app.draw2d.sprite(.{ .image = .init("resources/images/player.png") });
    /// // Currently returns NotImplemented.
    /// ```
    pub fn sprite(_: Draw2d, request: Sprite) api.Error!void {
        return api.notImplemented(request);
    }
    /// Request borrowed text at a 3D world position and glyph height in metres.
    /// Currently returns `NotImplemented`; text is not retained and no font/draw is created.
    /// Use Weeoui for working screen-space labels.
    ///
    /// ```zig
    /// try app.draw2d.worldText("Checkpoint", .{ 0, 2, 0 }, 0.25); // NotImplemented.
    /// ```
    pub fn worldText(_: Draw2d, text: []const u8, position_m: [3]f32, height_m: f32) api.Error!void {
        return api.notImplemented(.{ text, position_m, height_m });
    }
};
