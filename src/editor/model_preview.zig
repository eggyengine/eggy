//! The Asset Preview panel's model viewer: the model selected in Assets, alone under the default
//! light, turned by dragging and zoomed by scrolling, with what it is made of listed under it
//! (its corners and triangles, size, materials, textures, rig and blend shapes) and its
//! animations to play. The editor renders it offscreen (`shot`) into the panel.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ProjectAssets = @import("assets/project_assets.zig").ProjectAssets;
const page_style = @import("page_style.zig");

/// What `build` reads from, borrowed for the call.
pub const Request = struct {
    /// The model file's project path.
    path: []const u8,
    assets: *ProjectAssets,
    app: *eggy.App,
    time_ms: u64,
    /// The height left in the panel.
    height: f32,
};

/// What the editor renders this frame: `drawable` seen through `view`, into `rect` (logical
/// points of the panel's window).
pub const Shot = struct {
    rect: ui.Rect,
    view: eggy.camera.View,
    drawable: *eggy.mesh.Drawable,
};

/// One of the model's animations: its name, and its asset key for an `Animator`.
const Clip = struct {
    name: []const u8,
    key: [eggy.assets.id.key_len]u8,
};

/// What the model is made of, read once when it is selected.
const Summary = struct {
    corners: usize,
    triangles: usize,
    /// For each part (material): the size of its texture, or null for plain colour.
    parts: []const ?[2]u32,
    textures: []const [3]u32,
    nodes: usize,
    bones: usize,
    blend_shapes: []const []const u8,
    clips: []const Clip,
};

/// The entity id the preview's drawable claims, which no world entity has.
const preview_entity_id = std.math.maxInt(u32) - 1;

pub const ModelPreview = struct {
    gpa: std.mem.Allocator,
    /// The geometry's asset key shown, which `drawable` points into.
    key: [eggy.assets.id.key_len]u8 = undefined,
    key_len: usize = 0,
    /// Holds `summary`; reset when another model is selected.
    arena: std.heap.ArenaAllocator,
    summary: ?Summary = null,
    /// Turning and distance (a multiple of the distance that fits it in view).
    yaw_deg: f32 = 35,
    pitch_deg: f32 = -20,
    zoom: f32 = 1,
    /// Where the pointer was last while dragging to turn it.
    turning: ?ui.Vec2 = null,
    /// The clip playing, from `started_ms`.
    playing: ?usize = null,
    started_ms: u64 = 0,
    animator: eggy.animation.Animator = .{},
    drawable: eggy.mesh.Drawable = undefined,
    view: eggy.camera.View = .default,
    /// Where its viewport was laid out last frame, and whether it was built this frame.
    area: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    shown: bool = false,

    pub fn init(gpa: std.mem.Allocator) ModelPreview {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(self: *ModelPreview) void {
        self.arena.deinit();
    }

    /// What the editor renders this frame; null when no model is shown.
    pub fn shot(self: *ModelPreview) ?Shot {
        if (!self.shown or self.area.w < 1 or self.area.h < 1) return null;
        return .{ .rect = self.area, .view = self.view, .drawable = &self.drawable };
    }

    /// Drag to turn the model, scroll to zoom, double-click to look again from the start.
    /// Returns whether the event was used.
    pub fn handle(self: *ModelPreview, event: ui.input.Event) bool {
        if (!self.shown) return false;
        switch (event) {
            .pointer_down => |down| {
                if (down.button != .left or !self.area.contains(down.position.x, down.position.y)) return false;
                if (down.clicks >= 2) {
                    self.yaw_deg = 35;
                    self.pitch_deg = -20;
                    self.zoom = 1;
                }
                self.turning = down.position;
                return true;
            },
            .pointer_move => |at| {
                const from = self.turning orelse return false;
                self.yaw_deg -= (at.x - from.x) * 0.4;
                self.pitch_deg = std.math.clamp(self.pitch_deg - (at.y - from.y) * 0.4, -89, 89);
                self.turning = at;
                return true;
            },
            .pointer_up => {
                const was_turning = self.turning != null;
                self.turning = null;
                return was_turning;
            },
            .wheel => |wheel| {
                if (!self.area.contains(wheel.position.x, wheel.position.y)) return false;
                self.zoom = std.math.clamp(self.zoom * @exp(-wheel.delta.y * 0.1), 0.1, 10);
                return true;
            },
            else => return false,
        }
    }

    /// Draw the model's viewport and what it is made of. Reads the model the first time it is
    /// shown; one that can't be read says so.
    pub fn build(self: *ModelPreview, context: *ui.Context, request: Request) void {
        const graphics = &request.app.graphics;
        const reference = request.assets.referenceAt(request.path) orelse return context.muted("This model isn't in the project's assets yet.");
        const key = reference.key();
        if (!std.mem.eql(u8, key, self.key[0..self.key_len])) self.select(request, key);
        const summary = self.summary orelse return context.muted("This model couldn't be read: see the Console.");
        const bounds = graphics.models.bounds(key) orelse blk: {
            _ = graphics.models.get(key, &graphics.textures);
            break :blk graphics.models.bounds(key) orelse return context.muted("This model couldn't be drawn: see the Console.");
        };
        self.place(bounds, request.time_ms);

        // The viewport, square up to half the panel's height; the editor draws the model into it.
        const width = context.contentWidth();
        const side = @min(width, @max(120, request.height * 0.5));
        context.element(context.builder().node(0, .{ .width = width, .height = side }, .{ .custom = .{ .context = &self.area, .draw = recordArea } }, &.{}) catch return);
        self.shown = true;
        if (self.playing) |index| if (graphics.models.get(key, &graphics.textures)) |gpu| if (gpu.rig) |rig| {
            const model_id = eggy.assets.id.parse(key) catch 0;
            if (graphics.clips.importedFor(&summary.clips[index].key, model_id, rig.*)) |clip| if (clip.duration_s > 0) {
                context.progress(@mod(self.animator.time_s, clip.duration_s) / clip.duration_s);
            };
        };
        context.muted("Drag to turn it, scroll to zoom, double-click to start again.");
        page_style.smallText(context, 11);

        // What it is made of, scrolling under the viewport.
        const arena = context.builder().allocator;
        const size = [3]f32{ bounds.max[0] - bounds.min[0], bounds.max[1] - bounds.min[1], bounds.max[2] - bounds.min[2] };
        const rigged = summary.nodes > 0;
        var rows: std.ArrayList([]const []const u8) = .empty;
        addRow(arena, &rows, "Kind", if (summary.bones > 0) "Skeletal mesh" else if (rigged) "Moving mesh" else "Static mesh");
        addRow(arena, &rows, "Corners", count(arena, summary.corners));
        addRow(arena, &rows, "Triangles", count(arena, summary.triangles));
        addRow(arena, &rows, "Size", std.fmt.allocPrint(arena, "{d:.2} x {d:.2} x {d:.2} m", .{ size[0], size[1], size[2] }) catch "");
        addRow(arena, &rows, "Materials", count(arena, summary.parts.len));
        addRow(arena, &rows, "Textures", count(arena, summary.textures.len));
        if (rigged) addRow(arena, &rows, "Nodes", count(arena, summary.nodes));
        if (summary.bones > 0) addRow(arena, &rows, "Bones", count(arena, summary.bones));
        if (summary.blend_shapes.len > 0) addRow(arena, &rows, "Blend shapes", count(arena, summary.blend_shapes.len));
        context.table(&.{ "Property", "Value" }, rows.items);

        if (summary.parts.len > 0) {
            var materials: std.ArrayList([]const []const u8) = .empty;
            for (summary.parts, 0..) |texture, index| {
                const shows = if (texture) |found| std.fmt.allocPrint(arena, "Texture, {d} x {d}", .{ found[0], found[1] }) catch "" else "Plain colour (the Mesh's)";
                addRow(arena, &materials, std.fmt.allocPrint(arena, "{d}", .{index}) catch "", shows);
            }
            context.table(&.{ "Material", "Painted with" }, materials.items);
        }
        if (summary.blend_shapes.len > 0) {
            var shapes: std.ArrayList([]const []const u8) = .empty;
            for (summary.blend_shapes) |name| addRow(arena, &shapes, name, "");
            context.table(&.{ "Blend shape", "" }, shapes.items);
        }
        self.clipButtons(context, summary, request.time_ms);
    }

    /// A button per animation: pressing one plays it on the preview, pressing it again stops.
    fn clipButtons(self: *ModelPreview, context: *ui.Context, summary: Summary, time_ms: u64) void {
        if (summary.clips.len == 0) return;
        context.text("Animations");
        page_style.smallText(context, 13);
        const arena = context.builder().allocator;
        for (summary.clips, 0..) |clip, index| {
            const on = self.playing == index;
            const label = std.fmt.allocPrint(arena, "{s}##model clip {d}", .{ clip.name, index }) catch continue;
            if (!context.buttonVariant(label, if (on) .default else .outline)) continue;
            self.playing = if (on) null else index;
            self.started_ms = time_ms;
        }
    }

    /// Show the model with `key`: read what it is made of, and look at it from the start.
    fn select(self: *ModelPreview, request: Request, key: []const u8) void {
        @memcpy(self.key[0..key.len], key);
        self.key_len = key.len;
        _ = self.arena.reset(.retain_capacity);
        self.summary = summarise(self.arena.allocator(), request, key) catch |err| blk: {
            std.log.err("cannot preview {s}: {t}", .{ request.path, err });
            break :blk null;
        };
        self.yaw_deg = 35;
        self.pitch_deg = -20;
        self.zoom = 1;
        self.playing = null;
    }

    /// Aim the camera at `bounds` and pose the model in the clip playing, `time_ms` now.
    fn place(self: *ModelPreview, bounds: eggy.assets.Bounds, time_ms: u64) void {
        var centre: [3]f32 = undefined;
        var half: [3]f32 = undefined;
        for (&centre, &half, bounds.min, bounds.max) |*c, *h, low, high| {
            c.* = (low + high) / 2;
            h.* = (high - low) / 2;
        }
        const radius = @max(0.01, @sqrt(half[0] * half[0] + half[1] * half[1] + half[2] * half[2]));
        const fov_deg: f32 = 35;
        const distance = radius / @sin(fov_deg / 2 * std.math.rad_per_deg) * self.zoom;
        const yaw = self.yaw_deg * std.math.rad_per_deg;
        const pitch = self.pitch_deg * std.math.rad_per_deg;
        const toward = [3]f32{ @sin(yaw) * @cos(pitch), -@sin(pitch), @cos(yaw) * @cos(pitch) };
        var eye: [3]f32 = undefined;
        for (&eye, centre, toward) |*e, c, t| e.* = c + t * distance;
        self.view = .lookingAt(eye, centre, .{ .fov_deg = fov_deg, .near = @max(0.001, (distance - radius) * 0.5), .far = distance + radius * 4 });

        self.animator = .{};
        if (self.playing) |index| if (self.summary) |summary| {
            self.animator.model_clip = eggy.AssetRef(.animation).parse(&summary.clips[index].key) catch .{};
            self.animator.time_s = @as(f32, @floatFromInt(time_ms -| self.started_ms)) / 1000;
        };
        self.drawable = .{
            .model = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } },
            .color = @splat(1),
            .shape = .cube,
            .entity_id = preview_entity_id,
            .entity_generation = 0,
            .model_file = &self.key,
            .model_file_len = @intCast(self.key_len),
            .animator = if (self.playing != null) &self.animator else null,
        };
    }
};

/// What the model with `key` is made of, in `arena`: read through the project's model loader
/// (so its triangles are imported once more), and its clips from the Assets panel's listing.
// ponytail: imports the model on the panel's thread when selected, so a big model stalls a frame; read it in a job if that shows.
fn summarise(arena: std.mem.Allocator, request: Request, key: []const u8) !Summary {
    const loader = request.assets.models();
    var model = try loader.load(loader.context, request.assets.gpa, key);
    defer model.deinit(request.assets.gpa);

    const parts = try arena.alloc(?[2]u32, model.parts.len);
    for (parts, model.parts) |*out, part| out.* = if (part.texture) |at| if (at < model.textures.len) .{ model.textures[at].width, model.textures[at].height } else null else null;
    const textures = try arena.alloc([3]u32, model.textures.len);
    for (textures, model.textures) |*out, texture| out.* = .{ texture.width, texture.height, @intCast(@max(1, texture.frame_delays_ms.len)) };
    var bones: usize = 0;
    for (model.rig.skins) |skin| bones += skin.joints.len;
    const blend_shapes = try arena.alloc([]const u8, model.rig.morph_targets.len);
    for (blend_shapes, model.rig.morph_targets) |*out, target| out.* = try arena.dupe(u8, target.name);

    // Its clips, as Assets lists them under it.
    var clips: std.ArrayList(Clip) = .empty;
    for (try request.assets.children(arena, request.path)) |child| {
        if (child.kind != .animation) continue;
        var clip = Clip{ .name = std.fs.path.basename(child.path), .key = undefined };
        _ = eggy.assets.id.key(&clip.key, child.id);
        try clips.append(arena, clip);
    }
    return .{
        .corners = model.vertices.len,
        .triangles = model.indices.len / 3,
        .parts = parts,
        .textures = textures,
        .nodes = model.rig.nodes.len,
        .bones = bones,
        .blend_shapes = blend_shapes,
        .clips = clips.items,
    };
}

fn addRow(arena: std.mem.Allocator, rows: *std.ArrayList([]const []const u8), label: []const u8, value: []const u8) void {
    const row = arena.dupe([]const u8, &.{ label, value }) catch return;
    rows.append(arena, row) catch {};
}

/// `value` with thousands separated: "12,480".
fn count(arena: std.mem.Allocator, value: usize) []const u8 {
    var digits: [32]u8 = undefined;
    const plain = std.fmt.bufPrint(&digits, "{d}", .{value}) catch return "";
    var out: std.ArrayList(u8) = .empty;
    for (plain, 0..) |digit, i| {
        if (i > 0 and (plain.len - i) % 3 == 0) out.append(arena, ',') catch return plain;
        out.append(arena, digit) catch return plain;
    }
    return out.items;
}

// Keep where the viewport was laid out, for the next frame's render.
fn recordArea(context: *const anyopaque, _: *ui.Canvas, rect: ui.Rect) anyerror!void {
    const area: *ui.Rect = @ptrCast(@alignCast(@constCast(context)));
    area.* = rect;
}

test "counts are grouped in thousands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("12,480", count(arena.allocator(), 12480));
    try std.testing.expectEqualStrings("999", count(arena.allocator(), 999));
    try std.testing.expectEqualStrings("1,000,000", count(arena.allocator(), 1000000));
}

test "dragging turns the model and scrolling zooms it, only over its viewport" {
    var preview = ModelPreview.init(std.testing.allocator);
    defer preview.deinit();
    preview.shown = true;
    preview.area = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try std.testing.expect(!preview.handle(.{ .pointer_down = .{ .position = .init(150, 50), .button = .left, .clicks = 1 } }));
    try std.testing.expect(preview.handle(.{ .pointer_down = .{ .position = .init(50, 50), .button = .left, .clicks = 1 } }));
    try std.testing.expect(preview.handle(.{ .pointer_move = .init(60, 50) }));
    try std.testing.expectApproxEqAbs(@as(f32, 31), preview.yaw_deg, 1e-4);
    try std.testing.expect(preview.handle(.{ .pointer_up = .{ .position = .init(60, 50), .button = .left } }));
    try std.testing.expect(!preview.handle(.{ .pointer_move = .init(70, 50) }));
    try std.testing.expect(preview.handle(.{ .wheel = .{ .position = .init(50, 50), .delta = .init(0, 1) } }));
    try std.testing.expect(preview.zoom < 1);
}
