//! `Sprite`: an image drawn flat on an entity, facing +z (the 2D Scene panel's way), a built-in
//! component. `mesh.gather` turns each into a quad drawable, so sprites are picked, outlined and
//! hidden like meshes; this file says which part of the image shows and how big it is.
const std = @import("std");
const Transform = @import("transform.zig").Transform;
const AssetRef = @import("refs.zig").AssetRef;

/// How far one sorting layer sits in front of the one below it, in metres along +z.
// ponytail: sprites sort by depth with an alpha cutout, not by blending; semi-transparent
// pixels show as opaque. Add a blended, back-to-front sprite pass if soft edges are needed.
pub const layer_step_m: f32 = 0.001;

pub const Sprite = struct {
    /// Marks it in the editor (nf-md-image_outline).
    pub const icon = "\u{f0976}";
    /// Drawn where its `Transform` puts it.
    pub const dependencies = .{Transform};

    image: AssetRef(.image) = .{},
    /// Width and height in metres, before the `Transform`'s scale.
    size_m: [2]f32 = .{ 1, 1 },
    /// Red, green, blue and alpha, 0 to 1, multiplied with the image.
    color: [4]f32 = .{ 1, 1, 1, 1 },
    /// The part of the image shown, as fractions of it: left, top, right, bottom. A sprite
    /// sheet's frame, or a tileset's tile.
    region: [4]f32 = .{ 0, 0, 1, 1 },
    flip_x: bool = false,
    flip_y: bool = false,
    /// Higher layers draw over lower ones, whatever their `Transform`'s z.
    layer: i32 = 0,
    /// Pixels with less alpha than this aren't drawn.
    alpha_cutoff: f32 = 0.5,

    /// The image's texture coordinates to draw, flipped as asked: left, top, right, bottom.
    pub fn uvRect(self: Sprite) [4]f32 {
        var rect = self.region;
        if (self.flip_x) std.mem.swap(f32, &rect[0], &rect[2]);
        if (self.flip_y) std.mem.swap(f32, &rect[1], &rect[3]);
        return rect;
    }

    /// `world`, the entity's matrix (columns), stretched to the sprite's size and lifted by its
    /// layer, for the one-metre quad.
    pub fn placed(self: Sprite, world: [4][4]f32) [4][4]f32 {
        var model = world;
        for (0..3) |row| {
            model[0][row] *= self.size_m[0];
            model[1][row] *= self.size_m[1];
        }
        const lift = @as(f32, @floatFromInt(self.layer)) * layer_step_m;
        for (0..3) |row| model[3][row] += world[2][row] * lift;
        return model;
    }
};

test "flipping swaps the region's edges, and the size stretches the quad's axes" {
    const sprite = Sprite{ .region = .{ 0.25, 0, 0.5, 1 }, .flip_x = true, .size_m = .{ 2, 3 }, .layer = 10 };
    try std.testing.expectEqual([4]f32{ 0.5, 0, 0.25, 1 }, sprite.uvRect());
    const identity = [4][4]f32{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 4, 5, 0, 1 } };
    const model = sprite.placed(identity);
    try std.testing.expectEqual([4]f32{ 2, 0, 0, 0 }, model[0]);
    try std.testing.expectEqual([4]f32{ 0, 3, 0, 0 }, model[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 10 * layer_step_m), model[3][2], 1e-6);
}
