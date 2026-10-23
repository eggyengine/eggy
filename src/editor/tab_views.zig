//! Each workspace tab's own view through the panels it has a copy of (`panels.Live`): the Scene's
//! camera and toolbar, the 2D Scene's centre, zoom, grid and snap, and the UI scene the UI
//! Designer has open. The editor has one of each; when another copy goes live, the one in use is
//! put aside for its copy and the new copy's is put in its place.
const std = @import("std");
const panels = @import("panels.zig");
const scene_view = @import("scene_view/scene_view.zig");
const Scene2d = @import("scene_2d.zig").Scene2d;
const ui_designer = @import("ui_designer/ui_designer.zig");
const log = std.log.scoped(.tabs);

/// What a Scene copy keeps while another is live.
const SceneLook = struct { camera: scene_view.SceneCamera, tools: scene_view.toolbar.State };

/// What a 2D Scene copy keeps while another is live.
const FlatLook = struct { centre: [2]f32, height_m: f32, grid: bool, snap: bool };

pub const TabViews = struct {
    /// The copies whose views are in use now.
    applied: panels.Live = .{},
    scenes: [panels.max_copies]?SceneLook = @splat(null),
    flats: [panels.max_copies]?FlatLook = @splat(null),
    /// Each UI copy's open UI scene (project-relative, owned), when it isn't live.
    ui_paths: [panels.max_copies]?[]u8 = @splat(null),

    pub fn deinit(self: *TabViews, gpa: std.mem.Allocator) void {
        for (self.ui_paths) |path| if (path) |owned| gpa.free(owned);
        self.* = .{};
    }

    /// Put the live copies' views in place of those in use, keeping those for their copies. A
    /// copy never seen before starts from the defaults (an empty UI Designer). Without `env` (no
    /// project open) the UI Designer is left as it is. A UI scene that won't open again is logged
    /// and left closed.
    pub fn follow(self: *TabViews, gpa: std.mem.Allocator, live: panels.Live, scene: *scene_view.SceneView, flat: *Scene2d, designer: *ui_designer.Designer, env: ?ui_designer.Env) void {
        if (live.scene != self.applied.scene) {
            scene.camera.cancelNavigation();
            self.scenes[self.applied.scene] = .{ .camera = scene.camera, .tools = scene.tools };
            const next = self.scenes[live.scene] orelse SceneLook{ .camera = .{}, .tools = .{} };
            scene.camera = next.camera;
            scene.tools = next.tools;
            self.applied.scene = live.scene;
        }
        if (live.scene_2d != self.applied.scene_2d) {
            self.flats[self.applied.scene_2d] = .{ .centre = flat.centre, .height_m = flat.height_m, .grid = flat.grid, .snap = flat.snap };
            const next = self.flats[live.scene_2d] orelse FlatLook{ .centre = .{ 0, 0 }, .height_m = 12, .grid = true, .snap = false };
            flat.* = .{ .centre = next.centre, .height_m = next.height_m, .grid = next.grid, .snap = next.snap };
            self.applied.scene_2d = live.scene_2d;
        }
        if (live.ui != self.applied.ui) if (env) |designer_env| {
            // The scene open goes aside under its copy; the live copy's comes back.
            const kept = if (designer.openPath()) |path| gpa.dupe(u8, path) catch null else null;
            if (self.ui_paths[self.applied.ui]) |old| gpa.free(old);
            self.ui_paths[self.applied.ui] = kept;
            designer.close();
            if (self.ui_paths[live.ui]) |path| {
                designer.open(designer_env, path) catch |err| log.warn("cannot open UI scene {s} again: {t}", .{ path, err });
                gpa.free(path);
                self.ui_paths[live.ui] = null;
            }
            self.applied.ui = live.ui;
        };
    }
};

test "each Scene and 2D Scene copy keeps its own view while another is live" {
    var views = TabViews{};
    defer views.deinit(std.testing.allocator);
    var scene = scene_view.SceneView{};
    var flat = Scene2d{};
    var designer = ui_designer.Designer{};
    scene.camera.distance = 40;
    flat.height_m = 3;

    // A new copy starts from the defaults.
    views.follow(std.testing.allocator, .{ .scene = 1, .scene_2d = 1 }, &scene, &flat, &designer, null);
    try std.testing.expectEqual((scene_view.SceneCamera{}).distance, scene.camera.distance);
    try std.testing.expectEqual(@as(f32, 12), flat.height_m);
    scene.camera.distance = 7;

    // Going back brings the first copy's view back, and keeps the second's.
    views.follow(std.testing.allocator, .{}, &scene, &flat, &designer, null);
    try std.testing.expectEqual(@as(f32, 40), scene.camera.distance);
    try std.testing.expectEqual(@as(f32, 3), flat.height_m);
    views.follow(std.testing.allocator, .{ .scene = 1 }, &scene, &flat, &designer, null);
    try std.testing.expectEqual(@as(f32, 7), scene.camera.distance);
}
