//! Which entity is under a point of the Scene panel: a ray from the camera through it, tested
//! against each mesh's shape (a model file's box round its vertices) in the mesh's own space,
//! the nearest hit winning.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;

/// The entity whose mesh (of `drawn`) is nearest the camera under `pointer`, seen through `view`
/// in `scene` (the Scene panel's rect), model files' boxes from `models`; null over nothing.
pub fn pick(drawn: []const eggy.mesh.Drawable, models: *const eggy.model_cache.ModelCache, view: eggy.camera.View, scene: ui.Rect, pointer: ui.Vec2) ?eggy.ecs.EntityId {
    const direction = rayThrough(view, scene, pointer);

    var nearest: ?eggy.ecs.EntityId = null;
    var nearest_t = std.math.inf(f32);
    for (drawn) |drawable| {
        // The ray in the mesh's own space, where its shape is a metre across round the origin;
        // `t` means the same distance along it in both.
        const to_local = eggy.transform.invert(drawable.model) orelse continue;
        const origin = eggy.transform.apply(to_local, view.eye, 1);
        const along = eggy.transform.apply(to_local, direction, 0);
        const hit: ?f32 = if (drawable.modelFile()) |file| blk: {
            const box = models.bounds(file) orelse continue;
            break :blk hitBox(origin, along, box[0], box[1]);
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
    return nearest;
}

/// The direction from the camera through `pointer` on the view in `scene` (not unit length).
pub fn rayThrough(view: eggy.camera.View, scene: ui.Rect, pointer: ui.Vec2) [3]f32 {
    const x = (pointer.x - scene.x) / scene.w * 2 - 1;
    const y = 1 - (pointer.y - scene.y) / scene.h * 2;
    const half_height = @tan(view.fov_deg * std.math.rad_per_deg / 2);
    const right = eggy.camera.normalize(eggy.camera.cross(view.forward, view.up));
    var direction: [3]f32 = undefined;
    for (&direction, view.forward, right, view.up) |*part, ahead, across, up| part.* = ahead + across * x * half_height * (scene.w / scene.h) + up * y * half_height;
    return direction;
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
    try std.testing.expectEqual(@as(u32, 2), pick(&drawn, &models, view, scene, .{ .x = 400, .y = 300 }).?.id);
    try std.testing.expect(pick(&drawn, &models, view, scene, .{ .x = 5, .y = 5 }) == null);

    // A model, picked by its box: four metres across, so it is hit well off its centre.
    var model = at(0, 3);
    model.model_file = "rat.glb";
    model.model_file_len = 7;
    try models.entries.put(std.testing.allocator, "rat.glb", .{ .vertices = undefined, .indices = undefined, .parts = &.{}, .min = .{ -2, -2, -2 }, .max = .{ 2, 2, 2 } });
    defer models.entries.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), pick(&.{model}, &models, view, scene, .{ .x = 520, .y = 300 }).?.id);
}
