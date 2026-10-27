//! `Tilemap`: a `.tilemap.zon` grid of tiles drawn flat on an entity with a tileset image, a
//! built-in component. The model cache builds each map file into one model (a quad per tile,
//! `eggy.assets.tilemap`), so a whole map is one drawable: `mesh.gather` lists it, and the
//! editor picks, outlines and hides it like a mesh. The 2D Scene panel paints its tiles.
const std = @import("std");
const Transform = @import("transform.zig").Transform;
const AssetRef = @import("refs.zig").AssetRef;
const sprite = @import("sprite.zig");

pub const Tilemap = struct {
    /// Marks it in the editor (nf-md-grid).
    pub const icon = "\u{f02c1}";
    /// Drawn where its `Transform` puts it, its top-left corner at the entity.
    pub const dependencies = .{Transform};

    /// The tiles: a `.tilemap.zon`, which also says how the tileset is cut.
    map: AssetRef(.tilemap) = .{},
    /// The image the tiles are cut from.
    tileset: AssetRef(.image) = .{},
    /// How wide and tall each tile is, in metres, before the `Transform`'s scale.
    tile_size_m: f32 = 1,
    /// Red, green, blue and alpha, 0 to 1, multiplied with the tileset.
    color: [4]f32 = .{ 1, 1, 1, 1 },
    /// Higher layers draw over lower ones, as `Sprite`s' do.
    layer: i32 = 0,
    /// Pixels with less alpha than this aren't drawn.
    alpha_cutoff: f32 = 0.5,

    /// `world`, the entity's matrix (columns), scaled to the tile size and lifted by its layer,
    /// for the map's model (one unit per tile).
    pub fn placed(self: Tilemap, world: [4][4]f32) [4][4]f32 {
        return (sprite.Sprite{ .size_m = .{ self.tile_size_m, self.tile_size_m }, .layer = self.layer }).placed(world);
    }
};
