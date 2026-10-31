//! The arrow drawn from a selected directional or spot light along the way it shines (local -Z),
//! so a light that points at the horizon is seen to do so.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const gizmo = @import("gizmo.zig");

/// How long the arrow is, in gizmo handle lengths.
const arrow_lengths: f32 = 2.5;
const arrow_color = [4]f32{ 1, 0.85, 0.3, 0.95 };

/// The arrow on screen, in the Scene panel's points.
pub const Arrow = struct { from: ui.Vec2, to: ui.Vec2 };

/// Whether a `SceneLight.kind` field read as ZON (`.directional`) shines along a direction.
pub fn shinesAlongDirection(kind_zon: []const u8) bool {
    return std.mem.eql(u8, kind_zon, ".directional") or std.mem.eql(u8, kind_zon, ".spot");
}

/// The arrow for a light placed by `placed` (its world matrix), sized and projected
/// like `handles`; null when the light's end is behind the camera.
pub fn arrow(handles: gizmo.Layout, placed: eggy.math.Mat4) ?Arrow {
    const shine = eggy.math.transformDirection4x4(f32, placed, .forward).normalize();
    const tip_world = handles.origin_world.add(shine.scale(handles.world_length * arrow_lengths));
    const projected = eggy.camera.project(handles.view.viewProjection(handles.scene.w / handles.scene.h), tip_world);
    if (!projected.in_front) return null;
    const scene = handles.scene;
    return .{
        .from = handles.origin,
        .to = .{ .x = scene.x + (projected.x + 1) / 2 * scene.w, .y = scene.y + (1 - projected.y) / 2 * scene.h },
    };
}

/// A paint that draws `shown` as a line with an arrow head.
pub fn paint(arena: std.mem.Allocator, shown: Arrow) ui.Layout.Paint {
    const drawing = arena.create(Arrow) catch return .none;
    drawing.* = shown;
    return .{ .custom = .{ .context = drawing, .draw = draw } };
}

fn draw(context: *const anyopaque, c: *ui.Canvas, _: ui.Rect) anyerror!void {
    const shown: *const Arrow = @ptrCast(@alignCast(context));
    const dx = shown.to.x - shown.from.x;
    const dy = shown.to.y - shown.from.y;
    const span = @sqrt(dx * dx + dy * dy);
    if (span < 1) return;
    const ux = dx / span;
    const uy = dy / span;

    // The shaft, then a head at the tip.
    const half_width: f32 = 1.25;
    const a = [2]f32{ shown.from.x - uy * half_width, shown.from.y + ux * half_width };
    const b = [2]f32{ shown.to.x - uy * half_width, shown.to.y + ux * half_width };
    const d = [2]f32{ shown.to.x + uy * half_width, shown.to.y - ux * half_width };
    const e = [2]f32{ shown.from.x + uy * half_width, shown.from.y - ux * half_width };
    const colors = .{ arrow_color, arrow_color, arrow_color };
    try c.triangle(.{ a, b, d }, colors);
    try c.triangle(.{ a, d, e }, colors);
    const head: f32 = 12;
    const base = [2]f32{ shown.to.x - ux * head, shown.to.y - uy * head };
    try c.triangle(.{ .{ shown.to.x + ux * 3, shown.to.y + uy * 3 }, .{ base[0] - uy * head / 2, base[1] + ux * head / 2 }, .{ base[0] + uy * head / 2, base[1] - ux * head / 2 } }, colors);
}

test "only directional and spot lights get an arrow" {
    try std.testing.expect(shinesAlongDirection(".directional"));
    try std.testing.expect(shinesAlongDirection(".spot"));
    try std.testing.expect(!shinesAlongDirection(".point"));
}

test "an unrotated light's arrow runs along the world's -Z" {
    const identity = eggy.math.identity(f32, 4);
    const scene = ui.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    // From +X looking back at the origin, world -Z is to the right of the screen.
    const view = eggy.camera.View.lookingAt(.init(10, 0, 0), .zero, .{});
    const handles = gizmo.layout(.move, .world, identity, view, scene).?;
    const shown = arrow(handles, identity).?;
    try std.testing.expect(shown.to.x > shown.from.x + 10);
    try std.testing.expect(@abs(shown.to.y - shown.from.y) < 1);
}
