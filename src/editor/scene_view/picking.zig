//! Which entity is under a point of the Scene panel: a ray from the camera through it, tested
//! against each mesh's shape (a model file's box round its vertices) in the mesh's own space,
//! and against each billboard's face, the nearest hit winning.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;

/// The entity whose mesh (of `drawn`) or billboard (of `ui_scenes`, read through `resources`) is
/// nearest the camera under `pointer`, seen through `view` in `scene` (the Scene panel's rect),
/// model files' boxes from `models`; null over nothing.
/// Editor-only: scene dimensions must be positive and pointer/rect use the same UI coordinates.
/// Does not clip the pointer or load models; missing model bounds and singular transforms are
/// skipped. Uses sphere hits or approximate bounding boxes, returning an id value without
/// mutating selection or taking ownership of drawables/cache.
///
/// ```zig
/// // Given current drawables, loaded model cache, camera view and Scene UI rect:
/// const entity = pick(drawables, &graphics.models, &app.ui_scenes, app.resources(), view, scene, pointer);
/// ```
pub fn pick(drawn: []const eggy.mesh.Drawable, models: *const eggy.model_cache.ModelCache, ui_scenes: *eggy.ui_scenes.State, resources: eggy.resources.Resources, view: eggy.camera.View, scene: ui.Rect, pointer: ui.Vec2) ?eggy.ecs.EntityId {
    const ray = rayThrough(view, scene, pointer);
    const billboard = eggy.ui_scenes.billboards.hit(ui_scenes, resources, view, ray);

    var nearest: ?eggy.ecs.EntityId = null;
    var nearest_t = std.math.inf(f32);
    for (drawn) |drawable| {
        // The ray in the mesh's own space, where its shape is a metre across round the origin;
        // `t` means the same distance along it in both.
        const to_local = eggy.transform.invert(drawable.model) orelse continue;
        const origin = eggy.transform.apply(to_local, ray.origin, 1);
        const along = eggy.transform.apply(to_local, ray.direction, 0);
        const hit: ?f32 = if (drawable.modelFile()) |file| blk: {
            const box = models.bounds(file) orelse continue;
            break :blk hitBox(origin, along, box.min, box.max);
        } else switch (drawable.shape) {
            .sphere => hitSphere(origin, along),
            .plane => hitBox(origin, along, .{ -0.5, -0.001, -0.5 }, .{ 0.5, 0.001, 0.5 }),
            .cube, .cylinder, .cone => hitBox(origin, along, .{ -0.5, -0.5, -0.5 }, .{ 0.5, 0.5, 0.5 }),
        };
        const t = hit orelse continue;
        if (t < nearest_t) {
            nearest_t = t;
            nearest = drawable.entity();
        }
    }
    if (billboard) |sign| if (sign.distance < nearest_t) return sign.entity;
    return nearest;
}

/// The world ray from the camera through `pointer` on the view in `scene`: from the eye for a
/// perspective camera, and from the point on the eye's plane for an orthographic one, whose
/// rays run parallel. The direction is unit length.
/// Editor-only: requires positive scene width/height and a valid camera. Pointers outside the
/// rect still give a ray. Pure calculation.
///
/// ```zig
/// // Given camera view, positive-sized Scene rect and UI-space pointer:
/// const ray = rayThrough(view, scene, pointer);
/// ```
pub fn rayThrough(view: eggy.camera.View, scene: ui.Rect, pointer: ui.Vec2) eggy.camera.Ray {
    const x = (pointer.x - scene.x) / scene.w * 2 - 1;
    const y = 1 - (pointer.y - scene.y) / scene.h * 2;
    return view.ray(.{ x, y }, scene.w / scene.h);
}

/// Where the ray first enters the box from `min` to `max`, if it does.
// ponytail: round shapes and models are tested as their boxes; test their triangles if picking past their corners annoys.
fn hitBox(origin: [3]f32, along: [3]f32, min: [3]f32, max: [3]f32) ?f32 {
    var enter: f32 = 0;
    var leave = std.math.inf(f32);
    for (origin, along, min, max) |start, step, low, high| {
        if (@abs(step) < 1e-9) {
            if (start < low or start > high) return null;
            continue;
        }
        const a = (low - start) / step;
        const b = (high - start) / step;
        enter = @max(enter, @min(a, b));
        leave = @min(leave, @max(a, b));
        if (enter > leave) return null;
    }
    return enter;
}

/// Where the ray first meets the sphere half a metre round the origin, if it does.
fn hitSphere(origin: [3]f32, along: [3]f32) ?f32 {
    const a = dot(along, along);
    const b = 2 * dot(origin, along);
    const c = dot(origin, origin) - 0.25;
    const discriminant = b * b - 4 * a * c;
    if (discriminant < 0 or a == 0) return null;
    const t = (-b - @sqrt(discriminant)) / (2 * a);
    return if (t >= 0) t else null;
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

test "an orthographic pointer ray is parallel and starts beside the eye" {
    const scene = ui.Rect{ .x = 0, .y = 0, .w = 800, .h = 400 };
    const view = eggy.camera.View.lookingAt(.{ 0, 0, 10 }, .{ 0, 0, 0 }, .{ .projection = .orthographic, .orthographic_height_m = 4 });
    const ray = rayThrough(view, scene, .{ .x = 800, .y = 200 });
    // The right edge is half the view's width (4 m tall at 2:1 is 8 m wide) from its centre.
    try std.testing.expectApproxEqAbs(@as(f32, 4), ray.origin[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), ray.direction[2], 0.001);
    const cube = eggy.mesh.Drawable{ .model = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 3.5, 0, -5, 1 } }, .color = .{ 1, 1, 1, 1 }, .shape = .cube, .entity_id = 9, .entity_generation = 0 };
    var models = eggy.model_cache.ModelCache.init(std.testing.allocator, undefined);
    var ui_scenes = eggy.ui_scenes.State{ .gpa = std.testing.allocator };
    try std.testing.expectEqual(@as(u32, 9), pick(&.{cube}, &models, &ui_scenes, .{}, view, scene, .{ .x = 790, .y = 200 }).?.id);
    try std.testing.expect(pick(&.{cube}, &models, &ui_scenes, .{}, view, scene, .{ .x = 400, .y = 200 }) == null);
}

test "the nearest mesh under the pointer is picked, and empty space picks nothing" {
    const scene = ui.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    const view = eggy.camera.View.lookingAt(.{ 0, 0, 10 }, .{ 0, 0, 0 }, .{});
    const at = struct {
        fn f(z: f32, id: u32) eggy.mesh.Drawable {
            return .{ .model = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, z, 1 } }, .color = .{ 1, 1, 1, 1 }, .shape = .cube, .entity_id = id, .entity_generation = 0 };
        }
    }.f;
    const drawn = [_]eggy.mesh.Drawable{ at(0, 1), at(3, 2) };
    var models = eggy.model_cache.ModelCache.init(std.testing.allocator, undefined);
    var ui_scenes = eggy.ui_scenes.State{ .gpa = std.testing.allocator };
    try std.testing.expectEqual(@as(u32, 2), pick(&drawn, &models, &ui_scenes, .{}, view, scene, .{ .x = 400, .y = 300 }).?.id);
    try std.testing.expect(pick(&drawn, &models, &ui_scenes, .{}, view, scene, .{ .x = 5, .y = 5 }) == null);

    // A model, picked by its box: four metres across, so it is hit well off its centre.
    var model = at(0, 3);
    model.model_file = "rat.glb";
    model.model_file_len = 7;
    try models.entries.put(std.testing.allocator, "rat.glb", .{ .vertices = undefined, .indices = undefined, .parts = &.{}, .bounds = .{ .min = .{ -2, -2, -2 }, .max = .{ 2, 2, 2 } } });
    defer models.entries.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), pick(&.{model}, &models, &ui_scenes, .{}, view, scene, .{ .x = 520, .y = 300 }).?.id);
}
