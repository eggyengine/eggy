//! The Asset Preview panel's model viewer: the model selected in Assets, alone under the default
//! light, turned by dragging and zoomed by scrolling, with its animations to play, pause and
//! scrub under it, and tabs listing its materials (a swatch of each colour or texture) and what
//! its mesh is made of (corners, triangles, size, rig and blend shapes). The editor renders it
//! offscreen (`shot`) into the panel.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ui_scenes = eggy.ui_scenes;
const ProjectAssets = @import("assets/project_assets.zig").ProjectAssets;
const page_style = @import("page_style.zig");

/// What `build` reads from, borrowed for the call.
pub const Request = struct {
    /// The model file's project path.
    path: []const u8,
    /// The animation to show playing (a clip's name, as Assets lists it under the model), when
    /// that was what was selected.
    clip: ?[]const u8 = null,
    assets: *ProjectAssets,
    app: *eggy.App,
    /// Where the material swatches' textures are loaded.
    images: *ui_scenes.cache.Images,
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

/// A material of the model, as its parts are painted with it.
const Material = struct {
    name: []const u8,
    color: [4]f32,
    metallic_roughness: [2]f32,
    emissive_color: [3]f32,
    /// Its texture's size and asset key (the image Assets lists under the model); null for
    /// plain colour.
    texture: ?struct { size: [2]u32, key: [eggy.assets.id.key_len]u8 },
    /// How many of the model's parts use it.
    parts: usize,
};

/// What the model is made of, read once when it is selected.
const Summary = struct {
    corners: usize,
    triangles: usize,
    parts: usize,
    materials: []const Material,
    textures: usize,
    nodes: usize,
    bones: usize,
    blend_shapes: []const []const u8,
    clips: []const Clip,
};

/// The tabs under the viewport.
const Tab = enum(usize) { materials, mesh };

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
    /// The clip chosen, and where it is: `offset_s`, plus the time since `started_ms` while
    /// playing.
    clip: usize = 0,
    playing: bool = false,
    offset_s: f32 = 0,
    started_ms: u64 = 0,
    /// The clip `Request.clip` last asked for, so choosing another in the list sticks.
    asked_clip: std.ArrayList(u8) = .empty,
    tab: usize = @backingInt(Tab.materials),
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
        self.asked_clip.deinit(self.gpa);
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

    /// Draw the model's viewport, its animations' controls and the tabs on what it is made of.
    /// Reads the model the first time it is shown; one that can't be read says so.
    pub fn build(self: *ModelPreview, context: *ui.Context, request: Request) void {
        const graphics = &request.app.graphics;
        const reference = request.assets.referenceAt(request.path) orelse return context.muted("This model isn't in the project's assets yet.");
        const key = reference.key();
        if (!std.mem.eql(u8, key, self.key[0..self.key_len])) self.select(request, key);
        const summary = self.summary orelse return context.muted("This model couldn't be read: see the Console.");
        self.followAskedClip(summary, request);
        const bounds = graphics.models.bounds(key) orelse blk: {
            _ = graphics.models.get(key, &graphics.textures);
            break :blk graphics.models.bounds(key) orelse return context.muted("This model couldn't be drawn: see the Console.");
        };
        const duration_s = self.clipDuration(request, summary, key);
        self.place(bounds, summary, duration_s, request.time_ms);

        // The viewport fills most of the panel; the editor draws the model into it.
        const width = context.contentWidth();
        const side = @max(160, request.height * 0.55);
        context.element(context.builder().node(0, .{ .width = width, .height = side }, .{ .custom = .{ .context = &self.area, .draw = recordArea } }, &.{}) catch return);
        self.shown = true;
        context.muted("Drag to turn it, scroll to zoom, double-click to look again from the start.");
        page_style.smallText(context, 11);

        self.playback(context, summary, duration_s, request.time_ms);
        _ = context.tabs(&.{ std.fmt.allocPrint(context.builder().allocator, "Materials ({d})##model tab", .{summary.materials.len}) catch "Materials##model tab", "Mesh##model tab" }, &self.tab);
        switch (@as(Tab, @fromBackingInt(@intCast(self.tab)))) {
            .materials => materialList(context, request, summary),
            .mesh => meshTable(context, summary, bounds),
        }
    }

    /// Play and pause, the clip to play, where it is, and a bar to scrub through it. Nothing for
    /// a model without animations.
    fn playback(self: *ModelPreview, context: *ui.Context, summary: Summary, duration_s: f32, time_ms: u64) void {
        if (summary.clips.len == 0) return;
        const arena = context.builder().allocator;
        const now_s = self.timeAt(time_ms);
        context.begin(.row);
        if (context.buttonVariant(if (self.playing) "Pause##model play" else "Play##model play", if (self.playing) .outline else .default)) {
            self.offset_s = now_s;
            self.started_ms = time_ms;
            self.playing = !self.playing;
        }
        const names = arena.alloc([]const u8, summary.clips.len) catch return context.end();
        for (names, summary.clips) |*name, clip| name.* = clip.name;
        var chosen = self.clip;
        if (context.select("##model clip", names, &chosen)) {
            self.clip = chosen;
            self.offset_s = 0;
            self.started_ms = time_ms;
        }
        page_style.restyle(context, .{ .grow = 1 });
        const shown_s = if (duration_s > 0) @mod(now_s, duration_s) else now_s;
        context.muted(std.fmt.allocPrint(arena, "{d:.2} / {d:.2} s", .{ shown_s, duration_s }) catch "");
        page_style.smallText(context, 12);
        page_style.endRow(context);

        // Dragging the bar holds the clip at that moment.
        var scrub = shown_s;
        if (duration_s > 0 and context.slider("##model scrub", &scrub, 0, duration_s)) {
            self.playing = false;
            self.offset_s = scrub;
        }
    }

    /// Where the chosen clip is at `time_ms`, in seconds from its start.
    fn timeAt(self: *const ModelPreview, time_ms: u64) f32 {
        if (!self.playing) return self.offset_s;
        return self.offset_s + @as(f32, @floatFromInt(time_ms -| self.started_ms)) / 1000;
    }

    /// The chosen clip's length in seconds; 0 when it can't be read.
    fn clipDuration(self: *const ModelPreview, request: Request, summary: Summary, key: []const u8) f32 {
        if (summary.clips.len == 0) return 0;
        const graphics = &request.app.graphics;
        const gpu = graphics.models.get(key, &graphics.textures) orelse return 0;
        const rig = gpu.rig orelse return 0;
        const model_id = eggy.assets.id.parse(key) catch return 0;
        const clip = graphics.clips.importedFor(&summary.clips[self.clip].key, model_id, rig.*) orelse return 0;
        return clip.duration_s;
    }

    /// Play the clip `request` asks for when it asks for another one than last frame.
    fn followAskedClip(self: *ModelPreview, summary: Summary, request: Request) void {
        const asked = request.clip orelse "";
        if (std.mem.eql(u8, asked, self.asked_clip.items)) return;
        self.asked_clip.clearRetainingCapacity();
        self.asked_clip.appendSlice(self.gpa, asked) catch {};
        for (summary.clips, 0..) |clip, index| if (std.mem.eql(u8, clip.name, asked)) {
            self.clip = index;
            self.playing = true;
            self.offset_s = 0;
            self.started_ms = request.time_ms;
        };
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
        self.clip = 0;
        self.playing = false;
        self.offset_s = 0;
        self.asked_clip.clearRetainingCapacity();
    }

    /// Aim the camera at `bounds` and pose the model in the chosen clip, `time_ms` now.
    fn place(self: *ModelPreview, bounds: eggy.assets.Bounds, summary: Summary, duration_s: f32, time_ms: u64) void {
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

        // A model with animations always stands in the chosen one, held while paused.
        self.animator = .{};
        const animated = summary.clips.len > 0;
        if (animated) {
            self.animator.model_clip = eggy.AssetRef(.animation).parse(&summary.clips[self.clip].key) catch .{};
            const now_s = self.timeAt(time_ms);
            self.animator.time_s = if (duration_s > 0) @mod(now_s, duration_s) else now_s;
            self.animator.playing = false;
        }
        self.drawable = .{
            .model = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } },
            .color = @splat(1),
            .shape = .cube,
            .entity_id = preview_entity_id,
            .entity_generation = 0,
            .model_file = &self.key,
            .model_file_len = @intCast(self.key_len),
            .animator = if (animated) &self.animator else null,
        };
    }
};

/// Each material as a swatch of its texture or colour beside its name and how it shines.
fn materialList(context: *ui.Context, request: Request, summary: Summary) void {
    if (summary.materials.len == 0) return context.muted("It has no materials: the Mesh's colour paints it.");
    const arena = context.builder().allocator;
    const b = context.builder();
    const swatch_px: f32 = 36;
    for (summary.materials) |*material| {
        // The swatch: the texture as it is, else the colour (its glow, if any, as a border).
        const texture = if (material.texture) |found| request.images.get(request.app.resources(), context.font, &found.key) else null;
        const swatch = if (texture) |loaded|
            b.node(0, .{ .width = swatch_px, .height = swatch_px }, .{ .image = loaded.frameAt(request.time_ms) }, &.{}) catch continue
        else
            b.node(0, .{ .width = swatch_px, .height = swatch_px }, .{ .custom = .{ .context = material, .draw = drawSwatch } }, &.{}) catch continue;

        var shine: std.ArrayList(u8) = .empty;
        if (material.texture) |found| shine.print(arena, "{d} x {d} texture, ", .{ found.size[0], found.size[1] }) catch {};
        shine.print(arena, "metallic {d:.2}, roughness {d:.2}", .{ material.metallic_roughness[0], material.metallic_roughness[1] }) catch {};
        if (material.parts > 1) shine.print(arena, ", on {d} parts", .{material.parts}) catch {};

        context.begin(.row);
        context.element(swatch);
        context.begin(.column);
        context.text(material.name);
        page_style.smallText(context, 13);
        context.muted(shine.items);
        page_style.smallText(context, 11);
        if (context.last_added) |text| text.paint_kind.text.wrap = true;
        context.end();
        page_style.restyle(context, .{ .grow = 1, .gap = 2 });
        context.end();
        page_style.restyle(context, .{ .direction = .row, .gap = 10, .align_items = .center, .padding = .{ .top = 4, .bottom = 4 } });
    }
}

/// What the mesh is made of, as a two-column table, and its blend shapes by name.
fn meshTable(context: *ui.Context, summary: Summary, bounds: eggy.assets.Bounds) void {
    const arena = context.builder().allocator;
    const size = [3]f32{ bounds.max[0] - bounds.min[0], bounds.max[1] - bounds.min[1], bounds.max[2] - bounds.min[2] };
    const rigged = summary.nodes > 0;
    var rows: std.ArrayList([]const []const u8) = .empty;
    addRow(arena, &rows, "Kind", if (summary.bones > 0) "Skeletal mesh" else if (rigged) "Moving mesh" else "Static mesh");
    addRow(arena, &rows, "Corners", count(arena, summary.corners));
    addRow(arena, &rows, "Triangles", count(arena, summary.triangles));
    addRow(arena, &rows, "Parts", count(arena, summary.parts));
    addRow(arena, &rows, "Size", std.fmt.allocPrint(arena, "{d:.2} x {d:.2} x {d:.2} m", .{ size[0], size[1], size[2] }) catch "");
    addRow(arena, &rows, "Textures", count(arena, summary.textures));
    if (rigged) addRow(arena, &rows, "Nodes", count(arena, summary.nodes));
    if (summary.bones > 0) addRow(arena, &rows, "Bones", count(arena, summary.bones));
    addRow(arena, &rows, "Animations", count(arena, summary.clips.len));
    if (summary.blend_shapes.len > 0) addRow(arena, &rows, "Blend shapes", count(arena, summary.blend_shapes.len));
    context.table(&.{ "Property", "Value" }, rows.items);
    if (summary.blend_shapes.len == 0) return;
    var shapes: std.ArrayList([]const []const u8) = .empty;
    for (summary.blend_shapes) |name| addRow(arena, &shapes, name, "");
    context.table(&.{ "Blend shape", "" }, shapes.items);
}

/// What the model with `key` is made of, in `arena`: read through the project's model loader
/// (so its triangles are imported once more), and its clips and textures from the Assets panel's
/// listing.
// ponytail: imports the model on the panel's thread when selected, so a big model stalls a frame; read it in a job if that shows.
fn summarise(arena: std.mem.Allocator, request: Request, key: []const u8) !Summary {
    const loader = request.assets.models();
    var model = try loader.load(loader.context, request.assets.gpa, key);
    defer model.deinit(request.assets.gpa);

    // Its clips and textures, as Assets lists them under it.
    var clips: std.ArrayList(Clip) = .empty;
    const texture_keys = try arena.alloc(?[eggy.assets.id.key_len]u8, model.textures.len);
    @memset(texture_keys, null);
    for (try request.assets.children(arena, request.path)) |child| {
        var child_key: [eggy.assets.id.key_len]u8 = undefined;
        _ = eggy.assets.id.key(&child_key, child.id);
        if (child.kind == .animation) try clips.append(arena, .{ .name = std.fs.path.basename(child.path), .key = child_key });
        if (child.texture_index) |index| if (index < texture_keys.len) {
            texture_keys[index] = child_key;
        };
    }

    var bones: usize = 0;
    for (model.rig.skins) |skin| bones += skin.joints.len;
    const blend_shapes = try arena.alloc([]const u8, model.rig.morph_targets.len);
    for (blend_shapes, model.rig.morph_targets) |*out, target| out.* = try arena.dupe(u8, target.name);
    return .{
        .corners = model.vertices.len,
        .triangles = model.indices.len / 3,
        .parts = model.parts.len,
        .materials = try materialsOf(arena, model, texture_keys),
        .textures = model.textures.len,
        .nodes = model.rig.nodes.len,
        .bones = bones,
        .blend_shapes = blend_shapes,
        .clips = clips.items,
    };
}

/// Each material `model`'s parts use, in the file's order, with the colours of the first part
/// painted with it (they are kept in its corners); a part with no material counts as its own.
fn materialsOf(arena: std.mem.Allocator, model: eggy.assets.Model, texture_keys: []const ?[eggy.assets.id.key_len]u8) ![]const Material {
    var materials: std.ArrayList(Material) = .empty;
    const slot_of = try arena.alloc(?usize, model.materials.len);
    @memset(slot_of, null);
    for (model.parts, 0..) |part, part_index| {
        if (part.material) |material| if (slot_of[material]) |slot| {
            materials.items[slot].parts += 1;
            continue;
        };
        const corner = if (part.index_count > 0) model.vertices[model.indices[part.first_index]] else eggy.assets.model.Vertex{ .position = @splat(0), .normal = @splat(0) };
        const texture: @FieldType(Material, "texture") = if (part.texture) |at| if (texture_keys[at]) |texture_key| .{ .size = .{ model.textures[at].width, model.textures[at].height }, .key = texture_key } else null else null;
        if (part.material) |material| slot_of[material] = materials.items.len;
        try materials.append(arena, .{
            .name = if (part.material) |material| try arena.dupe(u8, model.materials[material].name) else try std.fmt.allocPrint(arena, "Part {d}", .{part_index + 1}),
            .color = corner.color,
            .metallic_roughness = corner.metallic_roughness,
            .emissive_color = corner.emissive_color,
            .texture = texture,
            .parts = 1,
        });
    }
    return materials.items;
}

// A material's colour (see-through parts blended over grey, as the canvas paints opaque
// rectangles), ringed by its glow when it has one.
fn drawSwatch(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const material: *const Material = @ptrCast(@alignCast(context));
    const glow = material.emissive_color;
    if (glow[0] + glow[1] + glow[2] > 0) try c.rect(r, .{ @min(1, glow[0]), @min(1, glow[1]), @min(1, glow[2]) });
    const alpha = material.color[3];
    var shown: ui.Color = undefined;
    for (&shown, material.color[0..3]) |*out, channel| out.* = channel * alpha + 0.7 * (1 - alpha);
    try c.rect(.{ .x = r.x + 3, .y = r.y + 3, .w = r.w - 6, .h = r.h - 6 }, shown);
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

test "parts sharing a material list it once, with its name and colour, and a part without one is its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vertices = [_]eggy.assets.model.Vertex{
        .{ .position = @splat(0), .normal = @splat(0), .color = .{ 1, 0, 0, 1 } },
        .{ .position = @splat(0), .normal = @splat(0), .color = .{ 0, 1, 0, 1 } },
    };
    var indices = [_]u32{ 0, 0, 0, 0, 0, 0, 1, 1, 1 };
    var parts = [_]eggy.assets.model.Part{
        .{ .first_index = 0, .index_count = 3, .material = 0 },
        .{ .first_index = 3, .index_count = 3, .material = 0 },
        .{ .first_index = 6, .index_count = 3 },
    };
    var names = [_]eggy.assets.model.Material{.{ .name = "petal" }};
    const model = eggy.assets.Model{ .vertices = &vertices, .indices = &indices, .parts = &parts, .textures = &.{}, .materials = &names };
    const materials = try materialsOf(arena.allocator(), model, &.{});
    try std.testing.expectEqual(@as(usize, 2), materials.len);
    try std.testing.expectEqualStrings("petal", materials[0].name);
    try std.testing.expectEqual(@as(usize, 2), materials[0].parts);
    try std.testing.expectEqual(@as(f32, 1), materials[0].color[0]);
    try std.testing.expectEqualStrings("Part 3", materials[1].name);
    try std.testing.expectEqual(@as(f32, 1), materials[1].color[1]);
}
