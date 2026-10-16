//! The `eggy_runtime` module: the game as players run it, with its plugins and nothing else.
const builtin = @import("builtin");
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const packaged_assets = @import("packaged_assets.zig");

const web = builtin.os.tag == .emscripten;
const fps = 340000;

/// The runtime for `project`, which declares `name` (the window title) and `plugins` (a tuple of
/// plugin types, the game first). `addGame` generates it from the game's build.
pub fn Runtime(comptime project: type) type {
    const Plugins = eggy.plugins.Set(project.plugins, &project.plugin_keys);
    return struct {
        gpa: std.mem.Allocator,
        app: eggy.App,
        plugins: Plugins,
        fps_capper: sdl3.extras.FramerateCapper(f32),
        /// The meshes drawn each frame, gathered from the world.
        drawables: []eggy.mesh.Drawable,
        /// "No camera available", made the first time the scene has no camera to look through.
        notice: ?eggy.Notice = null,
        /// Where packaging put the game's resources (null where there is none: the web), and
        /// the entities each scene instance made from them.
        data: ?std.Io.Dir,
        instances: eggy.SceneInstances,

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator, args: []const [*:0]const u8) !Self {
            _ = args;
            var app = try eggy.App.init(gpa, project.name);
            errdefer app.deinit();
            // Model and image files, as packaging made them.
            app.graphics.models.loader = packaged_assets.models;
            app.graphics.textures.loader = packaged_assets.textures;
            // The project's preferences, baked in by `addGame`, before the plugins start.
            if (@hasDecl(project, "preference_files")) for (project.preference_files) |file| {
                app.preference_values.read(.project, file.key, file.zon) catch |err| std.log.warn("the preferences for {s} don't parse ({t}): they are ignored", .{ file.key, err });
            };
            // The plugins the project turned off (`eggy.plugins.registry_file`), also baked in.
            var off_arena = std.heap.ArenaAllocator.init(gpa);
            defer off_arena.deinit();
            const off: []const []const u8 = if (@hasDecl(project, "plugin_registry")) eggy.plugins.parseOff(off_arena.allocator(), project.plugin_registry) catch |err| blk: {
                std.log.warn("{s} doesn't parse ({t}): every plugin runs", .{ eggy.plugins.registry_file, err });
                break :blk &.{};
            } else &.{};
            // The game's first scene, before the plugins start, as the editor puts it in.
            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.io();
            const data: ?std.Io.Dir = if (web) null else packaged_assets.openData(io) catch |err| blk: {
                std.log.warn("the game has no data folder ({t}): it starts with no scene", .{err});
                break :blk null;
            };
            errdefer if (data) |dir| dir.close(io);
            if (@hasDecl(project, "main_scene")) if (project.main_scene) |path| if (data) |dir| startScene(gpa, io, dir, &app.world, path);
            var plugins = try Plugins.init(gpa, &app, Plugins.enabledExcept(off));
            errdefer plugins.deinit();
            try app.startWorld();
            const drawables = try gpa.alloc(eggy.mesh.Drawable, eggy.max_drawables);
            return .{
                .gpa = gpa,
                .drawables = drawables,
                .plugins = plugins,
                .app = app,
                .fps_capper = .{ .mode = .{ .limited = fps } },
                .data = data,
                .instances = .init(gpa),
            };
        }

        /// Put the scene at `path` (in `data`) into `world`; a scene that can't be read leaves
        /// it empty, having said why.
        fn startScene(gpa: std.mem.Allocator, io: std.Io, data: std.Io.Dir, world: *eggy.ecs.World, path: []const u8) void {
            const source = data.readFileAllocOptions(io, path, gpa, .limited(64 << 20), .of(u8), 0) catch |err| return std.log.err("cannot read the scene {s}: {t}", .{ path, err });
            defer gpa.free(source);
            var scene = eggy.scene.Scene.parse(gpa, source) catch |err| return std.log.err("cannot read the scene {s}: {t}", .{ path, err });
            defer scene.deinit();
            const made = scene.instantiate(gpa, world, eggy.scene.registryAccess(Plugins.Components), null) catch |err| return std.log.err("cannot put the scene {s} in: {t}", .{ path, err });
            gpa.free(made.entities);
            if (made.skipped > 0) std.log.warn("{s}: {d} components or fields left out (see above)", .{ path, made.skipped });
        }

        pub fn deinit(self: *Self) void {
            self.instances.deinit();
            if (self.data) |dir| {
                var threaded: std.Io.Threaded = .init_single_threaded;
                dir.close(threaded.io());
            }
            if (self.notice) |*notice| {
                self.app.graphics.queue.waitIdle() catch {};
                notice.deinit();
            }
            self.plugins.deinit();
            self.app.deinit();
            self.gpa.free(self.drawables);
        }

        pub fn iterate(self: *Self) !sdl3.AppResult {
            try self.app.graphics.syncSize(self.app.window);
            // The browser already paces frames to the display.
            if (!web) _ = self.fps_capper.delay();
            // Scene instances' entities, from their files, for any made or changed.
            if (self.data) |dir| {
                var threaded: std.Io.Threaded = .init_single_threaded;
                self.instances.sync(threaded.io(), dir, &self.app.world, eggy.scene.registryAccess(Plugins.Components), null);
            }
            try self.plugins.update(&self.app);
            try self.app.updateWorld();
            const frame = try self.app.graphics.beginFrame();
            // Through the game's camera; without one, there is nothing to see it from.
            if (eggy.camera.find(&self.app.world)) |view| {
                const drawn = eggy.mesh.gather(&self.app.world, self.drawables);
                try self.app.graphics.drawScene(frame, self.drawables[0..drawn], view);
            } else {
                if (self.notice == null) self.notice = try eggy.Notice.init(self.gpa, &self.app.graphics);
                try self.notice.?.draw(frame, "No camera available");
            }
            try self.app.graphics.endFrame(frame);
            return .run;
        }

        pub fn event(self: *Self, curr_event: sdl3.events.Event) !sdl3.AppResult {
            try self.plugins.event(&self.app, curr_event);
            return self.app.event(curr_event);
        }
    };
}

test "the runtime compiles for a project" {
    const project = struct {
        pub const name = "test";
        pub const plugins = .{struct {}};
        pub const plugin_keys = [_][:0]const u8{"game"};
    };
    std.testing.refAllDecls(Runtime(project));
}
