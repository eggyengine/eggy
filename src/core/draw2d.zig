//! Frame-owned world sprites and camera-facing text, separate from screen-space game UI.
const std = @import("std");
const math = @import("eggenvector");
const AssetRef = @import("refs.zig").AssetRef;
pub const support: @import("support.zig").Support = .available;

/// An unlit XY-plane quad, centred at position, measured in world metres.
/// Atlas UVs are {left, top, right, bottom}; higher layers draw later.
pub const Sprite = struct {
    /// None draws a plain square of `tint`.
    image: AssetRef(.image),
    position: math.Vec2 = .zero,
    depth_m: f32 = 0,
    size: math.Vec2 = .one,
    tint: [4]f32 = @splat(1),
    uv_rect: [4]f32 = .{ 0, 0, 1, 1 },
    rotation_deg: f32 = 0,
    layer: i32 = 0,
    billboard: bool = false,
};

pub const Text = struct { value: []u8, position_m: math.Vec3, height_m: f32, order: usize };
const SpriteRequest = struct { value: Sprite, order: usize };

/// Main-thread requests are copied until the next host frame. Text is UTF-8, anchored at
/// its left baseline, camera-facing and depth-tested; sprites do not capture input.
pub const Draw2d = struct {
    gpa: std.mem.Allocator = std.heap.c_allocator,
    sprites: std.ArrayList(SpriteRequest) = .empty,
    labels: std.ArrayList(Text) = .empty,

    pub fn sprite(self: *Draw2d, request: Sprite) !void {
        for (request.position.toArray()) |value| if (!std.math.isFinite(value)) return error.InvalidSprite;
        for (request.size.toArray()) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSprite;
        for (request.tint) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSprite;
        for (request.uv_rect) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSprite;
        if (!std.math.isFinite(request.depth_m) or !std.math.isFinite(request.rotation_deg) or
            request.uv_rect[0] > request.uv_rect[2] or request.uv_rect[1] > request.uv_rect[3]) return error.InvalidSprite;
        try self.sprites.append(self.gpa, .{ .value = request, .order = self.sprites.items.len + self.labels.items.len });
    }

    /// Copy UTF-8 text; height is the nominal font size in world metres, not screen pixels.
    pub fn worldText(self: *Draw2d, text: []const u8, position_m: math.Vec3, height_m: f32) !void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        for (position_m.toArray()) |value| if (!std.math.isFinite(value)) return error.InvalidTextPosition;
        if (!std.math.isFinite(height_m) or height_m <= 0) return error.InvalidTextHeight;
        const owned = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned);
        try self.labels.append(self.gpa, .{ .value = owned, .position_m = position_m, .height_m = height_m, .order = self.sprites.items.len + self.labels.items.len });
    }

    pub fn clear(self: *Draw2d) void {
        for (self.labels.items) |label| self.gpa.free(label.value);
        self.labels.clearRetainingCapacity();
        self.sprites.clearRetainingCapacity();
    }

    pub fn deinit(self: *Draw2d) void {
        self.clear();
        self.labels.deinit(self.gpa);
        self.sprites.deinit(self.gpa);
    }
};
