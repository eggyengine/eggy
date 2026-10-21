//! What the Scene panel draws for lights and cameras, which have no mesh of their own: a low-poly
//! bulb for each point light, a spotlight for each spot light and a film camera for each camera,
//! built from the built-in shapes and placed by their entity every frame, so turning one is seen
//! as it happens; and a sun badge facing the view for each directional light, with a tick the
//! way it shines. Editor-only: none of it is saved, picked by the game, or casts a shadow.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const Drawable = eggy.mesh.Drawable;
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;

/// How a part's shape is turned before it is placed: built-in cylinders and cones run along +Y.
const Turn = enum { none, along_z, along_x };

/// One shape of a stand-in, in its entity's space (metres): where, how big, which way, and colour.
const Part = struct {
    shape: eggy.mesh.Shape,
    at: [3]f32 = .{ 0, 0, 0 },
    size: [3]f32,
    turn: Turn = .none,
    color: [3]f32,
    /// How much of the colour it gives off, so it reads in an unlit scene; `glows` takes the
    /// light's own colour instead.
    glow: f32 = 0.3,
    glows: bool = false,
    metallic: f32 = 0,
};

const metal = [3]f32{ 0.55, 0.56, 0.6 };
const dark = [3]f32{ 0.16, 0.17, 0.19 };
const glass = [3]f32{ 0.35, 0.55, 0.9 };

/// A bulb, its glass round the entity's origin and its screw cap below.
const bulb = [_]Part{
    .{ .shape = .sphere, .at = .{ 0, 0.04, 0 }, .size = @splat(0.26), .color = .{ 1, 1, 1 }, .glows = true },
    .{ .shape = .sphere, .at = .{ 0, -0.08, 0 }, .size = .{ 0.15, 0.12, 0.15 }, .color = .{ 1, 1, 1 }, .glows = true },
    .{ .shape = .cylinder, .at = .{ 0, -0.15, 0 }, .size = .{ 0.13, 0.1, 0.13 }, .color = metal, .metallic = 0.8 },
    .{ .shape = .cylinder, .at = .{ 0, -0.13, 0 }, .size = .{ 0.145, 0.02, 0.145 }, .color = metal, .metallic = 0.8 },
    .{ .shape = .cylinder, .at = .{ 0, -0.17, 0 }, .size = .{ 0.145, 0.02, 0.145 }, .color = metal, .metallic = 0.8 },
    .{ .shape = .sphere, .at = .{ 0, -0.205, 0 }, .size = @splat(0.06), .color = dark },
};

/// A can light shining along local -Z: its housing narrows to the back, its lens at the front.
const spotlight = [_]Part{
    .{ .shape = .cone, .at = .{ 0, 0, 0.02 }, .size = .{ 0.3, 0.34, 0.3 }, .turn = .along_z, .color = dark, .metallic = 0.5 },
    .{ .shape = .cylinder, .at = .{ 0, 0, 0.2 }, .size = .{ 0.13, 0.08, 0.13 }, .turn = .along_z, .color = metal, .metallic = 0.8 },
    .{ .shape = .cylinder, .at = .{ 0, 0, -0.155 }, .size = .{ 0.31, 0.03, 0.31 }, .turn = .along_z, .color = metal, .metallic = 0.8 },
    .{ .shape = .cylinder, .at = .{ 0, 0, -0.17 }, .size = .{ 0.27, 0.01, 0.27 }, .turn = .along_z, .color = .{ 1, 1, 1 }, .glows = true },
};

/// A film camera looking along local -Z with +Y up: its body, lens, and two reels on top.
const film_camera = [_]Part{
    .{ .shape = .cube, .at = .{ 0, 0, 0.05 }, .size = .{ 0.18, 0.24, 0.4 }, .color = dark },
    .{ .shape = .cylinder, .at = .{ 0, 0, -0.2 }, .size = .{ 0.13, 0.1, 0.13 }, .turn = .along_z, .color = metal, .metallic = 0.8 },
    .{ .shape = .cone, .at = .{ 0, 0, -0.3 }, .size = .{ 0.22, 0.12, 0.22 }, .turn = .along_z, .color = glass, .glow = 0.35 },
    .{ .shape = .cylinder, .at = .{ 0, 0.22, 0.16 }, .size = .{ 0.2, 0.06, 0.2 }, .turn = .along_x, .color = dark },
    .{ .shape = .cylinder, .at = .{ 0, 0.22, -0.06 }, .size = .{ 0.2, 0.06, 0.2 }, .turn = .along_x, .color = dark },
    .{ .shape = .cylinder, .at = .{ 0, 0.22, 0.16 }, .size = .{ 0.08, 0.065, 0.08 }, .turn = .along_x, .color = metal, .metallic = 0.8 },
    .{ .shape = .cylinder, .at = .{ 0, 0.22, -0.06 }, .size = .{ 0.08, 0.065, 0.08 }, .turn = .along_x, .color = metal, .metallic = 0.8 },
};

/// Append the stand-ins of `lights` (point and spot ones; directional ones are `suns`) and of
/// every camera in `app`'s world to `out` after its first `count`, each part carrying its
/// entity so clicking it selects that. Returns the new count; parts past `out.len` are left out.
/// Editor-only: reads cameras and transforms through `game`.
///
/// ```zig
/// count = stand_ins.append(game, app, &app.graphics.lights, drawables, count);
/// ```
pub fn append(game: *const HotGame, app: *eggy.App, lights: *const eggy.lighting.Frame, out: []Drawable, count: usize) usize {
    var written = count;
    for (lights.lights[0..lights.count], lights.entities[0..lights.count]) |light, source| {
        const parts: []const Part = switch (lightKind(light)) {
            .directional => continue,
            .point => &bulb,
            .spot => &spotlight,
        };
        const entity = eggy.ecs.EntityId.init(source.id, source.generation);
        const placed = game.worldMatrix(app, entity) orelse continue;
        const shine = [3]f32{ light.color_intensity[0], light.color_intensity[1], light.color_intensity[2] };
        written = place(parts, placed, entity, shine, out, written);
    }

    const camera = game.builtinComponent("Camera") orelse return written;
    for (app.world.slots.items, 0..) |slot, i| {
        if (!slot.alive) continue;
        const entity = eggy.ecs.EntityId.init(@intCast(i), slot.generation);
        if (!game.hasComponent(app, entity, camera)) continue;
        const placed = game.worldMatrix(app, entity) orelse continue;
        written = place(&film_camera, placed, entity, .{ 1, 1, 1 }, out, written);
    }
    return written;
}

const LightKind = enum { directional, point, spot };

/// The kind `lighting.gather` packed into the light's `position_kind.w`.
fn lightKind(light: eggy.lighting.GpuLight) LightKind {
    return switch (@as(u32, @intFromFloat(@round(light.position_kind[3])))) {
        0 => .directional,
        1 => .point,
        else => .spot,
    };
}

/// Write `parts` placed by `placed` (the entity's world matrix, by column) into `out` from `at`.
fn place(parts: []const Part, placed: [4][4]f32, entity: eggy.ecs.EntityId, shine: [3]f32, out: []Drawable, at: usize) usize {
    var written = at;
    for (parts) |part| {
        if (written >= out.len) break;
        const color = if (part.glows) brightest(shine) else part.color;
        const glow: f32 = if (part.glows) 0.85 else part.glow;
        out[written] = .{
            .model = multiply(placed, local(part)),
            .color = .{ 1, 1, 1, 1 },
            .shape = part.shape,
            .entity_id = entity.id,
            .entity_generation = entity.generation,
            .surface_color = .{ color[0], color[1], color[2], 1 },
            .material_params = .{ part.metallic, 0.5, 0, 1 },
            .emissive_cutoff = .{ color[0] * glow, color[1] * glow, color[2] * glow, 0.01 },
            .casts_shadow = 0,
        };
        written += 1;
    }
    return written;
}

/// A light's colour scaled so its brightest channel is 1: the hue, whatever its intensity.
fn brightest(color: [3]f32) [3]f32 {
    const top = @max(color[0], @max(color[1], color[2]));
    if (top <= 0.0001) return .{ 1, 1, 1 };
    return .{ color[0] / top, color[1] / top, color[2] / top };
}

/// The part's own matrix, by column: sized, turned, then moved to `at`.
fn local(part: Part) [4][4]f32 {
    const x: [3]f32, const y: [3]f32, const z: [3]f32 = switch (part.turn) {
        .none => .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } },
        // A quarter turn round X: +Y becomes +Z (a cone's tip then points backwards).
        .along_z => .{ .{ 1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, -1, 0 } },
        // A quarter turn round Z: +Y becomes -X.
        .along_x => .{ .{ 0, 1, 0 }, .{ -1, 0, 0 }, .{ 0, 0, 1 } },
    };
    const s = part.size;
    return .{
        .{ x[0] * s[0], x[1] * s[0], x[2] * s[0], 0 },
        .{ y[0] * s[1], y[1] * s[1], y[2] * s[1], 0 },
        .{ z[0] * s[2], z[1] * s[2], z[2] * s[2], 0 },
        .{ part.at[0], part.at[1], part.at[2], 1 },
    };
}

/// `a` times `b`, both by column.
fn multiply(a: [4][4]f32, b: [4][4]f32) [4][4]f32 {
    var result: [4][4]f32 = undefined;
    for (0..4) |column| {
        for (0..4) |row| {
            var sum: f32 = 0;
            for (0..4) |k| sum += a[k][row] * b[column][k];
            result[column][row] = sum;
        }
    }
    return result;
}

/// A directional light's badge on the Scene panel, in its points: where the light is, the end of
/// its tick (one metre the way it shines, if that is in front of the view), its colour and entity.
pub const Sun = struct {
    at: ui.Vec2,
    tip: ?ui.Vec2,
    color: [3]f32,
    entity: eggy.ecs.EntityId,
};

/// How far from a badge's centre a click still picks it, in points.
pub const sun_radius: f32 = 14;

/// The badges of `lights`' directional lights seen through `view` on the panel at `scene`,
/// written into `out`; those behind the view are left out. Returns how many there are.
pub fn suns(lights: *const eggy.lighting.Frame, view: eggy.camera.View, scene: ui.Rect, out: []Sun) usize {
    const view_projection = view.viewProjection(scene.w / scene.h);
    var count: usize = 0;
    for (lights.lights[0..lights.count], lights.entities[0..lights.count]) |light, source| {
        if (lightKind(light) != .directional or count >= out.len) continue;
        const position = [3]f32{ light.position_kind[0], light.position_kind[1], light.position_kind[2] };
        const at = onPanel(view_projection, scene, position) orelse continue;
        const ahead = [3]f32{ position[0] + light.direction_range[0], position[1] + light.direction_range[1], position[2] + light.direction_range[2] };
        out[count] = .{
            .at = at,
            .tip = onPanel(view_projection, scene, ahead),
            .color = brightest(.{ light.color_intensity[0], light.color_intensity[1], light.color_intensity[2] }),
            .entity = .init(source.id, source.generation),
        };
        count += 1;
    }
    return count;
}

/// Where `point` is on the panel at `scene`, null when it is behind the view.
fn onPanel(view_projection: [4][4]f32, scene: ui.Rect, point: [3]f32) ?ui.Vec2 {
    const projected = eggy.camera.project(view_projection, point);
    if (!projected.in_front) return null;
    return .{ .x = scene.x + (projected.x + 1) / 2 * scene.w, .y = scene.y + (1 - projected.y) / 2 * scene.h };
}

/// The light of the badge under `pointer`, if any; the nearest when they overlap.
pub fn sunAt(shown: []const Sun, pointer: ui.Vec2) ?eggy.ecs.EntityId {
    var best: ?eggy.ecs.EntityId = null;
    var best_distance: f32 = sun_radius * sun_radius;
    for (shown) |sun| {
        const dx = sun.at.x - pointer.x;
        const dy = sun.at.y - pointer.y;
        const distance = dx * dx + dy * dy;
        if (distance > best_distance) continue;
        best_distance = distance;
        best = sun.entity;
    }
    return best;
}

/// A paint that draws the badges of `shown` (copied into `arena`).
pub fn paint(arena: std.mem.Allocator, shown: []const Sun) ui.Layout.Paint {
    const held = arena.create(Badges) catch return .none;
    held.* = .{ .suns = arena.dupe(Sun, shown) catch return .none };
    return .{ .custom = .{ .context = held, .draw = draw } };
}

const Badges = struct { suns: []const Sun };

fn draw(context: *const anyopaque, c: *ui.Canvas, _: ui.Rect) anyerror!void {
    const badges: *const Badges = @ptrCast(@alignCast(context));
    for (badges.suns) |sun| {
        const color = [4]f32{ sun.color[0], sun.color[1], sun.color[2], 1 };
        const outline = [4]f32{ 0.1, 0.1, 0.1, 0.9 };

        // The tick, under the badge, from its centre the way the light shines.
        if (sun.tip) |tip| try line(c, sun.at, tip, 2.5, outline);
        if (sun.tip) |tip| try line(c, sun.at, tip, 1.25, color);

        // Eight rays round a disc.
        for (0..8) |ray| {
            const angle = std.math.tau * @as(f32, @floatFromInt(ray)) / 8;
            const ux = @cos(angle);
            const uy = @sin(angle);
            const base: f32 = 7.5;
            const end: f32 = 12.5;
            const half: f32 = 2;
            try c.triangle(.{
                .{ sun.at.x + ux * end, sun.at.y + uy * end },
                .{ sun.at.x + ux * base - uy * half, sun.at.y + uy * base + ux * half },
                .{ sun.at.x + ux * base + uy * half, sun.at.y + uy * base - ux * half },
            }, .{ color, color, color });
        }
        try c.roundRect(.{ .x = sun.at.x - 7, .y = sun.at.y - 7, .w = 14, .h = 14 }, .{ 0.1, 0.1, 0.1 }, 7);
        try c.roundRect(.{ .x = sun.at.x - 5.5, .y = sun.at.y - 5.5, .w = 11, .h = 11 }, sun.color, 5.5);
    }
}

/// A line from `from` to `to`, `half_width` points either side.
fn line(c: *ui.Canvas, from: ui.Vec2, to: ui.Vec2, half_width: f32, color: [4]f32) !void {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const span = @sqrt(dx * dx + dy * dy);
    if (span < 1) return;
    const nx = -dy / span * half_width;
    const ny = dx / span * half_width;
    const colors = .{ color, color, color };
    try c.triangle(.{ .{ from.x + nx, from.y + ny }, .{ to.x + nx, to.y + ny }, .{ to.x - nx, to.y - ny } }, colors);
    try c.triangle(.{ .{ from.x + nx, from.y + ny }, .{ to.x - nx, to.y - ny }, .{ from.x - nx, from.y - ny } }, colors);
}

test "a part is placed by its entity: a turned spotlight's lens follows the turn" {
    // The entity half a turn round Y, at (5, 0, 0): its -Z (where the lens sits) is world +Z.
    const turned = [4][4]f32{ .{ -1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, -1, 0 }, .{ 5, 0, 0, 1 } };
    var out: [spotlight.len]Drawable = undefined;
    const written = place(&spotlight, turned, .init(3, 1), .{ 2, 1, 0 }, &out, 0);
    try std.testing.expectEqual(spotlight.len, written);
    const lens = out[3];
    try std.testing.expectApproxEqAbs(@as(f32, 5), lens.model[3][0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.17), lens.model[3][2], 0.0001);
    // Its axis (built along +Y) now runs along Z, and it glows the light's hue.
    try std.testing.expectApproxEqAbs(@as(f32, 0), lens.model[1][1], 0.0001);
    try std.testing.expectEqual(@as(f32, 0.5), lens.surface_color[1]);
    try std.testing.expectEqual(@as(u32, 0), lens.casts_shadow);
    try std.testing.expectEqual(@as(u32, 3), lens.entity_id);
}

test "only directional lights get a badge, placed where they are and ticked the way they shine" {
    var lights = eggy.lighting.Frame{ .count = 2 };
    lights.lights[0] = .{ .position_kind = .{ 0, 0, 0, 0 }, .direction_range = .{ 0, 0, -1, 0 }, .color_intensity = .{ 1, 1, 1, 1000 } };
    lights.lights[1] = .{ .position_kind = .{ 0, 0, 0, 1 }, .color_intensity = .{ 1, 1, 1, 100 } };
    lights.entities[0] = .{ .id = 7, .generation = 2 };
    const scene = ui.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    // From +X looking back at the origin: world -Z is to the right.
    const view = eggy.camera.View.lookingAt(.{ 10, 0, 0 }, .{ 0, 0, 0 }, .{});
    var shown: [4]Sun = undefined;
    try std.testing.expectEqual(@as(usize, 1), suns(&lights, view, scene, &shown));
    try std.testing.expectApproxEqAbs(@as(f32, 400), shown[0].at.x, 0.5);
    try std.testing.expect(shown[0].tip.?.x > shown[0].at.x + 10);
    try std.testing.expectEqual(@as(u32, 7), sunAt(shown[0..1], .{ .x = 405, .y = 303 }).?.id);
    try std.testing.expect(sunAt(shown[0..1], .{ .x = 450, .y = 300 }) == null);
}
