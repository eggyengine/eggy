//! `Terrain`: ground drawn from a height grid (`app.heightfields()`) without the CPU making a
//! triangle. One flat patch of `patch_cells` by `patch_cells` cells is drawn many times, each
//! copy lifted to the grid's heights on the GPU, with every corner near the viewer and every
//! second, fourth and so on further off; `patches` picks them for a view, and
//! `terrain_renderer.zig` draws them, each face flat and coloured by its height and slope.
const std = @import("std");
const math = @import("eggenvector");
const Name = @import("name.zig").Name;
const Transform = @import("transform.zig").Transform;
const Bounds = @import("bounds.zig").Bounds;
const Grid = @import("heightfields.zig").Heightfields.Grid;

pub const Terrain = struct {
    /// Marks it in the editor (nf-md-terrain).
    pub const icon = "\u{f0583}";
    pub const category = "Rendering";
    /// Drawn where its `Transform` puts it.
    pub const dependencies = .{Transform};

    /// The height grid drawn (`app.heightfields()`), its first corner at the entity. Give a
    /// `Collider` a `.heightfield` shape of the same name to stand on what is drawn.
    heights: Name = .{},
    /// Faces between the low and high bands that aren't steep.
    color: [3]f32 = .{ 0.36, 0.47, 0.24 },
    low_color: [3]f32 = .{ 0.55, 0.5, 0.38 },
    /// Faces whose middle is lower than this, in the world, take `low_color`.
    low_below_m: f32 = -3,
    high_color: [3]f32 = .{ 0.6, 0.6, 0.62 },
    /// Faces whose middle is higher than this, in the world, take `high_color`.
    high_above_m: f32 = 8,
    steep_color: [3]f32 = .{ 0.43, 0.4, 0.37 },
    /// Faces whose normal points up less than this (0 a wall, 1 level) take `steep_color`,
    /// whatever their height.
    steep_normal_y: f32 = 0.8,
    /// How much lighter or darker each face may be, as a share: 0.05 is 5 %.
    shade_variation: f32 = 0.05,
    roughness: f32 = 0.9,
    /// How near the viewer, in its own widths, a patch is split into four with twice the corners.
    detail_distance: f32 = 2,
};

/// Cells along each side of a patch.
pub const patch_cells = 32;

/// One patch as the GPU draws it (`vertexTerrain` in `mesh.slang` reads it per instance).
pub const Patch = extern struct {
    /// From the grid's column, height in metres and row to the world, by column.
    model: [4][4]f32,
    /// Its first column and row, corners per cell, and how far its skirts hang in metres.
    patch: [4]f32,
    /// Each colour with its band's bound: `Terrain.color` with `shade_variation`,
    /// `low_color` with `low_below_m`, `high_color` with `high_above_m`, `steep_color` with
    /// `steep_normal_y`.
    color: [4]f32,
    low: [4]f32,
    high: [4]f32,
    steep: [4]f32,
    /// Roughness, and `patch_cells`.
    surface: [4]f32,
};

/// The most patches one terrain draws in a view; further ones are left out.
pub const max_patches = 2048;

/// The patches of `terrain` over `grid` that a view from `eye` (world space) needs, written to
/// `out`: whole patches of every corner near it, coarser further off, placed by `world_matrix`
/// (the entity's). With `clip_from_world`, only those it sees. Returns the part of `out` filled;
/// patches past its end are left out.
///
/// ```zig
/// const drawn = terrain.patches(&buffer, look, grid.*, world_matrix, view.eye, view_projection);
/// ```
pub fn patches(out: []Patch, terrain: Terrain, grid: Grid, world_matrix: math.Mat4, eye: math.Vec3, clip_from_world: ?math.Mat4) []Patch {
    const cells = [2]u32{ grid.columns - 1, grid.rows() - 1 };
    // The coarsest patch covers the whole grid.
    var step: u32 = 1;
    while (patch_cells * step < @max(cells[0], cells[1])) step *= 2;
    var model = columnsOf(world_matrix);
    for (&model[0]) |*part| part.* *= grid.cell_m;
    for (&model[2]) |*part| part.* *= grid.cell_m;
    const clip_from_local: ?[4][4]f32 = if (clip_from_world) |clip| columnsOf(math.mul(f32, 4, 4, 4, clip, math.fromArray(f32, 4, 4, model))) else null;
    // Deep enough to cover any gap a coarser neighbour leaves, which the ground hides.
    const skirt_m = grid.max_m - grid.min_m + grid.cell_m;
    const look: Patch = .{
        .model = model,
        .patch = .{ 0, 0, 0, skirt_m },
        .color = .{ terrain.color[0], terrain.color[1], terrain.color[2], terrain.shade_variation },
        .low = .{ terrain.low_color[0], terrain.low_color[1], terrain.low_color[2], terrain.low_below_m },
        .high = .{ terrain.high_color[0], terrain.high_color[1], terrain.high_color[2], terrain.high_above_m },
        .steep = .{ terrain.steep_color[0], terrain.steep_color[1], terrain.steep_color[2], terrain.steep_normal_y },
        .surface = .{ terrain.roughness, patch_cells, 0, 0 },
    };

    // A quadtree, depth first: a patch near enough to the eye is drawn as its four quarters.
    const Node = struct { column: u32, row: u32, step: u32 };
    var pending: [64]Node = undefined;
    pending[0] = .{ .column = 0, .row = 0, .step = step };
    var pending_len: usize = 1;
    var count: usize = 0;
    while (pending_len > 0) {
        pending_len -= 1;
        const node = pending[pending_len];
        if (node.column >= cells[0] or node.row >= cells[1]) continue;
        const span = patch_cells * node.step;
        const box: Bounds = .{
            .min = .{ @floatFromInt(node.column), grid.min_m - skirt_m, @floatFromInt(node.row) },
            .max = .{ @floatFromInt(@min(node.column + span, cells[0])), grid.max_m, @floatFromInt(@min(node.row + span, cells[1])) },
        };
        if (clip_from_local) |clip| if (!box.visible(clip)) continue;
        if (node.step > 1 and nearerThan(model, box, eye, terrain.detail_distance * @as(f32, @floatFromInt(span))) and pending_len + 4 <= pending.len) {
            const half = node.step / 2;
            const quarter = patch_cells * half;
            for ([_][2]u32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |corner| {
                pending[pending_len] = .{ .column = node.column + corner[0] * quarter, .row = node.row + corner[1] * quarter, .step = half };
                pending_len += 1;
            }
            continue;
        }
        if (count == out.len) break;
        out[count] = look;
        out[count].patch = .{ @floatFromInt(node.column), @floatFromInt(node.row), @floatFromInt(node.step), skirt_m };
        count += 1;
    }
    return out[0..count];
}

/// Whether `eye` is within `cells` cells' width (along x, where `model` places them) of `box`.
fn nearerThan(model: [4][4]f32, box: Bounds, eye: math.Vec3, cells: f32) bool {
    const min = place(model, box.min);
    const max = place(model, box.max);
    const centre = min.add(max).scale(0.5);
    const radius = max.sub(min).length() / 2;
    const cell_m = math.Vec3.init(model[0][0], model[0][1], model[0][2]).length();
    return eye.sub(centre).length() - radius < cells * cell_m;
}

fn place(model: [4][4]f32, at: [3]f32) math.Vec3 {
    var out: [3]f32 = undefined;
    for (&out, 0..) |*part, axis| part.* = model[0][axis] * at[0] + model[1][axis] * at[1] + model[2][axis] * at[2] + model[3][axis];
    return .init(out[0], out[1], out[2]);
}

fn columnsOf(m: math.Mat4) [4][4]f32 {
    var out: [4][4]f32 = undefined;
    for (&out, m.data) |*column, data| column.* = data;
    return out;
}

test "patches are fine near the eye and coarse far off, and none are made for what is out of sight" {
    // 1025 by 1025 corners two metres apart: two kilometres across.
    const side = 1025;
    const heights = try std.testing.allocator.alloc(f32, side * side);
    defer std.testing.allocator.free(heights);
    @memset(heights, 0);
    const grid: Grid = .{ .heights = heights, .columns = side, .cell_m = 2, .min_m = 0, .max_m = 0 };
    var buffer: [max_patches]Patch = undefined;
    const eye = math.Vec3.init(1, 2, 1);
    const all = patches(&buffer, .{}, grid, math.identity(f32, 4), eye, null);
    // Every corner beside the eye, every eighth at the far side, and far fewer patches than
    // the 1,024 a grid of full-detail ones would take.
    var finest: f32 = std.math.inf(f32);
    var coarsest: f32 = 0;
    for (all) |patch| {
        const near = patch.patch[0] == 0 and patch.patch[1] == 0;
        if (near) finest = patch.patch[2];
        coarsest = @max(coarsest, patch.patch[2]);
    }
    try std.testing.expectEqual(@as(f32, 1), finest);
    try std.testing.expectEqual(@as(f32, 8), coarsest);
    try std.testing.expect(all.len < 100);

    // Looking away from the grid, out past its corner: nothing.
    const away = math.mul(f32, 4, 4, 4, math.perspective(1.2, 1, 0.1, 5000), math.lookAt(math.Vec3.init(-10, 2, -10), math.Vec3.init(-20, 2, -20), math.Vec3.init(0, 1, 0)));
    try std.testing.expectEqual(@as(usize, 0), patches(&buffer, .{}, grid, math.identity(f32, 4), math.Vec3.init(-10, 2, -10), away).len);
}
