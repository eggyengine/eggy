//! Billboards' UI scenes in the world: each frame every billboard's scene is painted into its own
//! tile of one shared texture by weeoui's renderer, then drawn where its entity is, depth-tested,
//! as a world panel (`world_draw.zig`). The buttons it painted take presses through `press`.
const std = @import("std");
const ecs = @import("clutch");
const vit = @import("vitellus");
const ui = @import("weeoui");
const weeoui_vitellus = @import("weeoui_vitellus");
const camera = @import("../camera.zig");
const world_draw = @import("../world_draw.zig");
const Resources = @import("../resources/resources.zig").Resources;
const state_zig = @import("state.zig");
const State = state_zig.State;
const Billboard = state_zig.Billboard;
const cache = @import("cache.zig");
const scene_ui = @import("scene_ui.zig");

/// What the host gives graphics for one frame's billboards, borrowed until it is drawn.
pub const Frame = struct {
    state: *State,
    resources: Resources,
    billboards: []const Billboard,
    /// For GIFs: milliseconds of a steady clock.
    time_ms: u64,
};

/// The side of the texture billboards share, in texels, and the texels kept clear around a tile
/// so filtering doesn't bleed into the next.
pub const atlas_size = 2048;
const gap = 2;

/// Paints billboards for one scene viewport. Owns its own font, images and texture.
pub const Renderer = struct {
    gpa: std.mem.Allocator,
    context: ui.Context,
    painter: weeoui_vitellus.Renderer,
    texture: vit.Texture,
    view: vit.TextureView,
    sampler: vit.Sampler,
    group: vit.BindGroup,
    images: cache.Images,
    /// The `State.files_revision` its images were loaded at.
    files_revision: u32 = 0,
    /// Whether the texture has been painted once, so it is sampled rather than undefined.
    painted: bool = false,
    panels: std.ArrayList(world_draw.Panel) = .empty,

    /// Make the shared texture and its painter on `device`; `texture_layout` is the layout of a
    /// world sprite's texture (`TextureCache.layout`). Pair with `deinit`.
    pub fn init(gpa: std.mem.Allocator, device: vit.Device, texture_layout: vit.BindGroupLayout) !Renderer {
        var context = try ui.Context.init(gpa);
        errdefer context.deinit();
        var painter = try weeoui_vitellus.Renderer.init(device, .rgba8_unorm, context.font);
        errdefer painter.deinit();
        const texture = try vit.Texture.init(device, .{
            .label = "billboard UI",
            .width = atlas_size,
            .height = atlas_size,
            .format = .rgba8_unorm,
            .usage = .{ .color_attachment = true, .sampled = true },
        });
        errdefer texture.deinit();
        const view = try vit.TextureView.init(device, .{ .texture = texture });
        errdefer view.deinit();
        const sampler = try vit.Sampler.init(device, .{ .address_u = .clamp_to_edge, .address_v = .clamp_to_edge });
        errdefer sampler.deinit();
        const group = try vit.BindGroup.init(device, .{ .layout = texture_layout, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = view } },
            .{ .binding = 1, .resource = .{ .sampler = sampler } },
        } });
        return .{ .gpa = gpa, .context = context, .painter = painter, .texture = texture, .view = view, .sampler = sampler, .group = group, .images = .{ .gpa = gpa } };
    }

    /// Free everything. The GPU must be done with it.
    pub fn deinit(self: *Renderer) void {
        self.panels.deinit(self.gpa);
        self.images.deinit();
        self.group.deinit();
        self.sampler.deinit();
        self.view.deinit();
        self.texture.deinit();
        self.painter.deinit();
        self.context.deinit();
    }

    /// Paint `frame`'s billboards into their tiles, recording into `cmd` outside a render pass,
    /// and return the panels that show them seen from `view` (borrowed until the next call).
    /// Billboards whose scene can't be read, or that don't fit the texture this frame, are
    /// left out.
    pub fn prepare(self: *Renderer, cmd: vit.CommandBuffer, frame: *const Frame, view: camera.View) ![]const world_draw.Panel {
        self.panels.clearRetainingCapacity();
        if (frame.billboards.len == 0) return self.panels.items;
        if (self.files_revision != frame.state.files_revision) {
            self.images.forgetAll();
            self.files_revision = frame.state.files_revision;
        }

        // Lay each scene out in its tile, in rows down the texture.
        const whole = ui.Rect{ .x = 0, .y = 0, .w = atlas_size, .h = atlas_size };
        self.context.newFrame(whole);
        self.context.time_ms = frame.time_ms;
        var shelf = Shelf{};
        for (frame.billboards) |billboard| {
            const scene = frame.state.sceneCache().get(frame.resources, billboard.key()) orelse continue;
            const design = scene.design_size;
            if (!(design[0] > 0 and design[1] > 0)) continue;
            // ponytail: a billboard larger than the texture is drawn coarser; split the texture if big signs look soft.
            const resolution = @min(billboard.resolution, (atlas_size - gap) / @max(design[0], design[1]));
            const tile = shelf.place(@ceil(design[0] * resolution), @ceil(design[1] * resolution)) orelse continue;
            const built = try scene_ui.build(&self.context, frame.state, frame.resources, &self.images, scene, billboard.entity(), .{ .viewport = tile, .scale = resolution, .interactive = false }, frame.time_ms);
            try self.panels.append(self.gpa, panelFor(billboard, tile, design[1] / design[0], view, self.group));
            try noteButtons(frame.state, billboard.entity(), built.placed, tile);
        }
        const vertices = try self.context.render();
        if (self.panels.items.len == 0) return self.panels.items;

        // Paint the tiles over a clear texture, then leave it to be sampled.
        try self.painter.upload(cmd, self.context.font, vertices, whole);
        try cmd.barrier(&.{.{ .texture = .{ .texture = self.texture, .before = if (self.painted) .sampled else .common, .after = .color_attachment } }});
        try cmd.beginRenderPass(.{ .label = "billboard UI", .color_attachments = &.{.{ .view = self.view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } }} });
        self.painter.draw(cmd, .{ .width = atlas_size, .height = atlas_size }, 0, vertices.len);
        cmd.endRenderPass();
        try cmd.barrier(&.{.{ .texture = .{ .texture = self.texture, .before = .color_attachment, .after = .sampled } }});
        self.painted = true;
        return self.panels.items;
    }
};

/// Tiles placed left to right in rows, each row as tall as its tallest tile.
const Shelf = struct {
    x: f32 = gap,
    y: f32 = gap,
    row_h: f32 = 0,

    fn place(self: *Shelf, w: f32, h: f32) ?ui.Rect {
        if (self.x + w + gap > atlas_size) {
            self.x = gap;
            self.y += self.row_h + gap;
            self.row_h = 0;
        }
        if (self.x + w + gap > atlas_size or self.y + h + gap > atlas_size) return null;
        const tile = ui.Rect{ .x = self.x, .y = self.y, .w = w, .h = h };
        self.x += w + gap;
        self.row_h = @max(self.row_h, h);
        return tile;
    }
};

/// Keep where `entity`'s buttons were painted in `tile`, for presses, unless another viewport
/// painted them this frame already.
fn noteButtons(state: *State, entity: ecs.EntityId, placed: []const @import("layout.zig").Placed, tile: ui.Rect) !void {
    for (state.billboard_buttons.items) |button| if (button.entity.eql(entity)) return;
    for (placed) |item| {
        if (item.node.widget != .button or item.rect.w <= 0 or item.rect.h <= 0) continue;
        const rect = ui.Rect{ .x = (item.rect.x - tile.x) / tile.w, .y = (item.rect.y - tile.y) / tile.h, .w = item.rect.w / tile.w, .h = item.rect.h / tile.h };
        try state.billboard_buttons.append(state.gpa, .{ .entity = entity, .node = item.node.name, .rect = rect });
    }
}

/// Press the button of the nearest billboard under `at` (in points, from the top left of a
/// `viewport_points` view seen through `view`), as painted last frame, and record it as clicked
/// for that billboard's entity. Returns whether a button was pressed, so the game doesn't also
/// take the press.
// ponytail: what stands in front of a billboard doesn't stop the press; ray-test meshes too if presses go through walls.
pub fn press(state: *State, resources: Resources, view: camera.View, viewport_points: [2]f32, at: [2]f32) !bool {
    if (!(viewport_points[0] > 0 and viewport_points[1] > 0)) return false;
    const ndc = [2]f32{ at[0] / viewport_points[0] * 2 - 1, 1 - at[1] / viewport_points[1] * 2 };
    const found = hit(state, resources, view, view.ray(ndc, viewport_points[0] / viewport_points[1])) orelse return false;
    // The topmost button there: the last painted.
    var pressed: ?[]const u8 = null;
    for (state.billboard_buttons.items) |button| {
        if (button.entity.eql(found.entity) and button.rect.contains(found.at[0], found.at[1])) pressed = button.node;
    }
    const name = pressed orelse return false;
    try state.recordClick(found.entity, name);
    return true;
}

/// Where a ray meets a billboard: its entity, how far along the ray, and where on its face (0
/// to 1 from its top left).
pub const Hit = struct {
    entity: ecs.EntityId,
    distance: f32,
    at: [2]f32,
};

/// The nearest of this frame's billboards (`gatherInto`) that `ray` meets, their faces turned as
/// seen through `view`; null when it misses them all. `ray`'s direction must be unit length for
/// `distance` to be in metres.
pub fn hit(state: *State, resources: Resources, view: camera.View, ray: camera.Ray) ?Hit {
    var nearest: ?Hit = null;
    for (state.shownBillboards()) |billboard| {
        const scene = state.sceneCache().get(resources, billboard.key()) orelse continue;
        const design = scene.design_size;
        if (!(design[0] > 0 and design[1] > 0)) continue;
        var found = hitFace(faceOf(billboard, design[1] / design[0], view), ray) orelse continue;
        if (nearest != null and found.distance >= nearest.?.distance) continue;
        found.entity = billboard.entity();
        nearest = found;
    }
    return nearest;
}

/// A billboard's face in the world: its bottom-left corner and its edges along its width and
/// its height.
const Face = struct { origin: [3]f32, across: [3]f32, upward: [3]f32 };

/// Where `ray` crosses `face` from its front or back, with no entity yet.
fn hitFace(face: Face, ray: camera.Ray) ?Hit {
    const normal = camera.cross(face.across, face.upward);
    const facing = dot(ray.direction, normal);
    if (@abs(facing) < 1e-9) return null;
    const distance = dot(camera.sub(face.origin, ray.origin), normal) / facing;
    if (distance < 0) return null;
    var offset: [3]f32 = undefined;
    for (&offset, ray.origin, ray.direction, face.origin) |*o, start, step, corner| o.* = start + step * distance - corner;
    const u = dot(offset, face.across) / dot(face.across, face.across);
    const v = dot(offset, face.upward) / dot(face.upward, face.upward);
    if (u < 0 or u > 1 or v < 0 or v > 1) return null;
    return .{ .entity = .{ .id = 0, .generation = 0 }, .distance = distance, .at = .{ u, 1 - v } };
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// Where `billboard`'s `tile` shows in the world (`faceOf`).
fn panelFor(billboard: Billboard, tile: ui.Rect, aspect: f32, view: camera.View, group: vit.BindGroup) world_draw.Panel {
    const face = faceOf(billboard, aspect, view);
    return .{
        .origin = face.origin,
        .across = face.across,
        .upward = face.upward,
        .uv_rect = .{ tile.x / atlas_size, tile.y / atlas_size, (tile.x + tile.w) / atlas_size, (tile.y + tile.h) / atlas_size },
        .group = group,
    };
}

/// Where `billboard`'s face is: centred on its entity, `width_m` wide and `aspect` (height over
/// width) of that tall, facing the camera or along its own X and Y.
fn faceOf(billboard: Billboard, aspect: f32, view: camera.View) Face {
    const model = billboard.model;
    const width_m = billboard.width_m;
    const height_m = width_m * aspect;
    var across: [3]f32 = undefined;
    var upward: [3]f32 = undefined;
    if (billboard.face_camera) {
        const right = camera.normalize(camera.cross(view.forward, view.up));
        const up = camera.normalize(camera.cross(right, view.forward));
        for (&across, &upward, right, up) |*a, *u, r, v| {
            a.* = r * width_m;
            u.* = v * height_m;
        }
    } else for (&across, &upward, 0..) |*a, *u, i| {
        a.* = model[0][i] * width_m;
        u.* = model[1][i] * height_m;
    }
    var origin: [3]f32 = undefined;
    for (&origin, across, upward, 0..) |*o, a, u, i| o.* = model[3][i] - (a + u) / 2;
    return .{ .origin = origin, .across = across, .upward = upward };
}

test "tiles fill rows and stop when the texture is full" {
    var shelf = Shelf{};
    const first = shelf.place(1000, 500).?;
    const second = shelf.place(1000, 300).?;
    const third = shelf.place(1000, 200).?;
    try std.testing.expectEqual(@as(f32, gap), first.x);
    try std.testing.expectEqual(first.y, second.y);
    try std.testing.expectEqual(first.y + 500 + gap, third.y);
    try std.testing.expect(shelf.place(atlas_size, 10) == null);
}

test "a camera-facing panel is centred on its entity" {
    var billboard = std.mem.zeroes(Billboard);
    billboard.width_m = 2;
    billboard.face_camera = true;
    billboard.model = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 5, 1, 0, 1 } };
    const view = camera.View{ .eye = .{ 5, 1, 10 }, .forward = .{ 0, 0, -1 }, .up = .{ 0, 1, 0 } };
    const panel = panelFor(billboard, .{ .x = 0, .y = 0, .w = 100, .h = 50 }, 0.5, view, undefined);
    try std.testing.expectApproxEqAbs(@as(f32, 4), panel.origin[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), panel.origin[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), panel.across[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), panel.upward[1], 1e-5);
}

test "a ray meets a face where it crosses it, measured from the top left" {
    const face = Face{ .origin = .{ -1, -0.5, 0 }, .across = .{ 2, 0, 0 }, .upward = .{ 0, 1, 0 } };
    const found = hitFace(face, .{ .origin = .{ 0.5, 0.25, 5 }, .direction = .{ 0, 0, -1 } }).?;
    try std.testing.expectApproxEqAbs(@as(f32, 5), found.distance, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), found.at[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), found.at[1], 1e-5);
    try std.testing.expect(hitFace(face, .{ .origin = .{ 3, 0, 5 }, .direction = .{ 0, 0, -1 } }) == null);
    try std.testing.expect(hitFace(face, .{ .origin = .{ 0, 0, 5 }, .direction = .{ 0, 0, 1 } }) == null);
}

test "a press over a painted button records its click" {
    var state = State{ .gpa = std.testing.allocator };
    defer state.deinit();
    const sign = ecs.EntityId{ .id = 2, .generation = 1 };
    // A scene the cache already holds, so nothing is read.
    var billboard = std.mem.zeroes(Billboard);
    billboard.entity_id = 2;
    billboard.entity_generation = 1;
    billboard.width_m = 2;
    billboard.face_camera = true;
    billboard.model = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
    @memcpy(billboard.scene[0..8], "s.ui.zon");
    billboard.scene_len = 8;
    state.billboards[0] = billboard;
    state.billboard_count = 1;
    const parsed = try state.gpa.create(@import("eggy_assets").ui_scene.Parsed);
    parsed.* = try @import("eggy_assets").ui_scene.parse(state.gpa, ".{ .design_size = .{ 200, 100 }, .root = .{} }");
    try state.sceneCache().entries.put(state.gpa, try state.gpa.dupe(u8, "s.ui.zon"), parsed);
    try state.billboard_buttons.append(state.gpa, .{ .entity = sign, .node = "go", .rect = .{ .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 } });
    const view = camera.View{ .eye = .{ 0, 0, 10 }, .forward = .{ 0, 0, -1 }, .up = .{ 0, 1, 0 } };
    // The view's top right quarter is the billboard's; its middle is not a button.
    try std.testing.expect(!try press(&state, .{}, view, .{ 800, 600 }, .{ 400, 300 }));
    const half_height = 10 * @tan(30 * std.math.rad_per_deg);
    const x = 400 + 0.5 / (half_height * 800.0 / 600.0) * 400;
    const y = 300 - 0.25 / half_height * 300;
    try std.testing.expect(try press(&state, .{}, view, .{ 800, 600 }, .{ x, y }));
    try std.testing.expectEqualStrings("go", state.clicks.items[0].node);
    try std.testing.expect(state.clicks.items[0].entity.eql(sign));
}
