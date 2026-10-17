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
        /// What packaging put beside the game (null where there is none: the web), and the
        /// entities each scene instance made from it.
        data: ?*packaged_assets.Data,

        const Self = @This();

        // What the executable says about itself (`eggy.zon`'s metadata, from `addGame`), kept in
        // a section of its own.
        comptime {
            if (@hasDecl(project, "metadata_text")) {
                const section: ?[]const u8 = switch (builtin.object_format) {
                    .elf => ".eggy_metadata",
                    .macho => "__DATA,__eggy_meta",
                    else => null,
                };
                if (section) |name| @export(&project.metadata_text, .{ .name = "eggy_metadata", .section = name });
            }
        }

        pub fn init(gpa: std.mem.Allocator, args: []const [*:0]const u8) !Self {
            _ = args;
            // Used, so a release build's linker keeps the metadata's section.
            if (@hasDecl(project, "metadata_text")) std.mem.doNotOptimizeAway(&project.metadata_text);
            var app = try eggy.App.init(gpa, project.name);
            errdefer app.deinit();
            // Model and image files, and scenes, as packaging made them.
            const data: ?*packaged_assets.Data = if (web) null else packaged_assets.Data.open(gpa) catch |err| blk: {
                std.log.warn("the game's data folder can't be read ({t}): it starts with no scene, models or textures", .{err});
                break :blk null;
            };
            errdefer if (data) |packaged| packaged.close();
            if (data) |packaged| {
                app.graphics.models.loader = packaged.models();
                app.graphics.textures.loader = packaged.textures();
                app.resource_provider = packaged.resources();
            }
            app.scene_access = eggy.scene.registryAccess(Plugins.Components);
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
            if (@hasDecl(project, "main_scene")) if (project.main_scene) |path| if (data) |packaged| startScene(gpa, packaged.copies(), &app.world, path);
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
            };
        }

        /// Put the scene at `path` (from `files`) into `world`; a scene that can't be read leaves
        /// it empty, having said why.
        fn startScene(gpa: std.mem.Allocator, files: eggy.scene_instances.Files, world: *eggy.ecs.World, path: []const u8) void {
            const source = files.read(files.context, gpa, path) catch |err| return std.log.err("cannot read the scene {s}: {t}", .{ path, err });
            defer gpa.free(source);
            var scene = eggy.scene.Scene.parse(gpa, source) catch |err| return std.log.err("cannot read the scene {s}: {t}", .{ path, err });
            defer scene.deinit();
            const made = scene.instantiate(gpa, world, eggy.scene.registryAccess(Plugins.Components), null) catch |err| return std.log.err("cannot put the scene {s} in: {t}", .{ path, err });
            gpa.free(made.entities);
            if (made.skipped > 0) std.log.warn("{s}: {d} components or fields left out (see above)", .{ path, made.skipped });
        }

        pub fn deinit(self: *Self) void {
            if (self.notice) |*notice| {
                self.app.graphics.queue.waitIdle() catch {};
                notice.deinit();
            }
            self.plugins.deinit();
            self.app.deinit();
            if (self.data) |packaged| packaged.close();
            self.gpa.free(self.drawables);
        }

        pub fn iterate(self: *Self) !sdl3.AppResult {
            try self.app.graphics.syncSize(self.app.window);
            // The browser already paces frames to the display.
            if (!web) _ = self.fps_capper.delay();
            // Scene instances' entities, from their files, for any made or changed.
            if (self.data) |packaged| self.app.sceneInstances().sync(packaged.copies(), &self.app.world, eggy.scene.registryAccess(Plugins.Components), null);
            self.app.time.tick(sdl3.timer.getNanosecondsSinceInit());
            try self.plugins.update(&self.app);
            try self.app.updateWorld();
            self.app.input.endFrame();
            const frame = try self.app.graphics.beginFrame();
            // Through the game's camera; without one, there is nothing to see it from.
            if (eggy.camera.find(&self.app.world)) |view| {
                const drawn = eggy.mesh.gather(&self.app.world, self.drawables);
                try self.app.graphics.drawScene(frame, self.drawables[0..drawn], view);
            } else if (!self.plugins.hasGameUi() and !self.plugins.hasDraw()) {
                if (self.notice == null) self.notice = try eggy.Notice.init(self.gpa, &self.app.graphics);
                try self.notice.?.draw(frame, "No camera available");
            }
            const logical_width, const logical_height = try self.app.window.window.getSize();
            if (logical_width > 0 and logical_height > 0) {
                const draw = eggy.DrawContext{
                    .cmd = frame.cmd,
                    .target = frame.target,
                    .extent_px = frame.extent,
                    .viewport = .{ .x = 0, .y = 0, .w = @floatFromInt(logical_width), .h = @floatFromInt(logical_height) },
                    .color_format = self.app.graphics.color_format,
                    .frame_owner = &self.app.graphics.surface,
                    .frame_slot = self.app.graphics.surface.slot,
                };
                try self.plugins.draw(&self.app, draw);
                if (self.plugins.hasGameUi()) {
                    const layer = try self.app.gameUi();
                    layer.begin(draw, sdl3.timer.getMillisecondsSinceInit());
                    try self.plugins.gameUi(&self.app, &layer.context);
                    if (try layer.render(draw)) self.app.input.cancel();
                    try layer.syncClipboard();
                    const window = self.app.window.window;
                    if (sdl3.keyboard.textInputActive(window) != layer.context.wants_text) {
                        if (layer.context.wants_text) try sdl3.keyboard.startTextInput(window) else try sdl3.keyboard.stopTextInput(window);
                    }
                }
            }
            try self.app.graphics.endFrame(frame);
            return .run;
        }

        pub fn event(self: *Self, curr_event: sdl3.events.Event) !sdl3.AppResult {
            const lifecycle = try self.app.event(curr_event);
            if (lifecycle != .run) return lifecycle;
            const consumed = if (self.app.ui_layer) |layer| layer.handle(curr_event, false) else false;
            if (eggy.game_ui.isInput(curr_event) and (consumed or try self.plugins.uiEvent(&self.app, curr_event))) {
                self.app.input.suppress(curr_event);
                return .run;
            }
            self.app.input.handle(curr_event);
            try self.plugins.event(&self.app, curr_event);
            return .run;
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
