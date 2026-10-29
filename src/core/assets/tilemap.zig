//! The `.tilemap.zon` format: a grid of tiles, each a frame of a tileset image cut into
//! `columns` by `rows`, and the model that draws it (one quad per tile). The image itself is the
//! `Tilemap` component's, so one map can be drawn with different tilesets.
//!
//!     .{ .columns = 8, .rows = 4, .width = 3, .height = 2, .tiles = .{ 1, 0, 2, 9, 9, 9 } }
//!
//! `tiles` holds `width * height` entries, row by row from the top: 0 is empty, and `n` is the
//! tileset's frame `n - 1`, numbered left to right, top to bottom. The map's top-left corner is
//! at its origin, x to the right and y up, one unit per tile.
const std = @import("std");
const zon_file = @import("zon.zig");
const model_format = @import("model.zig");

pub const extension = ".tilemap.zon";

/// A new map: 16 by 16 tiles, all empty, with a tileset of one frame. Edit `columns` and `rows`
/// to how the tileset is cut.
pub const template = blk: {
    const side = 16;
    var text: []const u8 = ".{\n    .columns = 1,\n    .rows = 1,\n    .width = 16,\n    .height = 16,\n    .tiles = .{";
    for (0..side) |_| {
        text = text ++ "\n        ";
        for (0..side) |_| text = text ++ "0, ";
    }
    break :blk text ++ "\n    },\n}\n";
};

/// The most tiles a map may hold, so a file can't ask for unbounded memory.
pub const max_tiles = 512 * 512;

pub const Map = struct {
    /// How the tileset image is cut: frames across, and down.
    columns: u16 = 1,
    rows: u16 = 1,
    /// Tiles across and down.
    width: u16,
    height: u16,
    tiles: []u16,

    /// An empty map of `width` by `height`, owned by the caller (`deinit`).
    pub fn initEmpty(gpa: std.mem.Allocator, columns: u16, rows: u16, width: u16, height: u16) !Map {
        const tiles = try gpa.alloc(u16, @as(usize, width) * height);
        @memset(tiles, 0);
        return .{ .columns = columns, .rows = rows, .width = width, .height = height, .tiles = tiles };
    }

    pub fn deinit(self: Map, gpa: std.mem.Allocator) void {
        gpa.free(self.tiles);
    }

    /// The tile at column `x`, row `y` from the top; null outside the map.
    pub fn at(self: Map, x: i32, y: i32) ?*u16 {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return null;
        return &self.tiles[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))];
    }

    /// The tile under the point (`x`, `y`) of the map's own space (one unit per tile, y up from
    /// its top edge), as column and row; null outside the map.
    pub fn cellAt(self: Map, x: f32, y: f32) ?[2]i32 {
        const column: i32 = @intFromFloat(@floor(x));
        const row: i32 = @intFromFloat(@floor(-y));
        if (self.at(column, row) == null) return null;
        return .{ column, row };
    }

    pub fn write(self: Map, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(".{{\n    .columns = {d},\n    .rows = {d},\n    .width = {d},\n    .height = {d},\n    .tiles = .{{", .{ self.columns, self.rows, self.width, self.height });
        // One line per row of the map, so the file reads as the map looks.
        for (0..self.height) |row| {
            try writer.writeAll("\n        ");
            for (self.tiles[row * self.width ..][0..self.width]) |tile| try writer.print("{d}, ", .{tile});
        }
        try writer.writeAll("\n    },\n}\n");
    }

    /// The quads that draw it: one per tile showing its tileset frame, plus a triangle of no
    /// area across the whole map so its bounds (and picking) cover the empty parts too.
    /// The caller owns the model (`deinit`).
    pub fn buildModel(self: Map, gpa: std.mem.Allocator) !model_format.Model {
        var vertices: std.ArrayList(model_format.Vertex) = .empty;
        errdefer vertices.deinit(gpa);
        var indices: std.ArrayList(u32) = .empty;
        errdefer indices.deinit(gpa);
        const front = [3]f32{ 0, 0, 1 };
        const width: f32 = @floatFromInt(self.width);
        const height: f32 = @floatFromInt(self.height);
        try vertices.appendSlice(gpa, &.{ .{ .position = .{ 0, 0, 0 }, .normal = front }, .{ .position = .{ width, -height, 0 }, .normal = front } });
        try indices.appendSlice(gpa, &.{ 0, 1, 0 });

        const columns: u32 = @max(1, self.columns);
        const rows: u32 = @max(1, self.rows);
        for (0..self.height) |row| for (0..self.width) |column| {
            const tile = self.tiles[row * self.width + column];
            if (tile == 0) continue;
            const frame = tile - 1;
            // The frame's part of the tileset, inset by a sliver so neighbours don't bleed in.
            const inset = 0.001;
            const left_u = (@as(f32, @floatFromInt(frame % columns)) + inset) / @as(f32, @floatFromInt(columns));
            const top_v = (@as(f32, @floatFromInt(@min(frame / columns, rows - 1))) + inset) / @as(f32, @floatFromInt(rows));
            const right_u = left_u + (1 - 2 * inset) / @as(f32, @floatFromInt(columns));
            const bottom_v = top_v + (1 - 2 * inset) / @as(f32, @floatFromInt(rows));
            const left: f32 = @floatFromInt(column);
            const top = -@as(f32, @floatFromInt(row));
            const first: u32 = @intCast(vertices.items.len);
            try vertices.appendSlice(gpa, &.{
                .{ .position = .{ left, top - 1, 0 }, .normal = front, .uv = .{ left_u, bottom_v } },
                .{ .position = .{ left + 1, top - 1, 0 }, .normal = front, .uv = .{ right_u, bottom_v } },
                .{ .position = .{ left + 1, top, 0 }, .normal = front, .uv = .{ right_u, top_v } },
                .{ .position = .{ left, top, 0 }, .normal = front, .uv = .{ left_u, top_v } },
            });
            try indices.appendSlice(gpa, &.{ first, first + 1, first + 2, first, first + 2, first + 3 });
        };

        const parts = try gpa.dupe(model_format.Part, &.{.{ .first_index = 0, .index_count = @intCast(indices.items.len) }});
        errdefer gpa.free(parts);
        const owned_indices = try indices.toOwnedSlice(gpa);
        errdefer gpa.free(owned_indices);
        return .{ .vertices = try vertices.toOwnedSlice(gpa), .indices = owned_indices, .parts = parts, .textures = &.{} };
    }
};

/// Read a `.tilemap.zon`; the caller owns the result (`deinit`). Fails with `error.ParseZon` for
/// text that isn't one and `error.InvalidTilemap` when its tiles don't fill its size.
///
/// ```zig
/// const map = try tilemap.parse(gpa, source);
/// defer map.deinit(gpa);
/// ```
pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !Map {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const parsed = try zon_file.parse(Map, arena.allocator(), source, .{ .ignore_unknown_fields = true });
    const count = @as(usize, parsed.width) * parsed.height;
    if (count > max_tiles or parsed.tiles.len != count) return error.InvalidTilemap;
    var owned = parsed;
    owned.tiles = try gpa.dupe(u16, parsed.tiles);
    return owned;
}

test "a new map's template reads as an empty 16 by 16 map" {
    const map = try parse(std.testing.allocator, template);
    defer map.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 256), map.tiles.len);
}

test "a map written out reads back the same, row by row" {
    const gpa = std.testing.allocator;
    var map = try Map.initEmpty(gpa, 4, 2, 3, 2);
    defer map.deinit(gpa);
    map.at(2, 0).?.* = 5;
    map.at(0, 1).?.* = 1;
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try map.write(&text.writer);
    const source = try gpa.dupeSentinel(u8, text.written(), 0);
    defer gpa.free(source);
    const read = try parse(gpa, source);
    defer read.deinit(gpa);
    try std.testing.expectEqualSlices(u16, &.{ 0, 0, 5, 1, 0, 0 }, read.tiles);
    try std.testing.expectError(error.InvalidTilemap, parse(gpa, ".{ .width = 2, .height = 2, .tiles = .{ 1, 2, 3 } }"));
}

test "each tile becomes a quad showing its tileset frame, and points find their tile" {
    const gpa = std.testing.allocator;
    var map = try Map.initEmpty(gpa, 4, 2, 3, 2);
    defer map.deinit(gpa);
    map.at(1, 1).?.* = 6; // frame 5: column 1 of the second row
    var built = try map.buildModel(gpa);
    defer built.deinit(gpa);
    // The bounds triangle, then one quad.
    try std.testing.expectEqual(@as(usize, 2 + 4), built.vertices.len);
    try std.testing.expectEqual(@as(usize, 3 + 6), built.indices.len);
    const corner = built.vertices[2 + 3];
    try std.testing.expectEqual([3]f32{ 1, -1, 0 }, corner.position);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), corner.uv[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), corner.uv[1], 0.001);
    try std.testing.expectEqual([2]i32{ 2, 1 }, map.cellAt(2.5, -1.2).?);
    try std.testing.expect(map.cellAt(3.1, -0.5) == null);
    try std.testing.expect(map.cellAt(0.5, 0.2) == null);
}
