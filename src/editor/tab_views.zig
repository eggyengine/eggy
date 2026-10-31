//! Each workspace tab's own view through the panels it has a copy of (`panels.Live`): the Scene's
//! camera and toolbar, the 2D Scene's centre, zoom and toolbar, and the UI scene the UI
//! Designer has open. The editor has one of each; when another copy goes live, the one in use is
//! put aside for its copy and the new copy's is put in its place. The Scene and 2D views are kept
//! in the project's `.eggy/views.zon`, so they come back after a Reload or when it opens again.
const std = @import("std");
const zon_file = @import("eggy").assets.zon;
const panels = @import("panels.zig");
const scene_view = @import("scene_view/scene_view.zig");
const Scene2d = @import("scene_2d/scene_2d.zig").Scene2d;
const ui_designer = @import("ui_designer/ui_designer.zig");
const log = std.log.scoped(.tabs);

/// Where in the project the views are kept.
const views_path = ".eggy" ++ std.fs.path.sep_str ++ "views.zon";

/// What is kept of a Scene copy's camera: where it looks from and how fast it flies, not the drag
/// or gesture under way.
const SavedCamera = struct {
    focus: [3]f32,
    yaw_deg: f32,
    pitch_deg: f32,
    distance: f32,
    fly_speed_m_per_s: f32,

    fn of(look: scene_view.SceneCamera) SavedCamera {
        return .{ .focus = look.focus.toArray(), .yaw_deg = look.yaw_deg, .pitch_deg = look.pitch_deg, .distance = look.distance, .fly_speed_m_per_s = look.fly_speed_m_per_s };
    }

    fn sceneCamera(self: SavedCamera) scene_view.SceneCamera {
        return .{ .focus = .fromArray(self.focus), .yaw_deg = self.yaw_deg, .pitch_deg = self.pitch_deg, .distance = self.distance, .fly_speed_m_per_s = self.fly_speed_m_per_s };
    }
};

/// The file's shape: each Scene and 2D Scene copy's view, by copy.
const Saved = struct {
    scenes: [panels.max_copies]?struct { camera: SavedCamera, tools: scene_view.toolbar.State } = @splat(null),
    flats: [panels.max_copies]?FlatLook = @splat(null),
};

/// What a Scene copy keeps while another is live.
const SceneLook = struct { camera: scene_view.SceneCamera, tools: scene_view.toolbar.State };

/// What a 2D Scene copy keeps while another is live.
const FlatLook = struct { centre: [2]f32, height_m: f32, tools: scene_view.toolbar.State };

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
            self.flats[self.applied.scene_2d] = .{ .centre = flat.centre.toArray(), .height_m = flat.height_m, .tools = flat.tools };
            const next = self.flats[live.scene_2d] orelse FlatLook{ .centre = .{ 0, 0 }, .height_m = 12, .tools = (Scene2d{}).tools };
            flat.* = .{ .centre = .fromArray(next.centre), .height_m = next.height_m, .tools = next.tools };
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

    /// Write every Scene and 2D Scene copy's view, those in use as `scene` and `flat` show them,
    /// to `project`'s `.eggy/views.zon`. Errors are the file's: the views in memory are unchanged.
    pub fn save(self: *const TabViews, gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, scene: *const scene_view.SceneView, flat: *const Scene2d) !void {
        var saved = Saved{ .flats = self.flats };
        for (&saved.scenes, self.scenes) |*kept, look| if (look) |shown| {
            kept.* = .{ .camera = .of(shown.camera), .tools = shown.tools };
        };
        saved.scenes[self.applied.scene] = .{ .camera = .of(scene.camera), .tools = scene.tools };
        saved.flats[self.applied.scene_2d] = .{ .centre = flat.centre.toArray(), .height_m = flat.height_m, .tools = flat.tools };

        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        try text.writer.writeAll("// Each tab's Scene camera and 2D view, put back when the editor opens.\n");
        try std.zon.stringify.serialize(saved, .{}, &text.writer);
        try project.createDirPath(io, ".eggy");
        try project.writeFile(io, .{ .sub_path = views_path, .data = text.written() });
    }

    /// Read the views `save` kept in `project`, putting the copies in use into `scene` and
    /// `flat`. Call before the first `follow`. A missing or unreadable file leaves every view as
    /// it is; one that can't be read is logged.
    pub fn load(self: *TabViews, gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, scene: *scene_view.SceneView, flat: *Scene2d) void {
        const source = project.readFileAllocOptions(io, views_path, gpa, .limited(64 * 1024), .of(u8), 0) catch return;
        defer gpa.free(source);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const saved = zon_file.parse(Saved, arena.allocator(), source, .{ .ignore_unknown_fields = true }) catch |err| return log.warn("cannot read the tabs' views: {t}", .{err});
        for (&self.scenes, saved.scenes) |*look, kept| look.* = if (kept) |shown| .{ .camera = shown.camera.sceneCamera(), .tools = shown.tools } else null;
        self.flats = saved.flats;
        // The copies in use take theirs now; the rest wait for `follow`.
        if (self.scenes[self.applied.scene]) |look| {
            scene.camera = look.camera;
            scene.tools = look.tools;
        }
        if (self.flats[self.applied.scene_2d]) |look| flat.* = .{ .centre = .fromArray(look.centre), .height_m = look.height_m, .tools = look.tools };
    }
};

test "the views kept in the project come back, each for its own copy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var views = TabViews{};
    var scene = scene_view.SceneView{};
    var flat = Scene2d{};
    var designer = ui_designer.Designer{};
    scene.camera.distance = 40;
    scene.camera.fly_speed_m_per_s = 2;
    views.follow(std.testing.allocator, .{ .scene = 1 }, &scene, &flat, &designer, null);
    scene.camera.distance = 7;
    flat.height_m = 3;
    try views.save(std.testing.allocator, std.testing.io, tmp.dir, &scene, &flat);

    // A new editor starts on copy 0, then shows copy 1.
    var reopened = TabViews{};
    var reopened_scene = scene_view.SceneView{};
    var reopened_flat = Scene2d{};
    reopened.load(std.testing.allocator, std.testing.io, tmp.dir, &reopened_scene, &reopened_flat);
    try std.testing.expectEqual(@as(f32, 40), reopened_scene.camera.distance);
    try std.testing.expectEqual(@as(f32, 2), reopened_scene.camera.fly_speed_m_per_s);
    try std.testing.expectEqual(@as(f32, 3), reopened_flat.height_m);
    reopened.follow(std.testing.allocator, .{ .scene = 1 }, &reopened_scene, &reopened_flat, &designer, null);
    try std.testing.expectEqual(@as(f32, 7), reopened_scene.camera.distance);
}

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
