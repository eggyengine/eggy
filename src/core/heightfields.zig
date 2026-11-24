//! Height grids a game makes in code, kept by name: a `Collider` whose shape is `.heightfield`
//! collides with one, and a `Terrain` draws one, its triangles made on the GPU, so the ground
//! seen and the ground stood on agree. Setting a name again replaces its heights; drawing picks
//! them up next frame, and colliders made from it are rebuilt (`physics.remesh`). CPU data only,
//! so a game library may change it in the editor.
const std = @import("std");
const Name = @import("name.zig").Name;
const ByName = @import("by_name.zig").ByName;

/// The world's resource pointing physics at the grids (`App.updateWorld` inserts it).
pub const Ref = struct { heightfields: *const Heightfields };

pub const Heightfields = struct {
    gpa: std.mem.Allocator,
    grids: ByName(Grid) = .{},

    /// Heights in metres, row by row: `columns` corners along x, `rows()` along z, `cell_m`
    /// apart both ways, the first at its entity's origin. Each cell is two triangles, split from
    /// its first corner to the one across.
    pub const Grid = struct {
        heights: []f32,
        columns: u32,
        cell_m: f32,
        /// The lowest and highest of `heights`.
        min_m: f32,
        max_m: f32,
        /// Counts every set, so a cache can tell an old upload from the current heights.
        version: u32 = 0,

        pub fn rows(self: Grid) u32 {
            return @intCast(self.heights.len / self.columns);
        }

        /// The height at `column`, `row`.
        pub fn at(self: Grid, column: u32, row: u32) f32 {
            return self.heights[row * self.columns + column];
        }
    };

    pub const Error = error{ InvalidName, InvalidGrid } || std.mem.Allocator.Error;

    pub fn init(gpa: std.mem.Allocator) Heightfields {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Heightfields) void {
        var it = self.grids.entries.valueIterator();
        while (it.next()) |grid| self.gpa.free(grid.heights);
        self.grids.deinit(self.gpa);
    }

    /// Make the grid `name` `heights` (row by row, `columns` along x), `cell_m` apart, copied,
    /// replacing any it had. At least two columns and two rows; a name is 1 to `Name.max_len`
    /// bytes and not an asset key (16 hex digits).
    ///
    /// ```zig
    /// try app.heightfields().set("ground", heights, 33, 2);
    /// _ = try app.world.spawn(.{ eggy.Transform{}, eggy.Terrain{ .heights = .init("ground") }, eggy.physics.Collider{ .shape = .{ .heightfield = .init("ground") } } });
    /// ```
    pub fn set(self: *Heightfields, name: []const u8, heights: []const f32, columns: u32, cell_m: f32) Error!void {
        try ByName(Grid).check(name);
        if (columns < 2 or heights.len < 2 * @as(usize, columns) or heights.len % columns != 0) return error.InvalidGrid;
        if (!(cell_m > 0) or !std.math.isFinite(cell_m)) return error.InvalidGrid;
        var low: f32 = heights[0];
        var high: f32 = heights[0];
        for (heights) |h| {
            if (!std.math.isFinite(h)) return error.InvalidGrid;
            low = @min(low, h);
            high = @max(high, h);
        }
        const owned = try self.gpa.dupe(f32, heights);
        errdefer self.gpa.free(owned);
        const old = try self.grids.put(self.gpa, name, .{ .heights = owned, .columns = columns, .cell_m = cell_m, .min_m = low, .max_m = high });
        if (old) |replaced| self.gpa.free(replaced.heights);
    }

    /// Forget the grid `name`; `Terrain`s naming it draw nothing, and colliders made from it go.
    pub fn remove(self: *Heightfields, name: []const u8) void {
        const removed = self.grids.remove(self.gpa, name) orelse return;
        self.gpa.free(removed.heights);
    }

    /// The grid `name`, borrowed until it is next set or removed.
    pub fn get(self: *const Heightfields, name: []const u8) ?*const Grid {
        return self.grids.get(name);
    }

    /// The names set or removed since the last call, borrowed until the next `set` or `remove`;
    /// the list is emptied for the next call.
    pub fn takeChanged(self: *Heightfields) []const Name {
        return self.grids.takeChanged();
    }
};
