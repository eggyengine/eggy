//! The window, renderer and ECS world every Eggy program opens.
const builtin = @import("builtin");
const std = @import("std");
const sdl_adapter = @import("vitellus_sdl3");
const sdl3 = sdl_adapter.sdl;
const Graphics = @import("graphics.zig").Graphics;
const clutch = @import("clutch");
const preferences_zig = @import("preferences.zig");
const Input = @import("input/input.zig").Input;
const InputBackend = @import("input/backend.zig").Backend;
const Time = @import("time.zig").Time;
const Resources = @import("resources/resources.zig").Resources;
const Scenes = @import("scenes/scenes.zig").Scenes;
const SceneInstances = @import("scene_instances.zig").SceneInstances;
const scene = @import("scene.zig");
const Overlay = @import("game_ui/game_ui.zig").Overlay;
const render = @import("render_settings.zig");
const graphics_control = @import("graphics_control.zig");
const GraphicsSettingsUi = @import("game_ui/graphics_settings.zig").GraphicsSettingsUi;
const ui_scenes = @import("ui_scenes/ui_scenes.zig");

const web = builtin.os.tag == .emscripten;
const android = builtin.abi.isAndroid();
const mobile_zig = @import("mobile/mobile.zig");
const width = 900;
const height = 675;

/// Owns SDL, one window, the `Graphics` that draws into it, and the game's ECS `world`.
pub const App = struct {
    window: sdl_adapter.Sdl3Window,
    /// What Zig hands `main` (`std.process.Init`): the command line, the environment
    /// (`environ_map`), the process arena, allocator and `Io`. Valid for the whole run.
    process_init: *const std.process.Init,
    init_flags: sdl3.InitFlags,
    graphics: Graphics,
    /// Entities, components, resources and schedules. Plugins register schedules in `init`;
    /// `startWorld`, `updateWorld` and `deinit` run clutch's stages.
    world: clutch.World,
    /// Plugins' preference values (see `preferences`): the editor fills it from the user's and
    /// the project's files, the runtime from the project's, baked in.
    preference_values: preferences_zig.Store,
    /// The keyboard and mouse as they are this frame (see `eggy.Input`).
    input: Input = .{},
    input_backend: ?*InputBackend = null,
    /// How long the last frame took, and how long the game has run (see `eggy.Time`).
    time: Time = .{},
    /// Installed by the executable before plugin initialization.
    resource_provider: Resources = .{},
    resource_jobs: ?*@import("resources/async.zig").Queue = null,
    /// Typed registry installed by the game library, never the editor host.
    scene_access: ?scene.Access = null,
    instances: ?SceneInstances = null,
    scene_transition: @import("scenes/scenes.zig").Transition = .{},
    ui_layer: ?*Overlay = null,
    /// The player's graphics menu: F10 opens it, or `graphics_settings_ui.open()` (see `GraphicsSettingsUi`).
    graphics_settings_ui: GraphicsSettingsUi = .{},
    audio: @import("audio.zig").Audio = .{},
    draw2d: @import("draw2d.zig").Draw2d = .{},
    /// UI scenes' caches, what code changed about them and their presses (see `uiScenes`).
    ui_scenes: ui_scenes.State = .{},
    particles: @import("particles.zig").Particles = .{},
    network: @import("network.zig").Network = .{},
    navigation: @import("navigation.zig").Navigation = .{},
    storage: @import("storage.zig").Storage = .{},
    localization: @import("localization.zig").Localization = .{},
    debug_draw: @import("debug_draw.zig").DebugDraw = .{},
    profiling: @import("profiling.zig").Profiling = .{},
    graphics_options: graphics_control.State = .{},
    /// The motion sensors and vibrator `mobile()` has opened.
    mobile_state: mobile_zig.State = .{},

    /// Host entry point: open SDL video/gamepads, a 900x675 logical-point window, GPU and world.
    /// `process_init` must outlive the returned owner; `title` is null-terminated UTF-8.
    /// Call on the main thread and pair with `deinit`. SDL, GPU and allocation errors unwind
    /// partially created resources. Games normally receive an App rather than constructing one.
    ///
    /// ```zig
    /// // In an executable host with its process context:
    /// var app = try eggy.App.init(process, "Preview");
    /// defer app.deinit();
    /// ```
    pub fn init(process_init: *const std.process.Init, title: [:0]const u8) !App {
        return initConfigured(process_init, title, null);
    }

    /// Load persistent graphics choices before creating this project's window and device.
    pub fn initForProject(process_init: *const std.process.Init, title: [:0]const u8, project_name: []const u8, scope: render.Scope, defaults: render.Settings) !App {
        return initConfigured(process_init, title, .{ .project_name = project_name, .scope = scope, .defaults = defaults });
    }

    const GraphicsConfig = struct { project_name: []const u8, scope: render.Scope, defaults: render.Settings };

    fn initConfigured(process_init: *const std.process.Init, title: [:0]const u8, config: ?GraphicsConfig) !App {
        const gpa = process_init.gpa;
        // Phones and tablets also get their motion sensors and vibrator (see `mobile`).
        const init_flags = sdl3.InitFlags{ .video = true, .gamepad = true, .sensor = mobile_zig.is_mobile, .haptic = mobile_zig.is_mobile };
        try sdl3.init(init_flags);
        errdefer sdl3.quit(init_flags);
        var options = if (config) |value|
            try graphics_control.State.init(gpa, process_init.io, value.project_name, value.scope, value.defaults)
        else
            graphics_control.State{};
        errdefer options.deinit();

        // Android games start in landscape (either way round, as the user's rotation lock allows)
        // and fill the screen, the status and navigation bars hidden until swiped in.
        // ponytail: landscape only; add a project setting when a game wants portrait.
        if (android) try sdl3.hints.set(.orientations, "LandscapeLeft LandscapeRight");

        // On Windows the window stays hidden until the renderer is ready.
        var window: sdl_adapter.Sdl3Window = .init(try sdl3.video.Window.init(title, options.requested.width, options.requested.height, .{
            .vulkan = !web,
            .resizable = true,
            .high_pixel_density = true,
            .hidden = builtin.os.tag == .windows,
            .fullscreen = android or options.requested.window_mode == .borderless,
        }));
        errdefer window.deinit();
        const input_backend = try InputBackend.init(gpa);
        errdefer input_backend.deinit();
        const has_override = if (options.store) |store| store.has_override else false;
        var graphics = (if (has_override) Graphics.initWithSettings(gpa, window, options.requested) else Graphics.initWithDefaults(gpa, window, options.requested)) catch |err| blk: {
            if (options.store == null or !options.store.?.has_override) return err;
            options.recover(err);
            try window.window.setFullscreen(android or options.requested.window_mode == .borderless);
            if (!android and options.requested.window_mode == .windowed) try window.window.setSize(options.requested.width, options.requested.height);
            break :blk try Graphics.initWithDefaults(gpa, window, options.requested);
        };
        errdefer graphics.deinit();
        const resource_jobs = try @import("resources/async.zig").Queue.create(gpa);
        errdefer resource_jobs.destroy();
        options.defaults = options.defaults.supportedDefaults(graphics.capabilities());
        options.requested = graphics.render_settings;
        if (builtin.os.tag == .windows) try window.window.show();

        return .{ .window = window, .process_init = process_init, .init_flags = init_flags, .graphics = graphics, .graphics_options = options, .world = .init(gpa), .preference_values = .init(gpa), .input_backend = input_backend, .input = .{ .backend = input_backend.state.interface() }, .resource_jobs = resource_jobs, .draw2d = .{ .gpa = gpa } };
    }

    /// Queue validated live choices; restart-only selections remain pending until next launch.
    pub fn setGraphicsSettings(self: *App, settings: render.Settings) !render.ApplyResult {
        return self.graphics_options.request(settings, &self.graphics, false);
    }

    /// Host-only: atomically persist and queue user choices, outside game-library callbacks.
    pub fn saveGraphicsSettings(self: *App, settings: render.Settings) !render.ApplyResult {
        return self.graphics_options.request(settings, &self.graphics, true);
    }

    /// Update shipped defaults without overwriting an existing personal override.
    pub fn setGraphicsDefaults(self: *App, settings: render.Settings) !render.ApplyResult {
        return self.graphics_options.setDefaults(settings, &self.graphics);
    }

    /// Host-only safe point, before recording any window's commands for this frame.
    pub fn applyGraphicsSettings(self: *App) !void {
        try self.graphics_options.apply(&self.graphics, self.window);
    }

    /// Run the world's PreDeinit, Deinit and PostDeinit stages, then free everything.
    /// Host-only, on the main thread, exactly once. Keep plugin code loaded until this returns;
    /// world shutdown failures are logged. Invalidates borrowed services and shuts SDL down.
    ///
    /// ```zig
    /// var app = try eggy.App.init(process, "Preview");
    /// defer app.deinit(); // Runs before unloading the plugins' code.
    /// ```
    pub fn deinit(self: *App) void {
        self.stopWorld();
        if (self.resource_jobs) |jobs| jobs.destroy();
        self.clearGameUi();
        self.debug_draw.deinit(self.world.allocator);
        self.draw2d.deinit();
        self.graphics.ui_billboards = null;
        self.ui_scenes.deinit();
        self.scene_transition.deinit();
        if (self.instances) |*instances| instances.deinit();
        self.world.deinit();
        self.storage.deinit();
        if (self.input_backend) |backend| backend.deinit();
        self.preference_values.deinit();
        self.graphics.deinit();
        self.graphics_options.deinit();
        self.mobile_state.deinit();
        self.window.deinit();
        sdl3.quit(self.init_flags);
        sdl3.shutdown();
    }

    /// The values of `T`, a plugin's `Preferences` struct (see `eggy.preferences`): its defaults,
    /// overridden by what the user and the project set. Cheap enough to call every frame, which
    /// follows changes made in the Preferences window as they happen.
    /// The manifest must contain supported scalar fields with defaults. The returned value
    /// is an independent copy and does not require freeing.
    ///
    /// ```zig
    /// const Settings = struct { mouse_sensitivity: f32 = 0.2 };
    /// const sensitivity = app.preferences(Settings).mouse_sensitivity;
    /// transform.rotation_deg[1] += app.input.mouse_delta[0] * sensitivity;
    /// ```
    pub fn preferences(self: *const App, comptime T: type) T {
        return self.preference_values.get(T);
    }

    /// Borrow this executable's resource providers. Loaded CPU data belongs to the caller.
    /// The view does not allocate and must not outlive its host or survive library replacement.
    ///
    /// ```zig
    /// const notes = eggy.AssetRef(.text).init("resources/notes.txt");
    /// const bytes = try app.resources().read(gpa, notes);
    /// defer gpa.free(bytes);
    /// ```
    pub fn resources(self: *const App) Resources {
        if (self.resource_jobs) |jobs| return jobs.attach(self.resource_provider);
        return self.resource_provider;
    }

    /// Borrow material access for the current world; do not retain across reset/reload.
    pub fn materials(self: *App) @import("materials.zig").Materials {
        return .{ .world = &self.world };
    }

    /// Borrow scene-light access for the current world; do not retain across reset/reload.
    pub fn lighting(self: *App) @import("lighting.zig").Lighting {
        return .{ .world = &self.world };
    }

    /// Borrow animation controls for the current world; do not retain across reset/reload.
    pub fn animation(self: *App) @import("animation.zig").Animation {
        return .{ .world = &self.world };
    }

    /// Borrow UI scene controls: change what entities' `UiScreen`s and `UiBillboard`s show, and
    /// ask which of their buttons were pressed. Do not retain across reset/reload.
    ///
    /// ```zig
    /// try app.uiScenes().setText(hud, "score", "Score: 3");
    /// if (app.uiScenes().clicked(hud, "quit")) quitting = true;
    /// ```
    pub fn uiScenes(self: *App) ui_scenes.UiScenes {
        return .{ .state = &self.ui_scenes };
    }

    /// Borrow the device's phone and tablet features: the safe area, orientation, vibration,
    /// motion, battery and more (see `eggy.mobile`). Main thread only; don't keep it past the App.
    ///
    /// ```zig
    /// const safe = try app.mobile().safeArea();
    /// app.mobile().vibrate(0.5, 30) catch {};
    /// ```
    pub fn mobile(self: *App) mobile_zig.Mobile {
        return .{ .window = self.window.window, .state = &self.mobile_state };
    }

    /// Borrow active-camera controls; selection changes apply to the next scene draw.
    pub fn cameras(self: *App) @import("camera.zig").Cameras {
        return .{ .world = &self.world };
    }

    /// Borrow the current world's scene service; do not retain across reset/reload.
    /// Lazily creates the instance registry; the App owns it and any instantiated entities.
    ///
    /// ```zig
    /// const root = try app.scenes().instantiate(
    ///     .init("resources/scene/room.scene.zon"),
    ///     .{},
    /// );
    /// _ = root; // An entity owned by app.world, not caller-allocated scene data.
    /// ```
    pub fn scenes(self: *App) Scenes {
        return .{ .world = &self.world, .instances = self.sceneInstances(), .resources = self.resources(), .access = self.scene_access, .transition = &self.scene_transition };
    }

    /// The instance registry shared by author calls and the executable's scene-sync point.
    /// Lazily initializes App-owned state without reading scene files. The pointer becomes
    /// invalid on `resetWorld` or `deinit`; games should prefer `scenes().instantiate`.
    ///
    /// ```zig
    /// // Host sync point, with the current file provider and typed component access:
    /// app.sceneInstances().sync(files, &app.world, access, null);
    /// ```
    pub fn sceneInstances(self: *App) *SceneInstances {
        if (self.instances == null) self.instances = .init(self.world.allocator);
        return &self.instances.?;
    }

    /// Lazily create the default game UI. Customize its context theme/widgets, or use
    /// `setFont` to copy a font. Custom-renderer-only games need never create this service.
    /// Returns a borrowed App-owned overlay, invalidated by world reset/shutdown. GPU setup
    /// and allocation can fail; call on the main thread with the graphics device alive.
    ///
    /// ```zig
    /// const overlay = try app.gameUi();
    /// try overlay.setFont(font_bytes);
    /// ```
    pub fn gameUi(self: *App) !*Overlay {
        if (self.ui_layer) |layer| return layer;
        const layer = try self.world.allocator.create(Overlay);
        errdefer self.world.allocator.destroy(layer);
        layer.* = try Overlay.init(self.world.allocator, self.graphics.device, self.graphics.queue, self.graphics.color_format);
        self.ui_layer = layer;
        return layer;
    }

    fn clearGameUi(self: *App) void {
        if (self.ui_layer) |layer| {
            self.ui_scenes.fontGone();
            layer.deinit();
            self.world.allocator.destroy(layer);
            self.ui_layer = null;
        }
    }

    /// Start over with an empty world: run the old one's PreDeinit, Deinit and PostDeinit
    /// stages and free it. The editor does this before swapping in a rebuilt game, while the old
    /// game's code, which the world's schedules and storages point into, is still loaded. Run
    /// `startWorld` once the new game's plugins have registered their schedules.
    /// Host-only. Invalidates entity/component pointers, timers, scene services and default UI;
    /// preserves the window, graphics and preferences. Teardown failures are logged.
    ///
    /// ```zig
    /// // Host reload: old instances are stopped, but their library is still loaded for teardown.
    /// app.resetWorld();
    /// var replacement = try Plugins.init(gpa, app, Plugins.enabledExcept(&.{}));
    /// defer replacement.deinit();
    /// try app.startWorld();
    /// ```
    pub fn resetWorld(self: *App) void {
        self.stopWorld();
        if (self.resource_jobs) |jobs| jobs.clear();
        self.clearGameUi();
        self.debug_draw.deinit(self.world.allocator);
        self.draw2d.deinit();
        self.draw2d = .{ .gpa = self.world.allocator };
        self.graphics.world_draw = null;
        self.graphics.ui_billboards = null;
        self.ui_scenes.clearEntities();
        self.profiling = .{};
        self.graphics.lights = .{};
        self.scene_transition.deinit();
        if (self.instances) |*instances| instances.deinit();
        self.instances = null;
        self.scene_access = null;
        const allocator = self.world.allocator;
        self.world.deinit();
        self.world = .init(allocator);
        self.time.invalidateTimers();
        self.input.cancel();
        if (self.input_backend) |backend| backend.state.resetRun();
    }

    fn stopWorld(self: *App) void {
        inline for (.{ .PreDeinit, .Deinit, .PostDeinit }) |stage| {
            self.world.runStage(stage) catch |err| std.log.err("{s} schedule failed: {t}", .{ @tagName(stage), err });
        }
    }

    /// Run the world's PreInit, Init and PostInit stages. Call once, after plugins' `init`, so
    /// the schedules they registered run.
    /// Host-only; the first failing stage propagates its error and later stages do not run.
    ///
    /// ```zig
    /// // After the host has initialized all enabled plugins:
    /// try app.startWorld();
    /// ```
    pub fn startWorld(self: *App) !void {
        inline for (.{ .PreInit, .Init, .PostInit }) |stage| try self.world.runStage(stage);
    }

    /// Run the world's PreUpdate, Update and PostUpdate stages, then end the tick: `Added`,
    /// `Changed` and `Removed` filters and this frame's events reset. Systems see this frame's
    /// `input` and `time` as the resources `eggy.Input` and `eggy.Time`.
    /// Host-only, once per gameplay frame after plugin update. Resource insertion or a stage
    /// can fail; a failed stage prevents later stages and the final tick.
    ///
    /// ```zig
    /// try plugins.update(app);
    /// try app.updateWorld();
    /// app.input.endFrame();
    /// ```
    pub fn updateWorld(self: *App) !void {
        const sample = try self.profiling.begin("ECS update");
        errdefer self.profiling.end(sample) catch |err| std.log.err("cannot finish ECS timing: {t}", .{err});
        try self.world.insertResource(self.input);
        try self.world.insertResource(self.time);
        try ui_scenes.publish(&self.world, &self.ui_scenes);
        inline for (.{ .PreUpdate, .Update, .PostUpdate }) |stage| try self.world.runStage(stage);
        // Clips play after the game's systems, by the game's (scaled, pause-held) time.
        @import("animation.zig").step(&self.world, &self.graphics.clips, self.time.delta_s);
        self.world.tick();
        if (self.scene_transition.pending != null) if (self.scene_access) |access| {
            if (try self.scene_transition.apply(&self.world, access, self.sceneInstances())) self.input.cancel();
        };
        try self.profiling.end(sample);
    }

    /// Start frame-local diagnostics before any game/editor hooks run.
    pub fn beginDiagnosticsFrame(self: *App) void {
        self.debug_draw.clear();
        self.draw2d.clear();
        self.graphics.world_draw = &self.draw2d;
        self.profiling.beginFrame(sdl3.timer.getNanosecondsSinceInit());
        self.graphics.stats = .{};
    }

    /// Publish host counters and finish CPU frame timing after rendering/presentation.
    pub fn finishDiagnosticsFrame(self: *App) !void {
        var entities: usize = 0;
        for (self.world.slots.items) |slot| if (slot.alive) {
            entities += 1;
        };
        try self.profiling.counter("Entities", @floatFromInt(entities));
        try self.profiling.counter("Scene draw calls", @floatFromInt(self.graphics.stats.draw_calls));
        try self.profiling.counter("Meshes across views", @floatFromInt(self.graphics.stats.meshes));
        try self.profiling.counter("Culled meshes across views", @floatFromInt(self.graphics.stats.culled));
        try self.profiling.counter("Triangles across views", @floatFromInt(self.graphics.stats.triangles));
        try self.profiling.counter("Cached textures", @floatFromInt(self.graphics.textures.entries.count()));
        try self.profiling.counter("Scene lights", @floatFromInt(self.graphics.lights.count));
        try self.profiling.finishFrame(sdl3.timer.getNanosecondsSinceInit());
    }

    /// Render copied debug requests through a camera, without input capture or depth testing.
    pub fn drawDebug(self: *App, draw: @import("game_ui/game_ui.zig").DrawContext, view: @import("camera.zig").View) !void {
        try self.debug_draw.render(self.world.allocator, self.graphics.device, self.graphics.queue, draw, view);
    }

    /// Host device bookkeeping before UI/gameplay routing; opens/closes controllers as needed.
    /// Call once per SDL event on the main thread; backend/SDL errors propagate. Game code may
    /// use shared SDL directly, but must not duplicate the host's device-event bookkeeping.
    ///
    /// ```zig
    /// // At the start of the executable's event callback:
    /// try app.deviceEvent(current);
    /// const result = try app.event(current);
    /// if (result != .run) return result;
    /// ```
    pub fn deviceEvent(self: *App, value: sdl3.events.Event) !void {
        if (self.input_backend) |backend| try backend.event(value);
    }
    /// Advance input triggers once before game hooks/systems, independent of gameplay scaling.
    /// Host-only; uses `time.unscaled_delta_s` and propagates backend evaluation errors.
    /// Calling twice would advance hold/tap durations twice.
    ///
    /// ```zig
    /// app.time.tick(now_ns);
    /// try app.advanceInput();
    /// try plugins.update(app);
    /// ```
    pub fn advanceInput(self: *App) !void {
        if (self.input_backend) |backend| try backend.state.advance(self.time.unscaled_delta_s);
    }

    /// Window lifecycle every program shares: quit requests and closing the main window end the
    /// app (`.success`), and size or scale changes resize the main window's swapchain. Closing
    /// another window (an editor pop-out) is left to whoever opened it.
    /// Host-only, on the main thread. Returns `.run` for unhandled events; SDL window lookup
    /// and swapchain resize errors propagate. Does not feed gameplay input or plugin hooks.
    ///
    /// ```zig
    /// const result = try app.event(current);
    /// if (result != .run) return result;
    /// // Only feed gameplay after any host UI routing has declined the event:
    /// try app.input.handle(current);
    /// ```
    pub fn event(self: *App, curr_event: sdl3.events.Event) !sdl3.AppResult {
        switch (curr_event) {
            .quit, .terminating => return .success,
            .window_close_requested => |window| if (window.id == try self.window.window.getId()) return .success,
            .window_resized, .window_pixel_size_changed, .window_display_scale_changed => try self.graphics.syncSize(self.window),
            else => {},
        }
        return .run;
    }
};
