//! What UI scenes are drawn from, loaded once: parsed `.ui.zon`s (`Scenes`) and decoded images
//! packed into a font's color atlas (`Images`), GIFs with every frame. Both load through the
//! executable's resources on first use and remember failures until told to forget.
const std = @import("std");
const ui = @import("weeoui");
const assets = @import("eggy_assets");
const ui_scene = assets.ui_scene;
const Resources = @import("../resources/resources.zig").Resources;
const AssetRef = @import("../refs.zig").AssetRef;
const log = std.log.scoped(.ui_scenes);

/// Parsed UI scenes by asset key. Pointers it hands out stay valid until `forget` or `deinit`.
pub const Scenes = struct {
    gpa: std.mem.Allocator,
    /// Null where the file couldn't be read or parsed (logged once).
    entries: std.StringHashMapUnmanaged(?*ui_scene.Parsed) = .empty,

    pub fn deinit(self: *Scenes) void {
        self.forgetAll();
        self.entries.deinit(self.gpa);
    }

    /// The scene with asset `key`, read and parsed through `resources` the first time.
    pub fn get(self: *Scenes, resources: Resources, key: []const u8) ?*const ui_scene.UiScene {
        if (key.len == 0) return null;
        if (self.entries.get(key)) |entry| return if (entry) |parsed| &parsed.scene else null;
        const loaded = self.load(resources, key) catch |err| blk: {
            log.err("cannot load UI scene {s}: {t}", .{ key, err });
            break :blk null;
        };
        const owned_key = self.gpa.dupe(u8, key) catch return if (loaded) |parsed| self.discard(parsed) else null;
        self.entries.put(self.gpa, owned_key, loaded) catch {
            self.gpa.free(owned_key);
            return if (loaded) |parsed| self.discard(parsed) else null;
        };
        return if (loaded) |parsed| &parsed.scene else null;
    }

    fn load(self: *Scenes, resources: Resources, key: []const u8) !?*ui_scene.Parsed {
        const reference = try AssetRef(.ui).parse(key);
        const source = try resources.read(self.gpa, reference);
        defer self.gpa.free(source);
        const parsed = try self.gpa.create(ui_scene.Parsed);
        errdefer self.gpa.destroy(parsed);
        parsed.* = try ui_scene.parse(self.gpa, source);
        return parsed;
    }

    fn discard(self: *Scenes, parsed: *ui_scene.Parsed) ?*const ui_scene.UiScene {
        parsed.deinit();
        self.gpa.destroy(parsed);
        return null;
    }

    /// Read the scene with `key` again when next asked for: its file changed.
    pub fn forget(self: *Scenes, key: []const u8) void {
        const removed = self.entries.fetchRemove(key) orelse return;
        self.gpa.free(removed.key);
        if (removed.value) |parsed| _ = self.discard(parsed);
    }

    /// Read every scene again when next asked for.
    pub fn forgetAll(self: *Scenes) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |parsed| _ = self.discard(parsed);
        }
        self.entries.clearRetainingCapacity();
    }
};

const Frame = @typeInfo(@FieldType(ui.Image, "frames")).pointer.child;

/// Images by asset key, each frame packed into one font's color atlas. When the font changes
/// (`get` is given another), everything loads again into the new one.
pub const Images = struct {
    gpa: std.mem.Allocator,
    font: ?*ui.Font = null,
    /// Null where the image couldn't be loaded (logged once).
    entries: std.StringHashMapUnmanaged(?*ui.Image) = .empty,

    pub fn deinit(self: *Images) void {
        self.forgetAll();
        self.entries.deinit(self.gpa);
    }

    /// The image with asset `key` in `font`'s atlas, loaded through `resources` the first time.
    pub fn get(self: *Images, resources: Resources, font: *ui.Font, key: []const u8) ?*const ui.Image {
        if (key.len == 0) return null;
        if (self.font != font) {
            self.forgetAll();
            self.font = font;
        }
        if (self.entries.get(key)) |entry| return entry;
        const loaded = self.load(resources, font, key) catch |err| blk: {
            log.err("cannot load image {s} for UI: {t}", .{ key, err });
            break :blk null;
        };
        const owned_key = self.gpa.dupe(u8, key) catch return self.discard(loaded);
        self.entries.put(self.gpa, owned_key, loaded) catch {
            self.gpa.free(owned_key);
            return self.discard(loaded);
        };
        return loaded;
    }

    /// The size of the image with `key` in its file's pixels, if it is loaded or loads.
    pub fn size(self: *Images, resources: Resources, font: *ui.Font, key: []const u8) ?[2]f32 {
        const image = self.get(resources, font, key) orelse return null;
        return .{ @floatFromInt(image.width), @floatFromInt(image.height) };
    }

    fn load(self: *Images, resources: Resources, font: *ui.Font, key: []const u8) !*ui.Image {
        var texture = try resources.loadImage(self.gpa, try AssetRef(.image).parse(key));
        defer texture.deinit(self.gpa);
        if (!texture.isWhole()) return error.InvalidImage;
        return pack(self.gpa, font, texture);
    }

    fn discard(self: *Images, image: ?*ui.Image) ?*const ui.Image {
        if (image) |owned| {
            owned.deinit(self.gpa);
            self.gpa.destroy(owned);
        }
        return null;
    }

    /// Load the image with `key` again when next asked for: its file changed.
    pub fn forget(self: *Images, key: []const u8) void {
        const removed = self.entries.fetchRemove(key) orelse return;
        self.gpa.free(removed.key);
        _ = self.discard(removed.value);
    }

    /// Load every image again when next asked for. The atlas keeps the old sprites (see
    /// `ui.Font.addSprite`).
    pub fn forgetAll(self: *Images) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            _ = self.discard(entry.value_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }
};

/// The largest side of a frame in the atlas, and how much of the atlas one image may take, as
/// `ui.Image.load` allows.
const max_side = 512;
const max_pixels = ui.color_atlas_size * ui.color_atlas_size / 4;

/// `texture`'s frames packed into `font`'s color atlas, shrunk to fit it; an owned image.
pub fn pack(gpa: std.mem.Allocator, font: *ui.Font, texture: assets.Texture) !*ui.Image {
    const count = texture.frameCount();
    const width: usize = texture.width;
    const height: usize = texture.height;
    // Shrink so a frame fits `max_side` and all frames fit `max_pixels`.
    var scale = @min(1, @as(f32, max_side) / @as(f32, @floatFromInt(@max(width, height))));
    const total: f32 = @floatFromInt(width * height * count);
    scale = @min(scale, @sqrt(@as(f32, max_pixels) / total));
    const packed_w: usize = @max(1, @as(usize, @intFromFloat(@floor(@as(f32, @floatFromInt(width)) * scale))));
    const packed_h: usize = @max(1, @as(usize, @intFromFloat(@floor(@as(f32, @floatFromInt(height)) * scale))));
    const scaled = try gpa.alloc(u8, packed_w * packed_h * 4);
    defer gpa.free(scaled);

    const image = try gpa.create(ui.Image);
    errdefer gpa.destroy(image);
    const frames = try gpa.alloc(Frame, count);
    errdefer gpa.free(frames);
    var duration: u32 = 0;
    for (frames, 0..) |*frame, i| {
        const source = texture.frame(i);
        const pixels = if (packed_w == width and packed_h == height) source else blk: {
            // ponytail: nearest-neighbour shrinking; filter it if large UI images look rough.
            for (0..packed_h) |y| for (0..packed_w) |x| {
                const sx = x * width / packed_w;
                const sy = y * height / packed_h;
                @memcpy(scaled[(y * packed_w + x) * 4 ..][0..4], source[(sy * width + sx) * 4 ..][0..4]);
            };
            break :blk scaled;
        };
        const delay: u32 = if (texture.frame_delays_ms.len > i) texture.frame_delays_ms[i] else 0;
        frame.* = .{ .sprite = try font.addSprite(pixels, @intCast(packed_w), @intCast(packed_h)), .delay_ms = delay };
        duration += delay;
    }
    image.* = .{ .width = texture.width, .height = texture.height, .frames = frames, .duration_ms = if (count > 1) duration else 0 };
    return image;
}

test "an animated texture packs every frame and plays them in turn" {
    const gpa = std.testing.allocator;
    var font = try ui.Font.init(gpa, ui.default_font);
    defer font.deinit();
    var pixels = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 };
    var delays = [_]u32{ 100, 200 };
    const image = try pack(gpa, &font, .{ .width = 1, .height = 1, .pixels = &pixels, .frame_delays_ms = &delays });
    defer {
        image.deinit(gpa);
        gpa.destroy(image);
    }
    try std.testing.expectEqual(@as(usize, 2), image.frames.len);
    try std.testing.expectEqual(@as(u32, 300), image.duration_ms);
    try std.testing.expect(!std.meta.eql(image.frameAt(50), image.frameAt(150)));
}

test "a large image is shrunk to fit the atlas" {
    const gpa = std.testing.allocator;
    var font = try ui.Font.init(gpa, ui.default_font);
    defer font.deinit();
    const pixels = try gpa.alloc(u8, 1024 * 4 * 4);
    defer gpa.free(pixels);
    @memset(pixels, 255);
    const image = try pack(gpa, &font, .{ .width = 1024, .height = 4, .pixels = pixels });
    defer {
        image.deinit(gpa);
        gpa.destroy(image);
    }
    try std.testing.expectEqual(@as(u32, 1024), image.width);
    try std.testing.expectEqual(@as(u16, 512), image.frames[0].sprite.w);
}
