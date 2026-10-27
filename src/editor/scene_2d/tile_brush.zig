//! The 2D Scene panel's tile brush: with the selection's `Tilemap` and Paint on, a click or drag
//! paints the tile picked in the palette (the tileset, cut as the map file says), Shift erases
//! and Alt picks up the tile under the pointer. Every change rewrites the `.tilemap.zon` and
//! rebuilds its model, so painting shows at once; each stroke is one History step.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const assets = eggy.assets;
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
const ProjectAssets = @import("../assets/project_assets.zig").ProjectAssets;
const History = @import("../history.zig").History;

/// What the brush reads and writes through, borrowed for each call.
pub const Env = struct {
    gpa: std.mem.Allocator,
    app: *eggy.App,
    game: *const HotGame,
    assets: *ProjectAssets,
    project_dir: []const u8,
    history: *History,
    now_ms: u64,
};

/// How tall the palette is drawn, at most.
pub const palette_height_px: f32 = 96;
/// The Tilemap component's fields, in order.
const map_field = 0;
const tileset_field = 1;

pub const Brush = struct {
    painting: bool = false,
    /// The tileset frame painted.
    tile: u16 = 0,
    /// The selection's tilemap, while it has one.
    target: ?Target = null,
    /// The stroke being painted: the file's text before it, and the last cell changed.
    stroke: ?Stroke = null,
    /// The tileset's images for the palette.
    images: ?eggy.ui_scenes.cache.Images = null,
    /// Where the palette was laid out last frame.
    palette_area: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub const Target = struct {
        entity: eggy.ecs.EntityId,
        map_key: [assets.id.key_len]u8,
        map_key_len: usize,
        tileset_key: [assets.id.key_len]u8,
        tileset_key_len: usize,
        columns: u16,
        rows: u16,

        fn mapKey(self: *const Target) []const u8 {
            return self.map_key[0..self.map_key_len];
        }

        fn tilesetKey(self: *const Target) []const u8 {
            return self.tileset_key[0..self.tileset_key_len];
        }
    };

    const Stroke = struct { path: []u8, before: []u8, last: ?[2]i32 = null };

    pub fn deinit(self: *Brush, gpa: std.mem.Allocator) void {
        if (self.stroke) |stroke| {
            gpa.free(stroke.path);
            gpa.free(stroke.before);
        }
        if (self.images) |*images| images.deinit();
    }

    /// Find the tilemap of `selected` (none: no target), reading its file for how the tileset is
    /// cut when the map changes. Call each frame before the panel is built.
    pub fn follow(self: *Brush, env: Env, selected: ?eggy.ecs.EntityId) void {
        const entity = selected orelse return self.drop();
        const component = env.game.builtinComponent("Tilemap") orelse return self.drop();
        var map_buffer: [64]u8 = undefined;
        var tileset_buffer: [64]u8 = undefined;
        const map_key = unquote(env.game.readField(env.app, entity, component, map_field, &map_buffer) orelse return self.drop());
        const tileset_key = unquote(env.game.readField(env.app, entity, component, tileset_field, &tileset_buffer) orelse return self.drop());
        if (map_key.len == 0 or map_key.len > assets.id.key_len or tileset_key.len > assets.id.key_len) return self.drop();
        // The same map as last frame: nothing to read again.
        if (self.target) |*known| if (known.entity.id == entity.id and known.entity.generation == entity.generation and std.mem.eql(u8, known.mapKey(), map_key)) {
            @memcpy(known.tileset_key[0..tileset_key.len], tileset_key);
            known.tileset_key_len = tileset_key.len;
            return;
        };
        const map = self.readMap(env, map_key) orelse return self.drop();
        defer map.deinit(env.gpa);
        var target = Target{ .entity = entity, .map_key = undefined, .map_key_len = map_key.len, .tileset_key = undefined, .tileset_key_len = tileset_key.len, .columns = map.columns, .rows = map.rows };
        @memcpy(target.map_key[0..map_key.len], map_key);
        @memcpy(target.tileset_key[0..tileset_key.len], tileset_key);
        self.target = target;
        self.tile = @intCast(@min(self.tile, (@as(u32, map.columns) * map.rows) -| 1));
    }

    fn drop(self: *Brush) void {
        self.target = null;
    }

    /// The Paint toggle and, while painting, the palette: the tileset with its frames outlined
    /// and the one painted highlighted. Clicking a frame picks it. Nothing without a target.
    pub fn build(self: *Brush, context: *ui.Context, app: *eggy.App, gpa: std.mem.Allocator) void {
        const target = self.target orelse return;
        context.begin(.row);
        _ = context.toggle("Paint tiles", &self.painting);
        if (self.painting) context.muted(std.fmt.allocPrint(context.builder().allocator, "tile {d}   Shift: erase   Alt: pick", .{self.tile}) catch "");
        context.end();
        if (!self.painting) return;

        if (self.images == null) self.images = .{ .gpa = gpa };
        const image = self.images.?.get(app.resources(), context.font, target.tilesetKey()) orelse {
            context.muted("Set the Tilemap's tileset to paint with it.");
            return;
        };
        const w: f32 = @floatFromInt(image.width);
        const h: f32 = @floatFromInt(image.height);
        const fit = @min(palette_height_px / h, context.contentWidth() / w);
        const b = context.builder();
        const id: u32 = 0x5200_0001;
        const overlay = b.node(0, .{ .width = w * fit, .height = h * fit }, .{ .custom = .{ .context = self, .draw = drawPalette } }, &.{}) catch return;
        const picture = b.node(id, .{ .width = w * fit, .height = h * fit }, .{ .image = image.frameAt(0) }, &.{overlay}) catch return;
        picture.cursor = .pointer;
        context.element(picture);
        if (context.activated(id)) self.pickFromPalette(context.pointer);
    }

    /// The frame under `at` on the palette becomes the one painted.
    fn pickFromPalette(self: *Brush, at: ui.Vec2) void {
        const target = self.target orelse return;
        const area = self.palette_area;
        if (!area.contains(at.x, at.y)) return;
        const column: u16 = @intFromFloat(@floor((at.x - area.x) / area.w * @as(f32, @floatFromInt(target.columns))));
        const row: u16 = @intFromFloat(@floor((at.y - area.y) / area.h * @as(f32, @floatFromInt(target.rows))));
        self.tile = @min(row, target.rows - 1) * target.columns + @min(column, target.columns - 1);
    }

    /// Whether a press at the map-space point `local` (tiles, y up from the top edge) starts a
    /// stroke: painting is on and the point is on the map. Alt picks the tile there instead.
    pub fn press(self: *Brush, env: Env, local: [2]f32, erase: bool, pick: bool) bool {
        if (!self.painting) return false;
        const target = self.target orelse return false;
        const path = env.assets.label(env.gpa, target.mapKey());
        defer if (path.ptr != target.mapKey().ptr) env.gpa.free(path);
        const map = self.readMap(env, target.mapKey()) orelse return false;
        defer map.deinit(env.gpa);
        const cell = map.cellAt(local[0], local[1]) orelse return false;
        if (pick) {
            const tile = map.at(cell[0], cell[1]).?.*;
            if (tile > 0) self.tile = tile - 1;
            return true;
        }
        const before = self.readText(env, target.mapKey()) orelse return false;
        self.stroke = .{ .path = env.gpa.dupe(u8, path) catch {
            env.gpa.free(before);
            return false;
        }, .before = before };
        self.paint(env, local, erase);
        return true;
    }

    /// Paint (or erase) the cell under `local` during a stroke, once per cell.
    pub fn paint(self: *Brush, env: Env, local: [2]f32, erase: bool) void {
        const stroke = &(self.stroke orelse return);
        const target = self.target orelse return;
        var map = self.readMap(env, target.mapKey()) orelse return;
        defer map.deinit(env.gpa);
        const cell = map.cellAt(local[0], local[1]) orelse return;
        if (stroke.last) |last| if (last[0] == cell[0] and last[1] == cell[1]) return;
        stroke.last = cell;
        const wanted: u16 = if (erase) 0 else self.tile + 1;
        const slot = map.at(cell[0], cell[1]).?;
        if (slot.* == wanted) return;
        slot.* = wanted;
        self.writeMap(env, stroke.path, map, target.mapKey()) catch |err| std.log.err("cannot paint {s}: {t}", .{ stroke.path, err });
    }

    /// End the stroke: one History step from the file before it to the file now.
    pub fn release(self: *Brush, env: Env) bool {
        const stroke = self.stroke orelse return false;
        self.stroke = null;
        const target = self.target orelse {
            env.gpa.free(stroke.path);
            env.gpa.free(stroke.before);
            return true;
        };
        const after = self.readText(env, target.mapKey()) orelse {
            env.gpa.free(stroke.path);
            env.gpa.free(stroke.before);
            return true;
        };
        if (std.mem.eql(u8, stroke.before, after)) {
            env.gpa.free(stroke.path);
            env.gpa.free(stroke.before);
            env.gpa.free(after);
            return true;
        }
        env.history.record(.{ .tilemap = .{ .path = stroke.path, .text = .{ .before = stroke.before, .after = after } } });
        return true;
    }

    /// Whether a stroke is under way, so the scene isn't recorded mid-stroke.
    pub fn stroking(self: *const Brush) bool {
        return self.stroke != null;
    }

    fn readText(_: *const Brush, env: Env, key: []const u8) ?[]u8 {
        const path = env.assets.label(env.gpa, key);
        defer if (path.ptr != key.ptr) env.gpa.free(path);
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, env.project_dir, .{}) catch return null;
        defer dir.close(io);
        return dir.readFileAlloc(io, path, env.gpa, .limited(16 << 20)) catch |err| {
            std.log.err("cannot read the tilemap {s}: {t}", .{ path, err });
            return null;
        };
    }

    fn readMap(self: *const Brush, env: Env, key: []const u8) ?assets.tilemap.Map {
        const text = self.readText(env, key) orelse return null;
        defer env.gpa.free(text);
        const source = env.gpa.dupeSentinel(u8, text, 0) catch return null;
        defer env.gpa.free(source);
        return assets.tilemap.parse(env.gpa, source) catch |err| {
            std.log.err("cannot read the tilemap {s}: {t}", .{ key, err });
            return null;
        };
    }

    /// Write `map` to `path` and build its model again.
    fn writeMap(_: *const Brush, env: Env, path: []const u8, map: assets.tilemap.Map, key: []const u8) !void {
        var text: std.Io.Writer.Allocating = .init(env.gpa);
        defer text.deinit();
        try map.write(&text.writer);
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, env.project_dir, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = path, .data = text.written() });
        try env.app.graphics.queue.waitIdle();
        env.app.graphics.models.forget(key, &env.app.graphics.textures);
    }
};

/// An asset field's ZON text (`"1a2b..."`) without its quotes.
fn unquote(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, "\" ");
}

// The tileset's frames outlined, the one painted filled in; and where the palette went.
fn drawPalette(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const self: *Brush = @ptrCast(@alignCast(@constCast(context)));
    self.palette_area = r;
    const target = self.target orelse return;
    const cell_w = r.w / @as(f32, @floatFromInt(target.columns));
    const cell_h = r.h / @as(f32, @floatFromInt(target.rows));
    for (1..target.columns) |i| try c.rectAlpha(.{ .x = r.x + cell_w * @as(f32, @floatFromInt(i)), .y = r.y, .w = 1, .h = r.h }, c.theme.foreground, 0.35);
    for (1..target.rows) |i| try c.rectAlpha(.{ .x = r.x, .y = r.y + cell_h * @as(f32, @floatFromInt(i)), .w = r.w, .h = 1 }, c.theme.foreground, 0.35);
    const column: f32 = @floatFromInt(self.tile % target.columns);
    const row: f32 = @floatFromInt(self.tile / target.columns);
    try c.roundRectStroke(.{ .x = r.x + column * cell_w, .y = r.y + row * cell_h, .w = cell_w, .h = cell_h }, c.theme.primary, 0, 2);
}

test "a field's quoted key reads without its quotes" {
    try std.testing.expectEqualStrings("12ab", unquote("\"12ab\""));
}
