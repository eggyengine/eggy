//! The `eggy_runtime` module: the game as players run it, with its plugins and nothing else.
const builtin = @import("builtin");
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const packaged_assets = @import("packaged_assets.zig");

const web = builtin.os.tag == .emscripten;

/// The runtime for `project`, which declares `name` (the window title) and `plugins` (a tuple of
/// plugin types, the game first). `addGame` generates it from the game's build.
/// `project` also supplies published `plugin_keys` and may include packaged scenes,
/// preferences and metadata. Returns a host state type, not an initialized game.
///
/// ```zig
/// const State = @import("eggy_runtime").Runtime(@import("eggy_project"));
/// const callbacks = eggy.entry.Callbacks(State);
/// pub const init = callbacks.init;
/// ```
pub fn Runtime(comptime project: type) type {
    const Plugins = eggy.plugins.Set(project.plugins, &project.plugin_keys);
    return struct {
        gpa: std.mem.Allocator,
        app: eggy.App,
        plugins: Plugins,
        /// The meshes drawn each frame, gathered from the world.
        /// "No camera available", made the first time the scene has no camera to look through.
        notice: ?eggy.Notice = null,
        /// What packaging put beside or inside the game (null when data cannot be read), and the
        /// entities each scene instance made from it.
        data: ?*packaged_assets.Data,
        /// How many invalid lights were last reported (`eggy.lighting.reportInvalid`).
        invalid_lights_reported: u32 = 0,

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

        /// Host startup: open the App, install packaged providers/preferences, start enabled
        /// plugins and world schedules. `args` gives the log its `--log-level`.
        /// `process_init` must outlive the result; pair success with `deinit` on the main thread.
        /// Core setup failures propagate; unavailable packaged data/scenes are logged and skipped.
        ///
        /// ```zig
        /// // A custom host; normally entry.Callbacks calls this for SDL.
        /// var runtime = try State.init(process, args);
        /// defer runtime.deinit();
        /// ```
        pub fn init(process_init: *const std.process.Init, args: []const [*:0]const u8) !Self {
            eggy.log.start(process_init.io, .game, project.name, args);
            const gpa = process_init.gpa;
            // Used, so a release build's linker keeps the metadata's section.
            if (@hasDecl(project, "metadata_text")) std.mem.doNotOptimizeAway(&project.metadata_text);
            const graphics_defaults = if (@hasDecl(project, "graphics_zon"))
                try eggy.render_settings.parse(gpa, project.graphics_zon)
            else
                eggy.render_settings.Settings{};
            var app = try eggy.App.initForProject(process_init, project.name, project.name, .runtime, graphics_defaults);
            errdefer app.deinit();
            app.storage = try eggy.storage.Storage.init(gpa, process_init.io, project.name);
            if (@hasDecl(project, "input_bindings")) try app.input_backend.?.state.readOverrides(project.input_bindings);
            // Model and image files, and scenes, as packaging made them.
            const data: ?*packaged_assets.Data = packaged_assets.Data.open(gpa, process_init.io) catch |err| blk: {
                std.log.warn("the game's data folder can't be read ({t}): it starts with no scene, models or textures", .{err});
                break :blk null;
            };
            errdefer if (data) |packaged| {
                if (app.resource_jobs) |jobs| jobs.clear();
                packaged.close();
            };
            if (data) |packaged| {
                app.graphics.models.loader = packaged.models();
                app.graphics.textures.loader = packaged.textures();
                app.resource_provider = packaged.resources();
            }
            app.scene_access = eggy.scene.registryAccess(Plugins.Components);
            app.graphics.materials.resources = app.resources();
            app.graphics.clips.resources = app.resources();
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
            errdefer {
                if (app.resource_jobs) |jobs| jobs.clear();
                plugins.deinit();
            }
            try app.startWorld();
            return .{
                .gpa = gpa,
                .plugins = plugins,
                .app = app,
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

        /// Host shutdown: cancel resource jobs, release notice rendering, plugins, App and
        /// packaged providers, in that order. Call exactly once on a fully initialized state, on the main
        /// thread; invalidates all pointers borrowed from it. World teardown failures are logged.
        ///
        /// ```zig
        /// var runtime = try State.init(process, args);
        /// defer runtime.deinit();
        /// ```
        pub fn deinit(self: *Self) void {
            // Jobs may borrow allocators owned by plugins about to be destroyed.
            if (self.app.resource_jobs) |jobs| jobs.clear();
            if (self.notice) |*notice| {
                self.app.graphics.queue.waitIdle() catch {};
                notice.deinit();
            }
            self.plugins.deinit();
            self.app.deinit();
            if (self.data) |packaged| packaged.close();
        }

        /// Run one host frame: synchronize scenes, tick time/input, update plugins/world and
        /// draw/present the camera and optional game UI. Returns `.run` after a complete frame.
        /// GPU, input, system and hook failures propagate to the executable's fatal boundary.
        /// Call only while the initialized state and graphics device are alive.
        ///
        /// ```zig
        /// // SDL normally drives this; a custom host must also dispatch events.
        /// const result = try runtime.iterate();
        /// if (result != .run) return result;
        /// ```
        pub fn iterate(self: *Self) !sdl3.AppResult {
            if (builtin.abi.isAndroid() and !self.app.graphics.surface_active) return .run;
            // Graphics choices queued since last frame take effect before anything is drawn.
            try self.app.applyGraphicsSettings();
            self.app.beginDiagnosticsFrame();
            try self.app.graphics.syncSize(self.app.window);
            // Scene instances' entities, from their files, for any made or changed.
            if (self.data) |packaged| self.app.sceneInstances().sync(packaged.copies(), &self.app.world, eggy.scene.registryAccess(Plugins.Components), null);
            self.app.time.tick(sdl3.timer.getNanosecondsSinceInit());
            try self.app.advanceInput();
            try self.plugins.update(&self.app);
            try self.app.updateWorld();
            self.app.input.endFrame();
            self.app.graphics.lights = try eggy.lighting.gather(&self.app.world);
            eggy.lighting.reportInvalid(self.app.graphics.lights, &self.invalid_lights_reported);
            const frame = try self.app.graphics.beginFrame();
            // Through the game's camera; without one, there is nothing to see it from.
            if (eggy.camera.find(&self.app.world)) |view| {
                const drawn = try eggy.mesh.gatherAlloc(self.gpa, &self.app.world);
                defer self.gpa.free(drawn);
                try self.app.graphics.drawScene(frame, drawn, view);
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
                if (self.plugins.hasGameUi() or self.app.graphics_settings_ui.isOpen()) {
                    const layer = try self.app.gameUi();
                    layer.begin(draw, sdl3.timer.getMillisecondsSinceInit());
                    if (self.plugins.hasGameUi()) try self.plugins.gameUi(&self.app, &layer.context);
                    self.app.graphics_settings_ui.draw(&self.app, &layer.context);
                    if (try layer.render(draw)) self.app.input.cancel();
                    try layer.syncClipboard();
                    const window = self.app.window.window;
                    if (sdl3.keyboard.textInputActive(window) != layer.context.wants_text) {
                        if (layer.context.wants_text) try sdl3.keyboard.startTextInput(window) else try sdl3.keyboard.stopTextInput(window);
                    }
                }
                if (eggy.camera.find(&self.app.world)) |view| try self.app.drawDebug(draw, view);
            }
            try self.app.graphics.endFrame(frame);
            try self.app.finishDiagnosticsFrame();
            return .run;
        }

        /// Route a borrowed SDL event through device/window bookkeeping, UI capture, input and
        /// plugin hooks on the main thread. Quit/main-window-close returns `.success`;
        /// consumed input does not reach gameplay. Backend/hook/resize errors propagate.
        ///
        /// ```zig
        /// const result = try runtime.event(current);
        /// if (result != .run) return result; // Honor the host lifecycle decision.
        /// ```
        pub fn event(self: *Self, curr_event: sdl3.events.Event) !sdl3.AppResult {
            if (builtin.abi.isAndroid()) switch (curr_event) {
                .will_enter_background => {
                    self.app.input.cancel();
                    try self.app.graphics.suspendSurface();
                },
                .did_enter_foreground => try self.app.graphics.resumeSurface(self.app.window),
                else => {},
            };
            try self.app.deviceEvent(curr_event);
            const lifecycle = try self.app.event(curr_event);
            if (lifecycle != .run) return lifecycle;
            if (eggy.game_ui.syntheticTouchMouse(curr_event)) return .run;
            if (self.app.graphics_settings_ui.event(&self.app, curr_event)) return .run;
            const width, const height = try self.app.window.window.getSize();
            self.app.input.viewport_points = .{ @floatFromInt(width), @floatFromInt(height) };
            if (eggy.game_ui.isTouchInput(curr_event) and (width == 0 or height == 0)) return .run;
            const consumed = if (self.app.ui_layer) |layer| layer.handle(curr_event, false) else false;
            if (eggy.game_ui.isInput(curr_event) and (consumed or try self.plugins.uiEvent(&self.app, curr_event))) {
                self.app.input.suppress(curr_event);
                return .run;
            }
            try self.app.input.handle(curr_event);
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
