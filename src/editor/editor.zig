//! The `eggy_editor` module: a game's scene with Weeoui tooling drawn over it. Desktop only.
const builtin = @import("builtin");
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const weeoui_vitellus = @import("weeoui_vitellus");
const workspace_zig = @import("workspace.zig");
const Workspace = workspace_zig.Workspace;
const Slot = workspace_zig.Slot;
const main_slot = workspace_zig.main_slot;
const slot_count = 1 + ui.dock.max_windows;
const PopOut = @import("popout.zig").PopOut;
const icon = @import("icon.zig");
const job_zig = @import("projects/job.zig");
const Job = job_zig.Job;
const Upgrades = @import("projects/upgrades.zig").Upgrades;
const file_manager = @import("file_manager.zig");
const BuildWindow = @import("build_window.zig").BuildWindow;
const ExportWindow = @import("export/export.zig").ExportWindow;
const plugin_manager = @import("plugin_manager/plugin_manager.zig");
const project_settings_zig = @import("project_settings.zig");
const ProjectSettings = project_settings_zig.ProjectSettings;
const DevtoolsWindow = @import("devtools_window.zig").DevtoolsWindow;
const AboutWindow = @import("about_window.zig").AboutWindow;
const window_placement = @import("window_placement.zig");
const source_stamp = @import("projects/source_stamp.zig");
const Console = @import("console.zig").Console;
const panels = @import("panels.zig");

/// `std.Options.logFn` for editor executables: keeps every message for the Console panel.
/// Alias of `console_log.zig`'s `logFn`; see its canonical docs for threading, formatting,
/// allocation failure behavior, and a usage example.
pub const logFn = @import("console_log.zig").logFn;
pub const cli = @import("cli/cli.zig");
const ProjectFlow = @import("projects/flow.zig").ProjectFlow;
const HotGame = @import("hot_reload/hot_reload.zig").HotGame;
const preferences = @import("preferences/preferences.zig");
const entities = @import("entities/entities.zig");
const extraction = @import("entities/extraction.zig");
const scene_file = @import("scene_file.zig");
const layout_file = @import("layout_file.zig");
const PlayMode = @import("play_mode.zig").PlayMode;
const history_zig = @import("history.zig");
const PluginSwitches = @import("plugin_switches.zig").PluginSwitches;
const plugin_bars = @import("plugin_bars.zig");
const Dragged = @import("dragged.zig").Dragged;
const save_prompt_zig = @import("save_prompt.zig");
const page_style = @import("page_style.zig");
const file_ops = @import("assets/file_ops.zig");
const code_editor = @import("code_editor.zig");
const hit_test = eggy.ui_hit_test;
const scene_view = @import("scene_view/scene_view.zig");
const assets = @import("assets/assets.zig");
const AssetIcons = @import("assets/icons.zig").Icons;
const project_assets_zig = @import("assets/project_assets.zig");
const legacy_refs = @import("assets/legacy_refs.zig");
const clipboard = @import("clipboard.zig");
const ProjectAssets = project_assets_zig.ProjectAssets;
const Reference = project_assets_zig.Reference;
const extensions = @import("extensions/extensions.zig");
const GameInput = @import("game_input.zig").State;
const ViewportMouse = @import("viewport_mouse.zig").State;
const InputSettings = @import("input_settings.zig").InputSettings;
const input_map_asset = @import("input_map_asset/input_map_asset.zig");
const animation_dock = @import("animation_dock/animation_dock.zig");
const ui_designer = @import("ui_designer/ui_designer.zig");
const AssetPreview = @import("asset_preview.zig").AssetPreview;
const Scene2d = @import("scene_2d.zig").Scene2d;
/// The Preferences section File > Project Settings opens.
const project_section = "Project";

/// The editor for `project`, which declares `name` and `game_library` (the game library's
/// `file_name`, beside the editor). The game and its plugins run as they do in the runtime,
/// inside a window of dockable panels, from a library the editor swaps for a rebuilt one when
/// their code changes; each can add to the Inspector through `editorUi`.
/// Returns a desktop host type, not a game/plugin interface. `project.name` is a comptime
/// string and `project.game_library.file_name` names the generated shared library. Build
/// configuration supplies this module; games normally use `addGame`, not construct it.
/// The host owns its App, dock windows, scenes, UI, jobs, and loaded library. Keep initialized
/// state at a stable address while callbacks/dialogs use it and pair `init` with `deinit`.
///
/// ```zig
/// // Editor executable internals; project is the generated eggy_project module.
/// const Host = Editor(@import("eggy_project"));
/// var host = try Host.init(process_init, args);
/// defer host.deinit();
/// // SDL delivers host.event(...) between calls to host.iterate().
/// _ = try host.iterate();
/// ```
pub fn Editor(comptime project: type) type {
    return struct {
        gpa: std.mem.Allocator,
        app: eggy.App,
        extension_state: extensions.State = .{},
        game_input: GameInput = .{},
        viewport_mouse: ViewportMouse = .{},
        input_settings: ?*InputSettings = null,
        input_map_window: ?*input_map_asset.Window = null,
        /// The game and its plugins, from their library; null if it couldn't load (logged).
        game: ?HotGame,
        /// When the game's library was built, to tell whether a rebuild changed it.
        game_modified: ?std.Io.Timestamp = null,
        /// When the world was last compared with the saved scene, for the status bar's `*`.
        unsaved_checked_ms: u64 = 0,
        /// The dock's layout as last saved (`layout_file.fingerprint`), when it was last looked
        /// at, and since when it has differed from that.
        layout_saved: u64 = 0,
        /// The dock's layout as last recorded for undo (a snapshot, owned), and its arrangement.
        layout_step: ?[]u8 = null,
        layout_step_arrangement: u64 = 0,
        /// "Save changes?", while it asks; where the editor was going when it opened; and
        /// whether the answer let the next attempt through.
        save_prompt: ?*save_prompt_zig.SavePrompt = null,
        leaving: Leaving = .quit,
        leave_approved: bool = false,
        /// The Play mode warning's text (see `playWarning`).
        play_warning_buffer: [192]u8 = undefined,
        /// When the open scene last saved itself (see `autosave`).
        autosaved_ms: u64 = 0,
        layout_checked_ms: u64 = 0,
        layout_changed_ms: ?u64 = null,
        /// Undo and redo.
        history: history_zig.History,
        /// The project's plugins turned off, which the game starts without.
        plugin_switches: PluginSwitches,
        /// Whether the game is playing, and the scene to go back to when it stops.
        play_mode: PlayMode = .{},
        /// The scene open in the project, if any (with no project, none).
        open_scene: ?scene_file.OpenScene = null,
        /// Where the user's and the project's preferences are (their values are in `app`).
        preference_folders: preferences.Folders,
        /// Edit > Preferences, while open.
        preferences_window: ?*preferences.PreferencesWindow = null,
        /// File > Export, while open.
        export_window: ?*ExportWindow = null,
        plugins_window: ?*plugin_manager.PluginsWindow = null,
        /// File > Project Settings, while open.
        /// The Preferences window's Project section, while that window is open on a project.
        project_settings: ?*ProjectSettings = null,
        /// The Inspector's UI (the game's and plugins' `editorUi`), and the font every page shares.
        ui: ui.Context,
        /// JetBrains Mono, in `ui`'s font's atlas, for terminal output. On the heap, as views keep it.
        mono: *ui.Font,
        /// The Console panel's UI and state, drawing with `ui`'s font.
        console_ui: ui.Context,
        /// The Hierarchy panel's UI, drawing with `ui`'s font.
        hierarchy_ui: ui.Context,
        /// The Hierarchy's and the Inspector's entity views, and the entity selected.
        entity_editor: entities.EntityEditor,
        /// The Assets panel's UI (drawing with `ui`'s font), state, and icons.
        assets_ui: ui.Context,
        assets_panel: assets.AssetsPanel,
        /// The Animation panel's UI (drawing with `ui`'s font) and state.
        animation_ui: ui.Context,
        ui_designer_ui: ui.Context,
        ui_tree_ui: ui.Context,
        ui_properties_ui: ui.Context,
        ui_designer: ui_designer.Designer = .{},
        asset_preview_ui: ui.Context,
        asset_preview: AssetPreview,
        scene_2d_ui: ui.Context,
        /// The 2D Scene panel: its camera, grid and dragging.
        scene_2d: Scene2d = .{},
        animation: animation_dock.Dock = .{},
        asset_icons: AssetIcons,
        console: Console,
        /// A UI of its own for each plugin panel there can be, drawing with `ui`'s font.
        plugin_pages: [panels.max_pages - panels.first_plugin_page]ui.Context,
        /// The page (see `page`) that last took a press, which gets keyboard input.
        focused_page: usize = 0,
        /// The title bar, menus and dockable panels of every window.
        workspace: Workspace,
        /// Where the main window's drawn title bar is; SDL's hit test keeps a pointer to it.
        frame: *weeoui_sdl3.Frame,
        /// The game's scene, rendered offscreen and drawn into the Scene panel.
        scene: eggy.SceneTexture,
        /// What the selected camera sees, drawn in the Scene panel's corner.
        camera_preview: eggy.SceneTexture,
        /// The model the Asset Preview panel shows, made the first time one is shown.
        model_view: ?eggy.SceneTexture = null,
        /// The world seen flat in the 2D Scene panel, made the first time it is shown, and the
        /// meshes it draws.
        scene_2d_view: ?eggy.SceneTexture = null,
        drawables_2d: []eggy.mesh.Drawable,
        /// The meshes the scene draws, gathered from the world through the game's library.
        drawables: []eggy.mesh.Drawable,
        /// This frame's billboards (UI scenes in the world), which graphics borrows while drawing.
        billboards: eggy.ui_scenes.billboards.Frame = undefined,
        /// The Scene panel's camera, gizmo, picking and buttons.
        scene_view: scene_view.SceneView = .{},
        /// When the scene camera last flew, to fly by the time since.
        camera_tick_ns: u64 = 0,
        /// Draws the main window's UI into the frame `Graphics` already started.
        overlay: weeoui_vitellus.Renderer,
        /// The OS window for each of the dock's pop-out windows that is open.
        popouts: [ui.dock.max_windows]?PopOut = @splat(null),
        /// File > New Project or Open Project, while its window is open.
        project_flow: ?*ProjectFlow = null,
        /// A folder File > Open Project's picker chose; it may call back from another thread,
        /// so the next frame takes it from here.
        picked_project: std.atomic.Value(?[*:0]u8) = .init(null),
        /// Whether that picker is for Open Project with Developer Eggy, which links the project.
        picking_to_link: bool = false,
        /// Whether the editor's windows are hidden, as they are while a new project is created.
        hidden: bool = false,
        /// The explicit or discovered project this editor opened, from its `eggy.zon`.
        project: ?workspace_zig.Project = null,
        /// The open project's model and image files, imported for the scene's caches.
        project_assets: ?*ProjectAssets = null,
        /// The build started when the window regains focus, while it runs or once it made a new
        /// editor (see `rebuildState`).
        rebuild: ?*Job = null,
        /// The project's sources as the last build (or the one that made this editor) saw them;
        /// refocusing rebuilds only once they change.
        built_sources: source_stamp.Stamp = .{},
        /// Help > DevTools' window, while open.
        devtools_window: ?*DevtoolsWindow = null,
        about_window: ?*AboutWindow = null,
        /// When the last frame started, for DevTools' Performance.
        frame_start_ns: u64 = 0,
        /// Whether to open the project's editor once `rebuild` is done, changed or not (Reload).
        reload_when_built: bool = false,
        /// When the editor's windows last lost focus, until one gains it again; see `cameBack`.
        focus_lost_ms: ?u64 = null,
        /// The Build progress window, while `rebuild` runs or until its result is dismissed. The
        /// editor takes no input and the game is paused while it is open.
        build_window: ?*BuildWindow = null,
        /// When this editor's executable was built, to tell whether a rebuild changed it.
        editor_modified: ?std.Io.Timestamp = null,
        /// Which Eggy the project could move to, for File > Upgrade Editor and Link Developer Eggy.
        upgrades: Upgrades,
        /// When the main title bar was last pressed, to spot a double-click; see `titlebarPressed`.
        titlebar_press_ns: u64 = 0,
        /// When a double-click on the title bar asked to maximize or restore, until that is done.
        maximize_pending_ns: ?u64 = null,

        const Self = @This();
        /// SDL's default double-click time.
        const double_click_ns = 500 * std.time.ns_per_ms;
        const title = project.name ++ " - eggy editor";

        /// What would lose the scene's unsaved changes, and so asks first (see `mayLeave`).
        const Leaving = enum { quit, reload, new_project, open_project, open_project_linked };

        /// Initialize the desktop editor host with SDL/App graphics, shared UI fonts,
        /// persisted preferences/layout, project discovery, and the game's shared library.
        /// Borrows `process_init` for App lifetime; `args` are sentinel process arguments
        /// supporting project/window selection. Returns caller-owned state; keep it stable
        /// once passed to host callbacks. Startup allocation/I/O/graphics errors propagate
        /// with cleanup; an unavailable game library logs and leaves tools usable without it.
        ///
        /// ```zig
        /// // Shared SDL entry infrastructure owns process_init for this lifetime:
        /// var host = try Self.init(process_init, args);
        /// defer host.deinit();
        /// _ = try host.iterate();
        /// ```
        pub fn init(process_init: *const std.process.Init, args: []const [*:0]const u8) !Self {
            eggy.log.start(process_init.io, .editor, project.name ++ "_editor", args);
            const gpa = process_init.gpa;
            var app = try eggy.App.initForProject(process_init, title, project.name, .editor, .{});
            errdefer app.deinit();
            app.storage = try eggy.storage.Storage.init(gpa, process_init.io, project.name);
            const opened_project = try openProject(gpa, app.window.window, args);
            errdefer if (opened_project) |opened| freeProject(gpa, opened);
            // The project's graphics defaults, before anything is drawn.
            if (opened_project) |opened| {
                const wanted = project_settings_zig.loadGraphics(gpa, opened.dir) catch |err| blk: {
                    std.log.warn("cannot read the graphics settings from {s}: {t}", .{ eggy.project.file_name, err });
                    break :blk app.graphics_options.defaults;
                };
                _ = app.setGraphicsDefaults(wanted) catch |err| std.log.err("cannot use the project's graphics defaults: {t}", .{err});
            }
            // Every project has its resources and scene folders.
            if (opened_project) |opened| {
                var threaded: std.Io.Threaded = .init_single_threaded;
                const io = threaded.io();
                if (std.Io.Dir.cwd().openDir(io, opened.dir, .{})) |dir| {
                    var project_dir = dir;
                    defer project_dir.close(io);
                    eggy.project.makeFolders(io, project_dir) catch |err| std.log.warn("cannot make {s}: {t}", .{ eggy.project.scenes_dir, err });
                } else |_| {}
            }
            // Where the editor that reloaded into this one was (see `launchRebuilt`), else maximized.
            if (window_placement.fromArgs(args)) |placement| placement.apply(app.window.window) else app.window.window.maximize() catch |err| std.log.warn("cannot maximize the editor: {t}", .{err});
            if (opened_project) |opened| useProjectIcon(gpa, opened.dir);
            icon.apply(app.window.window);
            var context = try ui.Context.init(gpa);
            // The editor's pages and windows are a tool's: compact, with small text.
            context.density = .compact;
            errdefer context.deinit();
            context.srgb_target = weeoui_vitellus.isSrgb(app.graphics.color_format);
            context.theme = weeoui_sdl3.systemTheme();
            const mono = try gpa.create(ui.Font);
            errdefer gpa.destroy(mono);
            mono.* = try ui.Font.initCompanion(gpa, @embedFile("mono_font"), context.font, &.{ 10, 11, 12, 13, 14, 15, 16, 18, 20, 24 });
            errdefer mono.deinit();
            // Nerd Font icons for the characters the faces lack in private-use areas, in both.
            try context.font.setSymbolsFont(@embedFile("symbols_font"));
            try mono.setSymbolsFont(@embedFile("symbols_font"));
            var console_ui = ui.Context.initWithFont(gpa, context.font);
            errdefer console_ui.deinit();
            var hierarchy_ui = ui.Context.initWithFont(gpa, context.font);
            errdefer hierarchy_ui.deinit();
            var assets_ui = ui.Context.initWithFont(gpa, context.font);
            errdefer assets_ui.deinit();
            var animation_ui = ui.Context.initWithFont(gpa, context.font);
            errdefer animation_ui.deinit();
            var ui_designer_ui = ui.Context.initWithFont(gpa, context.font);
            errdefer ui_designer_ui.deinit();
            var ui_tree_ui = ui.Context.initWithFont(gpa, context.font);
            errdefer ui_tree_ui.deinit();
            var ui_properties_ui = ui.Context.initWithFont(gpa, context.font);
            errdefer ui_properties_ui.deinit();
            var asset_preview_ui = ui.Context.initWithFont(gpa, context.font);
            errdefer asset_preview_ui.deinit();
            var scene_2d_ui = ui.Context.initWithFont(gpa, context.font);
            errdefer scene_2d_ui.deinit();
            var asset_icons = AssetIcons.load(gpa, context.font);
            errdefer asset_icons.deinit(gpa);
            var console = Console.init(gpa, mono);
            errdefer console.deinit();
            var plugin_pages: [panels.max_pages - panels.first_plugin_page]ui.Context = undefined;
            for (&plugin_pages) |*page_ui| page_ui.* = ui.Context.initWithFont(gpa, context.font);
            errdefer for (&plugin_pages) |*page_ui| page_ui.deinit();
            var overlay = try weeoui_vitellus.Renderer.init(app.graphics.device, app.graphics.color_format, context.font);
            errdefer overlay.deinit();
            var scene = try eggy.SceneTexture.init(&app.graphics);
            errdefer scene.deinit();
            var camera_preview = try eggy.SceneTexture.init(&app.graphics);
            errdefer camera_preview.deinit();
            const drawables = try gpa.alloc(eggy.mesh.Drawable, eggy.max_drawables);
            errdefer gpa.free(drawables);
            const drawables_2d = try gpa.alloc(eggy.mesh.Drawable, eggy.max_drawables);
            errdefer gpa.free(drawables_2d);

            // Draw the title bar ourselves, with the menus on it, laid out like the desktop's.
            var threaded: std.Io.Threaded = .init_single_threaded;
            var workspace = try Workspace.init(gpa, weeoui_sdl3.buttonLayout(gpa, threaded.io()), &.{});
            errdefer workspace.deinit();
            workspace.project = opened_project;
            const frame = try gpa.create(weeoui_sdl3.Frame);
            errdefer gpa.destroy(frame);
            frame.* = .{};
            weeoui_sdl3.useCustomFrame(app.window.window, frame) catch |err| {
                std.log.warn("custom title bar unavailable: {t}", .{err});
                workspace.custom_frame = false;
            };

            // Preferences, before the game starts so its plugins see them.
            const preference_folders = try preferences.Folders.init(gpa, if (opened_project) |opened| opened.dir else null);
            errdefer preference_folders.deinit(gpa);
            // The layout this user left the dock in last, in any project.
            _ = layout_file.load(gpa, preference_folders.global, &workspace.dock, &workspace.tabs, &workspace.seen_plugin_panels);
            preferences.load(gpa, &app.preference_values, preference_folders);
            console.levels[@intFromEnum(std.log.Level.debug)] = preferences.editor(&app.preference_values).show_debug_logs;

            // The game, from its library beside the editor, without the plugins the project turned
            // off, and the scene open last.
            var plugin_switches = PluginSwitches.load(gpa, if (opened_project) |opened| opened.dir else null);
            errdefer plugin_switches.deinit();
            var open_scene: ?scene_file.OpenScene = null;
            errdefer if (open_scene) |*remembered| remembered.deinit();
            const library_path = try libraryPath(gpa);
            defer gpa.free(library_path);
            var game: ?HotGame = HotGame.load(gpa, library_path) catch |err| blk: {
                std.log.err("cannot load the game from {s}: {t}", .{ library_path, err });
                break :blk null;
            };
            errdefer if (game) |*loaded| loaded.deinit(&app);
            if (game) |loaded| {
                workspace.setPluginPanels(loaded.panels);
                workspace.plugin_commands = loaded.commands;
                workspace.setPluginBars(.{ .menus = loaded.menus, .status_items = loaded.status_items });
                preferences.writeRegistry(gpa, preference_folders, loaded.plugin_keys, loaded.preference_manifests, plugin_switches.off()) catch |err| std.log.warn("cannot update .eggy/plugins.zon: {t}", .{err});
            }
            // Model and image files, imported from the project as the scene first shows each.
            const project_assets: ?*ProjectAssets = if (opened_project) |opened| blk: {
                const loaders = try gpa.create(ProjectAssets);
                errdefer gpa.destroy(loaders);
                loaders.* = try ProjectAssets.init(gpa, process_init.io, opened.dir);
                errdefer loaders.deinit();
                app.graphics.models.loader = loaders.models();
                app.graphics.textures.loader = loaders.textures();
                app.resource_provider = loaders.resources();
                break :blk loaders;
            } else null;
            errdefer if (project_assets) |loaders| {
                loaders.deinit();
                gpa.destroy(loaders);
            };
            // Scenes and materials from before asset ids hold paths and bare clip names; make them
            // ids before one is opened, since a clip name only means something beside its model.
            if (game) |*loaded| if (project_assets) |loaders| {
                legacy_refs.normalizeOnOpen(gpa, process_init.io, opened_project.?.dir, loaders, loaded.sceneAccess().types());
            };
            // The project's scene first, so the game's plugins start among its entities.
            if (game) |*loaded| {
                if (opened_project) |opened| {
                    open_scene = .{ .gpa = gpa, .project_dir = opened.dir };
                    open_scene.?.reopen(&app.world, loaded.sceneAccess());
                }
            }
            const upgrades = Upgrades.init(gpa, if (opened_project) |opened| opened.dir else null, @import("build_options").source_dir);
            const input_settings = if (opened_project) |opened| try InputSettings.open(gpa, &app.input_backend.?.state, opened.dir) else null;
            errdefer if (input_settings) |settings| settings.close();
            if (game) |*loaded| loaded.start(&app, plugin_switches.off(), .discard);
            var self = Self{ .gpa = gpa, .game = game, .game_modified = modifiedAt(library_path), .app = app, .ui = context, .mono = mono, .console_ui = console_ui, .hierarchy_ui = hierarchy_ui, .assets_ui = assets_ui, .assets_panel = .init(gpa), .animation_ui = animation_ui, .ui_designer_ui = ui_designer_ui, .ui_tree_ui = ui_tree_ui, .ui_properties_ui = ui_properties_ui, .asset_preview_ui = asset_preview_ui, .asset_preview = .init(gpa, mono), .scene_2d_ui = scene_2d_ui, .asset_icons = asset_icons, .entity_editor = .init(gpa), .console = console, .plugin_pages = plugin_pages, .workspace = workspace, .frame = frame, .scene = scene, .camera_preview = camera_preview, .drawables = drawables, .drawables_2d = drawables_2d, .overlay = overlay, .project = opened_project, .editor_modified = if (opened_project) |opened| editorModified(gpa, opened) else null, .upgrades = upgrades, .preference_folders = preference_folders, .open_scene = open_scene, .history = .{ .gpa = gpa }, .plugin_switches = plugin_switches, .project_assets = project_assets };
            self.input_settings = input_settings;
            self.entity_editor.assets = project_assets;
            self.built_sources = self.sourcesNow();
            return self;
        }

        /// Tear down the host's loaded game, jobs, tool/pop-out windows, UI, GPU resources,
        /// and App, saving the dock layout for the next launch. Does not implicitly save the
        /// scene; the leave-confirmation workflow must run first. Borrowed process init
        /// remains caller-owned; no callbacks may access this host afterward.
        ///
        /// ```zig
        /// var host = try Self.init(process_init, args);
        /// defer host.deinit(); // Once after SDL stops delivering callbacks.
        /// ```
        pub fn deinit(self: *Self) void {
            self.releaseViewportMouse();
            self.game_input.deinit(self.gpa);
            self.extension_state.deinit(self.gpa);
            if (self.game) |*game| game.deinit(&self.app);
            if (self.input_settings) |settings| settings.close();
            if (self.input_map_window) |window| window.close(&self.app.graphics);
            if (self.project_flow) |flow| flow.close(&self.app.graphics);
            if (self.build_window) |window| window.close(&self.app.graphics);
            if (self.devtools_window) |window| window.close(&self.app.graphics);
            if (self.about_window) |window| window.close(&self.app.graphics);
            if (self.preferences_window) |window| window.close(&self.app.graphics);
            if (self.export_window) |window| window.close(&self.app.graphics);
            if (self.plugins_window) |window| window.close(&self.app.graphics);
            if (self.project_settings) |settings| settings.close();
            if (self.save_prompt) |prompt| prompt.close(&self.app.graphics);
            // The dock as this user left it, for the next editor.
            layout_file.save(self.gpa, self.preference_folders.global, &self.workspace.dock, &self.workspace.tabs, self.workspace.seen_plugin_panels.items);
            self.preference_folders.deinit(self.gpa);
            if (self.open_scene) |*scene| scene.deinit();
            self.play_mode.deinit();
            self.history.deinit();
            if (self.layout_step) |text| self.gpa.free(text);
            self.plugin_switches.deinit();
            if (self.rebuild) |job| job.deinit();
            if (self.picked_project.swap(null, .acq_rel)) |path| std.heap.c_allocator.free(std.mem.span(path));
            if (self.project) |opened| freeProject(self.gpa, opened);
            if (self.project_assets) |loaders| {
                // Resource jobs read through these loaders: cancel and join them first.
                if (self.app.resource_jobs) |jobs| jobs.clear();
                loaders.deinit();
                self.gpa.destroy(loaders);
            }
            self.upgrades.deinit();
            for (&self.popouts) |*popout| if (popout.*) |*open| {
                open.close(&self.app.graphics);
                popout.* = null;
            };
            // The overlay's and scene's GPU resources must outlive any frame still in flight.
            self.app.graphics.queue.waitIdle() catch {};
            self.scene.deinit();
            self.camera_preview.deinit();
            if (self.model_view) |*view| view.deinit();
            if (self.scene_2d_view) |*view| view.deinit();
            self.gpa.free(self.drawables);
            self.gpa.free(self.drawables_2d);
            self.overlay.deinit();
            self.workspace.deinit();
            for (&self.plugin_pages) |*page_ui| page_ui.deinit();
            self.console.deinit();
            self.console_ui.deinit();
            self.hierarchy_ui.deinit();
            self.assets_ui.deinit();
            self.ui_designer.deinit(self.gpa);
            self.ui_designer_ui.deinit();
            self.ui_tree_ui.deinit();
            self.ui_properties_ui.deinit();
            self.asset_preview_ui.deinit();
            self.asset_preview.deinit();
            self.scene_2d_ui.deinit();
            self.animation_ui.deinit();
            self.assets_panel.deinit();
            self.asset_icons.deinit(self.gpa);
            self.entity_editor.deinit();
            self.mono.deinit();
            self.gpa.destroy(self.mono);
            self.ui.deinit();
            self.app.deinit();
            self.gpa.destroy(self.frame);
        }

        /// Advance one editor-host frame: service project/build flows, update game/editor
        /// hooks, track undo/autosave, build dock pages, and present each live window.
        /// Requires successful init and serialized main-thread lifecycle calls. Minimized
        /// windows skip drawing; gameplay runs only in unpaused play, outside modal builds.
        /// Frame/input/render/job errors propagate; `.success` means a replacement launched
        /// or quit was approved, `.run` means continue. Does not destroy the host.
        ///
        /// ```zig
        /// // SDL callback adapter, with a live host:
        /// const result = try host.iterate();
        /// if (result != .run) return result;
        /// ```
        pub fn iterate(self: *Self) !sdl3.AppResult {
            // Graphics choices queued since last frame take effect before anything is drawn.
            try self.app.applyGraphicsSettings();
            self.app.beginDiagnosticsFrame();
            self.app.graphics.materials.resources = self.app.resources();
            self.app.graphics.clips.resources = self.app.resources();
            const result = try self.iterateFrame();
            try self.app.finishDiagnosticsFrame();
            return result;
        }

        fn iterateFrame(self: *Self) !sdl3.AppResult {
            // While a new project is created, only its loading screen shows. Hidden windows aren't
            // drawn to: presenting to one can block until it is shown again.
            if (self.project_flow) |flow| if (flow.isWorking()) {
                self.setHidden(true);
                return self.updateProjectFlow(flow);
            };
            self.setHidden(false);

            try self.app.graphics.syncSize(self.app.window);
            try self.syncViewportMouse();
            self.applyPendingMaximize(false);
            const viewport = try self.uiViewport() orelse return .run; // minimized
            // The game stays paused while the Build progress window is up.
            // The game runs only while playing; otherwise only its editor tools do.
            if (self.build_window == null) if (self.game) |*game| {
                if (self.play_mode.running()) {
                    self.app.time.tick(sdl3.timer.getNanosecondsSinceInit());
                    try self.app.advanceInput();
                    game.update(&self.app);
                    self.app.input.endFrame();
                } else {
                    var editor_context = extensions.context(self);
                    game.editorUpdate(&editor_context);
                }
            };
            try self.syncPopOuts();
            self.keepLayout();
            // The scene camera flies by the keys held, over the time since the last frame.
            const now_ns = sdl3.timer.getNanosecondsSinceInit();
            if (self.camera_tick_ns != 0) self.scene_view.camera.fly(@as(f32, @floatFromInt(now_ns - self.camera_tick_ns)) / std.time.ns_per_s);
            self.camera_tick_ns = now_ns;
            // Scene instances' entities, then what the Scene panel is seen from, and the
            // selection's gizmo over it.
            self.syncSceneInstances();
            self.entity_editor.forgetDead(&self.app);
            const look: scene_view.SceneView.Look = if (!self.play_mode.playing()) .editing else if (self.workspace.simulating) .simulating else .playing;
            self.scene_view.update(self.sceneTarget(), if (self.workspace.placed.scene) |placed| placed.rect else null, look);
            self.workspace.scene_overlay = self.scene_view.overlay();
            if (self.play_mode.playing() and !self.workspace.simulating) if (self.game) |game| {
                if (game.hasGameUi() or game.hasDraw()) self.workspace.scene_overlay.no_camera = false;
            };

            // Lay out every window, then tell the OS where the main title bar is.
            const flags = self.app.window.window.getFlags();
            self.workspace.window_state = .{ .maximized = flags.maximized, .focused = flags.input_focus };
            var window_viewports: [ui.dock.max_windows]?ui.Rect = @splat(null);
            for (self.popouts, &window_viewports) |popout, *area| if (popout) |open| {
                area.* = try open.viewport();
            };
            var frame_arena = std.heap.ArenaAllocator.init(self.gpa);
            defer frame_arena.deinit();
            self.workspace.build_state = try self.rebuildState(frame_arena.allocator());
            self.workspace.time_ms = sdl3.timer.getMillisecondsSinceInit();
            eggy.log.setLevel(@enumFromInt(@intFromEnum(preferences.editor(&self.app.preference_values).log_level)));
            self.ui.theme = switch (preferences.editor(&self.app.preference_values).theme) {
                .system => weeoui_sdl3.systemTheme(),
                .light => .{},
                .dark => ui.Theme.dark,
            };
            self.ui.theme.text_size = 12;
            self.ui.theme.small_text_size = 11;
            self.workspace.engine_label = self.upgrades.label;
            self.workspace.scene_name = if (self.open_scene) |*scene| scene.name() else null;
            // A few times a second (not while playing: Stop puts the scene back), compare the world
            // with the saved scene, for the status bar's `*`, and with the last undo step.
            // Nor while the Animation panel poses the scene: the pose is not an edit.
            if (self.workspace.time_ms -| self.unsaved_checked_ms >= 300 and !self.play_mode.playing() and !self.animation.isPosed()) {
                self.unsaved_checked_ms = self.workspace.time_ms;
                if (self.sceneText()) |text| {
                    const hash = std.hash.Wyhash.hash(0, text);
                    self.workspace.scene_unsaved = if (self.open_scene) |*scene| scene.unsavedHash(hash, &self.app.world) else false;
                    // A gizmo drag, or a number dragged in the Inspector, becomes one step once let go.
                    if (!self.scene_view.steeringNow() and !self.scene_2d.isMoving() and !self.entity_editor.inspector.scrubbing()) self.history.watch(text, self.workspace.time_ms, self.typing()) else self.gpa.free(text);
                }
                self.watchLayout();
                self.workspace.play_warning = self.playWarning();
            }
            self.workspace.can_upgrade = self.upgrades.can_upgrade;
            self.workspace.can_link = self.upgrades.can_link;
            self.workspace.developer_known = self.upgrades.developer_dir != null;
            const modifiers = sdl3.keyboard.getModState();
            self.workspace.shift_held = modifiers.left_shift or modifiers.right_shift;
            const stop_key = preferences.editor(&self.app.preference_values).stop_play_key;
            self.workspace.stop_tooltip = try std.fmt.allocPrint(frame_arena.allocator(), "Stop ({s})", .{sdl3.keyboard.getScancodeName(stop_key) orelse @tagName(stop_key)});
            self.workspace.bar_states = try self.askPluginBars(frame_arena.allocator());
            try self.workspace.build(viewport, window_viewports, self.ui.font);
            try self.syncViewportMouse();
            // Help > DevTools, on this frame's main window, before that draws their highlight.
            self.workspace.devtools = null;
            if (self.devtools_window) |window| {
                const now = sdl3.timer.getNanosecondsSinceInit();
                if (self.frame_start_ns != 0) window.tools.recordFrame(@as(f32, @floatFromInt(now - self.frame_start_ns)) / std.time.ns_per_ms);
                self.frame_start_ns = now;
                try window.update(&self.app.graphics, &self.ui, self.workspace.roots[main_slot].?, &self.app.profiling);
                self.workspace.devtools = &window.tools;
            }
            self.frame.* = self.workspace.titlebarFrame();

            // The Animation panel's pose follows its clock and the selection, before it is drawn.
            if (self.animationEnv()) |env| self.animation.tick(env, self.workspace.placed.pages[panels.animation_page] != null);

            // Build each page's UI into its panel, wherever that is.
            var pages_buffer: [panels.max_pages][]const ui.Vertex = @splat(&.{});
            const pages = pages_buffer[0..self.pageCount()];
            for (pages, 0..) |*vertices, index| {
                const placed = self.workspace.placed.pages[index] orelse continue;
                const page_ui = self.page(index);
                page_ui.theme = self.ui.theme;
                page_ui.density = .compact;
                page_ui.pixel_scale = self.ui.pixel_scale;
                page_ui.srgb_target = self.ui.srgb_target;
                page_ui.newFrame(placed.rect);
                page_ui.time_ms = sdl3.timer.getMillisecondsSinceInit();
                switch (index) {
                    panels.inspector_page => self.buildInspector(),
                    panels.console_page => {
                        if (self.console.build(page_ui, if (self.project) |opened| opened.dir else null)) |source| self.openDiagnostic(source);
                    },
                    panels.hierarchy_page => {
                        self.entity_editor.buildHierarchy(page_ui, &self.app, self.gamePtr());
                        self.applyEntityCommands();
                    },
                    panels.assets_page => {
                        // The view is a preference, so it is the same in the next editor.
                        const view_before: assets.View = @enumFromInt(@intFromEnum(preferences.editor(&self.app.preference_values).assets_view));
                        self.assets_panel.view = view_before;
                        self.assets_panel.file_types = if (self.game) |game| game.file_types else &.{};
                        if (self.assets_panel.build(page_ui, if (self.project) |opened| opened.dir else null, self.project_assets, &self.asset_icons, self.openScenePath())) |action| self.applyAssetAction(action);
                        if (self.assets_panel.view != view_before) self.rememberAssetsView();
                    },
                    panels.animation_page => if (self.animationEnv()) |env| self.animation.build(page_ui, env) else page_ui.muted("Open a project to animate."),
                    panels.ui_designer_page => if (self.uiDesignerEnv()) |env| self.ui_designer.buildPreview(page_ui, env) else page_ui.muted("Open a project to design UI."),
                    panels.ui_tree_page => if (self.uiDesignerEnv()) |env| self.ui_designer.buildTree(page_ui, env) else page_ui.muted("Open a project to design UI."),
                    panels.asset_preview_page => if (self.project) |opened| if (self.project_assets) |project_assets| {
                        const picked = self.assets_panel.selection();
                        self.asset_preview.build(page_ui, .{
                            .selection = if (picked) |chosen| .{ .path = chosen.path, .virtual = chosen.virtual } else null,
                            .assets = project_assets,
                            .project_dir = opened.dir,
                            .app = &self.app,
                            .time_ms = page_ui.time_ms,
                        });
                    } else page_ui.muted("Open a project to preview its files.") else page_ui.muted("Open a project to preview its files."),
                    panels.ui_properties_page => if (self.uiDesignerEnv()) |env| self.ui_designer.buildProperties(page_ui, env, self.dragging(page_ui.builder().allocator)) else page_ui.muted("Open a project to design UI."),
                    panels.scene_2d_page => self.scene_2d.build(page_ui),
                    else => if (self.game) |*game| {
                        var editor_context = extensions.context(self);
                        game.editorPanelUi(index - panels.first_plugin_page, &editor_context, page_ui);
                    },
                }
                // What is being dragged, named beside the pointer in the page it is over.
                if (self.dragging(frame_arena.allocator())) |dragged| if (self.pageAt(self.workspace.pointer_slot, page_ui.pointer.x, page_ui.pointer.y) == index) {
                    page_style.dragChip(page_ui, self.dragLabel(frame_arena.allocator(), dragged, index));
                };
                vertices.* = try page_ui.render();
                clipboard.sync(page_ui);
            }
            // Draw each window.
            try self.present(main_slot, &self.app.graphics.surface, &self.overlay, viewport, pages);
            for (&self.popouts, 0..) |*popout, i| if (popout.*) |*open| {
                const area = window_viewports[i] orelse continue;
                try open.surface.syncSize(self.app.graphics.queue, open.window);
                try self.present(workspace_zig.windowSlot(i), &open.surface, &open.overlay, area, pages);
            };
            self.syncTextInput();
            // A folder chosen in File > Open Project's picker: open it, linking it first for Open
            // Project with Developer Eggy once that is confirmed.
            if (self.picked_project.swap(null, .acq_rel)) |path| {
                defer std.heap.c_allocator.free(std.mem.span(path));
                const dir = std.mem.span(path);
                const action: job_zig.Action = if (self.picking_to_link) .{ .link = self.upgrades.developer_dir orelse "" } else .open;
                const confirmed = action == .open or self.upgrades.confirmLink(self.app.window.window, std.fs.path.basename(dir));
                // The layout first, for the editor the project opens in.
                if (self.project_flow == null and confirmed) layout_file.save(self.gpa, self.preference_folders.global, &self.workspace.dock, &self.workspace.tabs, self.workspace.seen_plugin_panels.items);
                if (self.project_flow == null and confirmed) self.project_flow = try ProjectFlow.open(self.gpa, &self.app.graphics, self.ui.font, self.mono, dir, action);
            }
            // File > New/Open Project's window, if open.
            if (self.project_flow) |flow| if (try self.updateProjectFlow(flow) == .success) return .success;
            // "Save changes?", if asking.
            if (self.save_prompt) |prompt| if (try prompt.update(&self.app.graphics, &self.ui)) |answer| {
                if (try self.answerSavePrompt(answer)) return .success;
            };
            self.autosave();
            // Edit > Preferences, if open.
            if (self.preferences_window) |window| {
                const flipped = try window.update(&self.app.graphics, &self.ui, try self.preferenceSections(frame_arena.allocator()), &self.app.preference_values, self.preference_folders, &self.history);
                if (flipped) |plugin| self.flipPlugin(plugin);
                // Its Project section writes eggy.zon as it changes: a step to undo.
                if (self.project_settings) |settings| if (settings.save() catch |err| blk: {
                    std.log.err("cannot write {s}: {t}", .{ eggy.project.file_name, err });
                    break :blk null;
                }) |change| {
                    self.history.recordProjectSettings(change.before, change.after, self.workspace.time_ms);
                    self.setGraphicsDefaults(settings.saved_graphics);
                    self.refreshProjectIcon();
                };
            }
            // File > Export, if open.
            if (self.export_window) |window| {
                var editor_context = extensions.context(self);
                const result = try window.update(&self.app.graphics, &self.ui, if (self.game) |*game| game else null, &editor_context);
                // Choosing the scene it starts in keeps it as the default: a step to undo.
                if (result.change) |change| {
                    self.history.recordProjectSettings(change.before, change.after, self.workspace.time_ms);
                    if (self.project_settings) |settings| settings.reload() catch {};
                }
                if (result.project_settings) self.showProjectSettings() catch |err| std.log.err("cannot open Project Settings: {t}", .{err});
                if (!result.open) {
                    window.close(&self.app.graphics);
                    self.export_window = null;
                }
            }
            // Edit > Plugins, if open: an install or uninstall is a step to undo, and a rebuild; a
            // switch is as Preferences > Plugins makes it.
            if (self.plugins_window) |window| {
                const outcome = try window.update(&self.app.graphics, &self.ui, self.plugin_switches.off());
                if (outcome.change) |change| {
                    self.history.record(.{ .plugins = .{ .project = change.project, .package = change.package } });
                    if (self.project_settings) |settings| settings.reload() catch {};
                    self.rebuildForPlugins();
                }
                if (outcome.switched) |switched| self.flipPlugin(.{ .key = switched.module, .on = switched.on });
            }
            if (self.input_map_window) |window| {
                const result = try window.update(&self.app.graphics, &self.ui, &self.history);
                if (result.saved) self.assets_panel.refreshSoon();
                if (result.close) {
                    window.close(&self.app.graphics);
                    self.input_map_window = null;
                }
            }
            if (self.input_settings) |settings| try settings.recordPending(&self.history);
            if (self.about_window) |window| if (!try window.update(&self.app.graphics, &self.ui)) {
                window.close(&self.app.graphics);
                self.about_window = null;
            };
            // The Build progress window, if open.
            if (self.build_window) |window| if (try self.updateBuildWindow(window, frame_arena.allocator())) return .success;

            const pointer = self.workspace.pointer;
            const hovered = self.pageAt(self.workspace.pointer_slot, pointer.x, pointer.y);
            const over_game = self.play_mode.playing() and !self.workspace.simulating and (self.game_input.mouse_captured or self.game_input.pointer_in_scene or self.game_input.buttons != 0);
            const game_cursor: ?ui.Cursor = if (over_game) if (self.app.ui_layer) |layer| layer.context.cursor else null else null;
            const dock_cursor = self.workspace.dock.cursor();
            if (!over_game or self.app.ui_layer != null or dock_cursor != null) {
                weeoui_sdl3.setCursor(dock_cursor orelse game_cursor orelse if (hovered) |index| self.page(index).cursor else .default);
            }
            if (self.extension_state.takeRequest()) |request| {
                if (extensions.processRequest(self, request)) |exit| {
                    if (exit) return .success;
                } else |err| {
                    std.log.err("queued editor request failed: {t}", .{err});
                    self.workspace.toast("Couldn't perform the request: see the Console");
                }
            }
            return .run;
        }

        /// Draw File > New/Open Project's window and move it on: drop it once closed, and quit once
        /// the new project's editor is up.
        fn updateProjectFlow(self: *Self, flow: *ProjectFlow) !sdl3.AppResult {
            switch (try flow.update(&self.app.graphics, &self.ui)) {
                .running => {},
                .closed => {
                    flow.close(&self.app.graphics);
                    self.project_flow = null;
                },
                .launched => return .success,
            }
            return .run;
        }

        /// SDL folder-dialog callback used only by this host; may execute off the main thread.
        /// Copies the first borrowed path into a C-allocator atomic handoff for the next frame,
        /// replacing/freeing any older choice. Ignores failed/empty results and allocation
        /// failure; the filter index is unused. A successful choice requires non-null `self`
        /// kept alive until dialog completion; no UI/GPU work runs on the callback thread.
        ///
        /// ```zig
        /// // Editor main thread registers the callback; SDL invokes pickedProject:
        /// sdl3.dialog.showOpenFolder(Self, Self.pickedProject, host, host.app.window.window, null, false);
        /// // Keep host alive; host.iterate() later consumes the copied selection.
        /// ```
        pub fn pickedProject(self: ?*Self, files: ?[]const [*:0]const u8, _: ?usize, failed: bool) void {
            const chosen = files orelse return;
            if (failed or chosen.len == 0) return;
            const copy = std.heap.c_allocator.dupeZ(u8, std.mem.span(chosen[0])) catch return;
            if (self.?.picked_project.swap(copy.ptr, .acq_rel)) |old| std.heap.c_allocator.free(std.mem.span(old));
        }

        /// Open the editor `job` rebuilt in place of this one, where this one's window is. Returns
        /// false, launching nothing, while "Save changes?" asks first.
        fn launchRebuilt(self: *Self, job: *Job) !bool {
            if (!self.mayLeave(.reload)) return false;
            try self.launchEditorFrom(job);
            return true;
        }

        /// Whether the editor may go ahead with `leaving`: yes when the scene has no unsaved
        /// changes, or the person just answered "Save changes?" for it. Otherwise it opens the
        /// prompt (once) and says no; the answer carries `leaving` out (`answerSavePrompt`).
        /// Internal host transition guard, not an extension/game API. Stops play before
        /// comparing the saved scene; an unsaved input-map document blocks leaving first.
        /// Prompt creation errors log and deny permission to avoid losing edits.
        ///
        /// ```zig
        /// // Inside the host's quit command route:
        /// if (self.mayLeave(.quit)) return .success;
        /// return .run; // Continue frames/events to service the save prompt.
        /// ```
        pub fn mayLeave(self: *Self, leaving: Leaving) bool {
            if (self.input_map_window) |window| if (window.document.modified()) {
                window.view.confirm_close = true;
                window.window.popout.window.window.raise() catch |err| std.log.err("cannot focus the input map: {t}", .{err});
                self.workspace.toast("Save or discard the input map, then try again");
                return false;
            };
            if (self.leave_approved) {
                self.leave_approved = false;
                return true;
            }
            // What a play did isn't the scene: compare the scene as it was before.
            self.stopPlaying();
            if (!self.sceneUnsaved()) return true;
            if (self.save_prompt != null) return false;
            const doing = switch (leaving) {
                .quit => "quitting",
                .reload => "reloading the editor",
                .new_project, .open_project, .open_project_linked => "opening another project",
            };
            const name = if (self.open_scene) |*scene| scene.name() else null;
            self.save_prompt = save_prompt_zig.SavePrompt.open(self.gpa, &self.app.graphics, self.ui.font, self.app.window.window, name, doing) catch |err| {
                // Without the prompt, keep the changes rather than lose them.
                std.log.err("cannot ask about unsaved changes ({t}): save first", .{err});
                return false;
            };
            self.leaving = leaving;
            return false;
        }

        /// Carry out the answer to "Save changes?". Returns whether the editor should now close
        /// (quitting, or a reload launched).
        fn answerSavePrompt(self: *Self, answer: save_prompt_zig.Answer) !bool {
            if (self.save_prompt) |prompt| prompt.close(&self.app.graphics);
            self.save_prompt = null;
            switch (answer) {
                .cancel => return false,
                .save => {
                    self.saveScene();
                    if (self.sceneUnsaved()) return false; // the save failed: stay
                },
                .discard => {},
            }
            // Go where the editor was going, this time without asking. A reload waiting for its
            // build keeps the answer until it launches.
            self.leave_approved = true;
            switch (self.leaving) {
                .quit => return true,
                .reload => return try self.forceReload(),
                .new_project => self.project_flow = try ProjectFlow.create(self.gpa, &self.app.graphics, self.ui.font, self.mono),
                .open_project, .open_project_linked => {
                    self.picking_to_link = self.leaving == .open_project_linked;
                    sdl3.dialog.showOpenFolder(Self, pickedProject, self, self.app.window.window, null, false);
                },
            }
            self.leave_approved = false;
            return false;
        }

        /// Whether the world has changes its scene file doesn't (or, with no scene open, has any
        /// entities). False without a project, where there is nowhere to save.
        fn sceneUnsaved(self: *Self) bool {
            const scene = if (self.open_scene) |*open| open else return false;
            const text = self.sceneText() orelse return false;
            defer self.gpa.free(text);
            return scene.unsavedHash(std.hash.Wyhash.hash(0, text), &self.app.world);
        }

        /// Save the open scene by itself every `autosave_seconds` (a preference; 0: never) while
        /// it has changes, unless playing or typing.
        fn autosave(self: *Self) void {
            const every_s = preferences.editor(&self.app.preference_values).autosave_seconds;
            const now = sdl3.timer.getMillisecondsSinceInit();
            if (every_s == 0 or now -| self.autosaved_ms < @as(u64, every_s) * 1000) return;
            self.autosaved_ms = now;
            const scene = if (self.open_scene) |*open| open else return;
            if (scene.path == null or self.play_mode.playing() or self.typing() or !self.workspace.scene_unsaved) return;
            const game = if (self.game) |*loaded| loaded else return;
            scene.save(&self.app.world, game.sceneAccess(), self.entity_editor.roots(&self.app.world)) catch |err| return std.log.err("cannot autosave the scene: {t}", .{err});
            self.workspace.scene_unsaved = false;
            var message: [96]u8 = undefined;
            self.workspace.toast(std.fmt.bufPrint(&message, "Autosaved {s}", .{scene.name() orelse "the scene"}) catch "Autosaved");
        }

        fn launchEditorFrom(self: *Self, job: *Job) !void {
            var buffer: [64]u8 = undefined;
            // The layout first: the new editor reads it as it starts, before this one has closed.
            layout_file.save(self.gpa, self.preference_folders.global, &self.workspace.dock, &self.workspace.tabs, self.workspace.seen_plugin_panels.items);
            const placement = window_placement.Placement.of(self.app.window.window) orelse return job.launchEditor(&.{});
            try job.launchEditor(&.{ window_placement.flag, try placement.format(&buffer) });
        }

        /// Why the game can't be played, if it can't: the scene holds components of plugins that
        /// are turned off, whose code isn't there to run them. Text in `play_warning_buffer`.
        fn playWarning(self: *Self) ?[]const u8 {
            const game = if (self.game) |*loaded| loaded else return null;
            const off = self.plugin_switches.off();
            if (off.len == 0) return null;
            var count: usize = 0;
            var plugin: []const u8 = "";
            for (self.app.world.slots.items, 0..) |slot, index| {
                if (!slot.alive) continue;
                const entity = eggy.ecs.EntityId.init(@intCast(index), slot.generation);
                for (game.component_types, 0..) |info, component| {
                    if (!entities.isOff(off, info.owner) or !game.hasComponent(&self.app, entity, component)) continue;
                    count += 1;
                    plugin = info.owner;
                    break;
                }
            }
            if (count == 0) return null;
            return std.fmt.bufPrint(&self.play_warning_buffer, "Play mode warning: {d} entit{s} use{s} components of {s}, which is turned off. Turn it on, or remove them, to play.", .{ count, if (count == 1) "y" else "ies", if (count == 1) "s" else "", plugin }) catch "Play mode warning: the scene uses a turned-off plugin";
        }

        /// Play or Simulate: keep the scene, then run the game with nothing selected.
        fn startPlaying(self: *Self) void {
            // Not with components whose plugin is off: their code isn't there to run them.
            if (self.playWarning()) |warning| {
                self.workspace.playing = false;
                self.workspace.simulating = false;
                self.workspace.toast("Can't play: see the status bar");
                return std.log.warn("{s}", .{warning});
            }
            const game = if (self.game) |*loaded| loaded else {
                self.workspace.playing = false;
                self.workspace.simulating = false;
                return std.log.err("play: the game's library isn't loaded", .{});
            };
            // Start as the shipped game does, with no keys held and its clock at zero.
            self.app.input.cancel();
            self.app.time.reset();
            self.play_mode.play(self.gpa, &self.app, game, self.entity_editor.roots(&self.app.world), self.plugin_switches.off()) catch |err| {
                self.workspace.playing = false;
                self.workspace.simulating = false;
                return std.log.err("cannot start playing: {t}", .{err});
            };
            self.entity_editor.resetWorldView();
            self.workspace.playing = true;
            self.game_input = .{ .focused = true };
        }

        /// Stop: the game starts over on the scene kept by Play. Entities are made anew; the
        /// selection follows its entity there.
        fn stopPlaying(self: *Self) void {
            self.releaseViewportMouse();
            self.scene_view.camera.cancelNavigation();
            self.game_input.cancel(&self.app);
            self.workspace.playing = false;
            self.workspace.simulating = false;
            self.workspace.paused = false;
            if (!self.play_mode.playing()) return;
            const game = if (self.game) |*loaded| loaded else return;
            const place = self.entity_editor.selectionPlace(&self.app, game);
            self.play_mode.stop(&self.app, game, self.plugin_switches.off());
            self.entity_editor.reselect(&self.app, game, place);
        }

        /// Keep the selected entity's Transform as it is in play, for when play stops (Ctrl+Shift+K).
        fn keepSelectedTransform(self: *Self) void {
            const game = if (self.game) |*loaded| loaded else return;
            const entity = self.entity_editor.selected orelse return self.workspace.toast("Select an entity to keep its Transform");
            const kept = self.play_mode.keepTransform(&self.app, game, entity) catch |err| {
                std.log.err("cannot keep the Transform: {t}", .{err});
                return self.workspace.toast("Couldn't keep the Transform: see the Console");
            };
            self.workspace.toast(if (kept) "Kept its Transform for after Stop" else "Only an entity with a Transform from before Play can keep it");
        }

        /// The open scene's path, relative to the project; null with none.
        fn openScenePath(self: *const Self) ?[]const u8 {
            return if (self.open_scene) |*scene| scene.path else null;
        }

        fn openDiagnostic(self: *Self, source: @import("diagnostic.zig").Location) void {
            const opened = self.project orelse return;
            const file = std.fs.path.resolve(self.gpa, &.{ opened.dir, source.path }) catch |err| {
                std.log.err("cannot resolve source {s}: {t}", .{ source.path, err });
                return self.workspace.toast("Couldn't open the source: see the Console");
            };
            defer self.gpa.free(file);
            const choice = preferences.editor(&self.app.preference_values).code_editor;
            code_editor.openAt(self.gpa, choice, opened.dir, file, source.line, source.column) catch |err| {
                std.log.err("cannot open {s}:{d}:{d} in {t}: {t}. Pick another code editor in Edit > Preferences.", .{ source.path, source.line, source.column, choice, err });
                self.workspace.toast("Couldn't open the source: see the Console");
            };
        }

        /// Carry out what the Assets panel asked: open or start a scene, or show a file.
        fn applyAssetAction(self: *Self, action: assets.Action) void {
            const opened = self.project orelse return;
            switch (action) {
                .open_scene, .create_scene => self.openSceneStep(action) catch |err| std.log.err("cannot open the scene: {t}", .{err}),
                .open_ui_scene => |path| {
                    const env = self.uiDesignerEnv() orelse return;
                    self.ui_designer.open(env, path) catch |err| {
                        std.log.err("cannot open UI scene {s}: {t}", .{ path, err });
                        return self.workspace.toast("Couldn't open the UI scene: see the Console");
                    };
                    self.workspace.showUiDesigner() catch |err| std.log.err("cannot show the UI Designer: {t}", .{err});
                },
                .open_input_map => |path| self.openInputMap(path) catch |err| {
                    std.log.err("cannot open input map {s}: {t}", .{ path, err });
                    self.workspace.toast("Couldn't open the input map: see the Console");
                },
                .open_code => |path| {
                    const file = std.fs.path.join(self.gpa, &.{ opened.dir, path }) catch return;
                    defer self.gpa.free(file);
                    const choice = preferences.editor(&self.app.preference_values).code_editor;
                    code_editor.open(self.gpa, choice, opened.dir, file) catch |err| {
                        std.log.err("cannot open {s} in {t}: {t}. Pick another code editor in Edit > Preferences.", .{ path, choice, err });
                        self.workspace.toast("Couldn't open it: see the Console");
                    };
                },
                .reveal => |path| {
                    // A file shows as its folder.
                    const folder = std.fs.path.join(self.gpa, &.{ opened.dir, if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[0..slash] else "" }) catch return;
                    defer self.gpa.free(folder);
                    file_manager.showFolder(self.gpa, folder) catch |err| std.log.err("cannot show {s}: {t}", .{ path, err });
                },
                .copy_path => |path| {
                    @import("terminal_view.zig").copyToClipboard(path);
                    self.workspace.toast("Copied the path");
                },
                .create_folder, .create_file, .rename, .duplicate, .delete, .move_into => self.changeFiles(opened.dir, action) catch |err| {
                    std.log.err("cannot change the files: {t}", .{err});
                    self.workspace.toast("Couldn't do that: see the Console");
                },
            }
        }

        fn openInputMap(self: *Self, path: []const u8) !void {
            const opened = self.project orelse return error.NoProject;
            if (self.input_map_window) |window| {
                if (std.mem.eql(u8, window.path, path)) return window.window.popout.window.window.raise();
                if (window.document.modified()) {
                    window.view.confirm_close = true;
                    try window.window.popout.window.window.raise();
                    return error.UnsavedInputMap;
                }
                window.close(&self.app.graphics);
                self.input_map_window = null;
            }
            self.input_map_window = try input_map_asset.Window.open(self.gpa, &self.app.graphics, self.ui.font, opened.dir, path);
        }

        fn beforeAssetRemoval(self: *Self, path: []const u8) !void {
            const window = self.input_map_window orelse return;
            if (!window.affectedBy(path)) return;
            if (window.document.modified()) {
                window.view.confirm_close = true;
                return error.UnsavedInputMap;
            }
            window.close(&self.app.graphics);
            self.input_map_window = null;
        }

        /// Open the scene `action` names, or make a new one, as a step to undo: undoing it puts
        /// back the scene open before, as its world was.
        /// Internal host/extension bridge: `action` must be `.open_scene` or `.create_scene`
        /// with a borrowed project-relative path/folder; other tags are unreachable.
        /// Stops play, records pending edits, replaces entities/selection, refreshes assets,
        /// and owns before/after snapshots in history. No open scene is a no-op; missing
        /// library, allocation, scene parse, and disk errors propagate, possibly after effects.
        ///
        /// ```zig
        /// // Host has already handled any transition/unsaved-change policy.
        /// try host.openSceneStep(.{ .open_scene = "resources/scene/main.scene.zon" });
        /// ```
        pub fn openSceneStep(self: *Self, action: assets.Action) !void {
            self.stopPlaying();
            const scene = if (self.open_scene) |*open| open else return;
            const game = if (self.game) |*loaded| loaded else return error.NoGameLibrary;
            // What was open, with any change not recorded yet recorded first.
            const from_world = self.sceneText() orelse return error.NoGameLibrary;
            errdefer self.gpa.free(from_world);
            self.history.watch(try self.gpa.dupe(u8, from_world), std.math.maxInt(u64), false);
            const from = if (scene.path) |path| try self.gpa.dupe(u8, path) else null;
            errdefer if (from) |path| self.gpa.free(path);
            const from_saved = scene.saved_hash;

            switch (action) {
                .open_scene => |path| try scene.open(path, &self.app.world, game.sceneAccess()),
                .create_scene => |folder| try scene.create(folder, &self.app.world, game.sceneAccess()),
                else => unreachable,
            }
            self.entity_editor.resetWorldView();
            self.filesChanged();
            const to_world = self.sceneText() orelse return error.NoGameLibrary;
            self.history.setBaseline(try self.gpa.dupe(u8, to_world));
            self.history.record(.{ .open_scene = .{
                .from = from,
                .from_world = from_world,
                .from_saved = from_saved,
                .to = try self.gpa.dupe(u8, scene.path.?),
                .to_world = to_world,
                .to_saved = scene.saved_hash,
                .created = action == .create_scene,
            } });
        }

        /// Record a step when the dock's panels were rearranged (once let go, not mid-drag).
        fn watchLayout(self: *Self) void {
            if (self.workspace.dock.drag != .none) return;
            const now = layout_file.arrangement(&self.workspace.dock, &self.workspace.tabs);
            if (self.layout_step != null and now == self.layout_step_arrangement) return;
            const after = layout_file.snapshot(self.gpa, &self.workspace.dock, &self.workspace.tabs) catch return;
            if (self.layout_step) |before| self.history.record(.{ .layout = .{ .before = before, .after = self.gpa.dupe(u8, after) catch {
                self.gpa.free(before);
                self.layout_step = null;
                self.gpa.free(after);
                return;
            } } });
            self.layout_step = after;
            self.layout_step_arrangement = now;
        }

        /// The Assets panel's file changes: new folders, renaming, duplicating, deleting (into
        /// the project's trash). The open scene follows its file.
        /// Internal host/extension bridge: `project_dir` is the current project's folder;
        /// action paths are project-relative and borrowed only for this call. Supports only
        /// create_folder/create_file/rename/duplicate/delete/move_into; other tags are unreachable.
        /// Ctrl during move_into copies instead. Mutates files and the asset catalog and records undo;
        /// refresh/remake is scheduled even on errors. I/O/allocation/document errors propagate
        /// and can occur after mutation, so this is not an atomic batch operation.
        ///
        /// ```zig
        /// try host.changeFiles(opened.dir, .{ .create_folder = "resources" });
        /// ```
        pub fn changeFiles(self: *Self, project_dir: []const u8, action: assets.Action) !void {
            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.io();
            var files = try std.Io.Dir.cwd().openDir(io, project_dir, .{});
            defer files.close(io);
            defer {
                self.assets_panel.refreshSoon();
                self.syncAssets();
                // Input-map defaults load on the next start, without rebuilding live scene instances.
                if (action != .create_file or !std.mem.endsWith(u8, action.create_file.file_type.extension, eggy.input.asset.extension))
                    self.app.sceneInstances().remakeAll();
            }
            switch (action) {
                .create_folder => |parent| self.history.record(.{ .create = .{ .path = try file_ops.createFolder(self.gpa, io, files, parent) } }),
                .create_file => |creation| {
                    try self.history.reserve();
                    const path = try file_ops.createFile(self.gpa, io, files, creation.folder, creation.file_type);
                    self.history.record(.{ .create = .{ .path = path } });
                    if (std.mem.endsWith(u8, path, eggy.input.asset.extension)) {
                        if (self.input_map_window == null or !self.input_map_window.?.document.modified()) {
                            try self.openInputMap(path);
                        } else self.workspace.toast("Created input map; save or close the open map to edit it");
                    }
                },
                .rename => |change| {
                    try self.keepRefsValid(io, files);
                    const renamed = try file_ops.rename(self.gpa, io, files, change.path, change.name);
                    self.assetsMoved(change.path, renamed);
                    if (self.open_scene) |*scene| scene.moved(change.path, renamed);
                    self.ui_designer.moved(change.path, renamed);
                    self.history.record(.{ .rename = .{ .from = try self.gpa.dupe(u8, change.path), .to = renamed } });
                    if (self.input_map_window) |window| try window.moved(change.path, renamed);
                },
                .duplicate => |path| {
                    const copy = try file_ops.duplicate(self.gpa, io, files, path);
                    self.assetsCopied(path, copy);
                    self.history.record(.{ .create = .{ .path = copy } });
                },
                // Dragged onto a folder: moved, or copied with Ctrl held.
                .move_into => |change| if (sdl3.keyboard.getModState().controlDown()) {
                    const copy = try file_ops.copyInto(self.gpa, io, files, change.path, change.folder);
                    self.assetsCopied(change.path, copy);
                    self.history.record(.{ .create = .{ .path = copy } });
                } else {
                    try self.keepRefsValid(io, files);
                    const moved = try file_ops.moveInto(self.gpa, io, files, change.path, change.folder);
                    self.assetsMoved(change.path, moved);
                    if (self.open_scene) |*scene| scene.moved(change.path, moved);
                    self.ui_designer.moved(change.path, moved);
                    self.history.record(.{ .rename = .{ .from = try self.gpa.dupe(u8, change.path), .to = moved } });
                    if (self.input_map_window) |window| try window.moved(change.path, moved);
                },
                .delete => |path| {
                    try self.beforeAssetRemoval(path);
                    try self.keepRefsValid(io, files);
                    const trashed = try file_ops.trash(self.gpa, io, files, path);
                    self.assetsMoved(path, trashed);
                    if (self.open_scene) |*scene| scene.deleted(path);
                    self.ui_designer.deleted(path);
                    self.history.record(.{ .delete = .{ .path = try self.gpa.dupe(u8, path), .trashed = trashed } });
                    var message: [96]u8 = undefined;
                    self.workspace.toast(std.fmt.bufPrint(&message, "Moved {s} to the trash", .{std.fs.path.basename(path)}) catch "Moved to the trash");
                },
                else => unreachable,
            }
        }

        /// The world as a scene file's text (caller-owned); null without a game library.
        fn sceneText(self: *Self) ?[]u8 {
            if (self.game == null) return null;
            // A pose from the Animation panel is not part of the scene: lift it while capturing.
            const env = self.animationEnv();
            const was_posed = if (env) |found| self.animation.liftPose(found) else false;
            defer if (env) |found| self.animation.restorePose(found, was_posed);
            return extensions.snapshot(self) catch |err| {
                std.log.err("cannot capture the editor scene: {t}", .{err});
                return null;
            };
        }

        /// What the Animation panel works on; null without a project or the game's library.
        fn animationEnv(self: *Self) ?animation_dock.Env {
            const opened = self.project orelse return null;
            return .{
                .game = self.gamePtr() orelse return null,
                .app = &self.app,
                .assets = self.project_assets orelse return null,
                .project_dir = opened.dir,
                .history = &self.history,
                .selected = self.entity_editor.selected,
                .playing = self.play_mode.playing(),
                .now_ms = self.workspace.time_ms,
            };
        }

        fn uiDesignerEnv(self: *Self) ?ui_designer.Env {
            const opened = self.project orelse return null;
            return .{
                .gpa = self.gpa,
                .app = &self.app,
                .assets = self.project_assets orelse return null,
                .project_dir = opened.dir,
                .history = &self.history,
                .widgets = if (self.game) |game| game.ui_widgets else &.{},
                .now_ms = self.workspace.time_ms,
            };
        }

        /// Whether a text field has the keyboard somewhere: changes made by typing wait for it.
        fn typing(self: *Self) bool {
            for (0..self.pageCount()) |index| if (self.page(index).wants_text) return true;
            return false;
        }

        /// Clipboard edits are discrete undo steps, not part of a pending field edit.
        fn applyEntityCommands(self: *Self) void {
            if (self.entity_editor.pending_visibility) |entity| {
                self.entity_editor.pending_visibility = null;
                self.toggleEntityVisibility(entity) catch |err| {
                    std.log.err("cannot change editor visibility: {t}", .{err});
                    self.workspace.toast("Couldn't change visibility: see the Console");
                };
            }
            if (self.entity_editor.pending_extract) |entity| {
                self.entity_editor.pending_extract = null;
                self.extractEntityTree(entity) catch |err| {
                    std.log.err("cannot extract entity tree: {t}", .{err});
                    self.workspace.toast(if (err == error.CrossSceneEntityReference) "Extraction needs all entity references inside the tree" else "Couldn't extract tree: original kept; see the Console");
                };
            }
            const request = self.entity_editor.pending_paste orelse return;
            self.entity_editor.pending_paste = null;
            self.pasteEntityTree(request.beside) catch |err| {
                std.log.err("cannot paste entity tree: {t}", .{err});
                self.workspace.toast("Couldn't paste tree: see the Console");
            };
        }

        fn toggleEntityVisibility(self: *Self, entity: eggy.ecs.EntityId) !void {
            if (self.play_mode.playing()) return error.NotEditing;
            const game = self.gamePtr() orelse return error.NoGameLibrary;
            self.history.watch(self.sceneText() orelse return error.CannotCaptureScene, std.math.maxInt(u64), false);
            const place = self.entity_editor.entityPlace(&self.app, game, entity) orelse return error.EntityNotSaved;
            try self.history.reserve();
            const before = self.entity_editor.view_state.hidden.contains(entity);
            try self.entity_editor.view_state.setHidden(entity, !before);
            self.history.record(.{ .entity_visibility = .{ .place = place, .before = before, .after = !before } });
            // Invalidate last frame's pick/gizmo geometry before another input event can use it.
            self.scene_view.drawn = &.{};
            self.scene_2d.drawn = &.{};
            self.scene_view.gizmo = null;
            self.scene_view.drag = null;
            self.scene_view.hot = null;
        }

        fn pasteEntityTree(self: *Self, beside: ?eggy.ecs.EntityId) !void {
            if (self.play_mode.playing()) return error.NotEditing;
            const game = self.gamePtr() orelse return error.NoGameLibrary;
            const before = self.sceneText() orelse return error.CannotCaptureScene;
            errdefer self.gpa.free(before);
            self.history.watch(try self.gpa.dupe(u8, before), std.math.maxInt(u64), false);
            try self.history.reserve();
            const selection = self.entity_editor.selected;
            const selection_before = self.entity_editor.selectionPlace(&self.app, game);
            const made = (try self.entity_editor.paste(&self.app, game, beside)) orelse return;
            errdefer {
                self.app.world.despawnRecursive(made);
                self.entity_editor.selected = selection;
            }
            const after = self.sceneText() orelse return error.CannotCaptureScene;
            errdefer self.gpa.free(after);
            const baseline = try self.gpa.dupe(u8, after);
            self.history.record(.{ .scene = .{
                .before = before,
                .after = after,
                .selection_recorded = true,
                .selection_before = selection_before,
                .selection_after = self.entity_editor.selectionPlace(&self.app, game),
            } });
            self.history.setBaseline(baseline);
        }

        fn extractEntityTree(self: *Self, entity: eggy.ecs.EntityId) !void {
            if (self.play_mode.playing()) return error.NotEditing;
            const opened = self.project orelse return error.NoProject;
            const game = self.gamePtr() orelse return error.NoGameLibrary;
            const before = self.sceneText() orelse return error.CannotCaptureScene;
            errdefer self.gpa.free(before);
            const selection_before = self.entity_editor.selectionPlace(&self.app, game);
            self.history.watch(try self.gpa.dupe(u8, before), std.math.maxInt(u64), false);
            try self.history.reserve();
            const steps = try self.gpa.alloc(history_zig.Step, 2);
            errdefer self.gpa.free(steps);
            const label = try self.gpa.dupe(u8, "extracting an entity tree");
            errdefer self.gpa.free(label);

            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.io();
            var files = try std.Io.Dir.cwd().openDir(io, opened.dir, .{});
            defer files.close(io);
            const prepared = try extraction.prepare(self.gpa, io, files, &self.app.world, game.sceneAccess(), entity, eggy.project.scenes_dir, self.project_assets orelse return error.NoProject);
            errdefer {
                prepared.rollback(io, files, &self.app.world);
                self.gpa.free(prepared.path);
            }
            try self.entity_editor.placeReplacement(&self.app.world, prepared.instance, entity);
            const after = try self.entity_editor.textWithout(&self.app.world, game.sceneAccess(), entity);
            errdefer self.gpa.free(after);
            const baseline = try self.gpa.dupe(u8, after);

            // All files and history allocations succeeded; only now remove the original tree.
            steps[0] = .{ .create = .{ .path = prepared.path } };
            steps[1] = .{ .scene = .{
                .before = before,
                .after = after,
                .selection_recorded = true,
                .selection_before = selection_before,
                .selection_after = selection_before,
            } };
            self.app.world.despawnRecursive(entity);
            self.entity_editor.selected = prepared.instance;
            self.history.record(.{ .group = .{ .label = label, .steps = steps } });
            self.history.setBaseline(baseline);
            self.filesChanged();
            self.workspace.toast("Extracted tree to resources/scene");
        }

        /// Edit > Undo or Redo: carry the step back (`.undo`) or out again (`.redo`).
        fn undoOrRedo(self: *Self, direction: eggy.Direction) void {
            if (self.input_settings) |settings| settings.recordPending(&self.history) catch |err| {
                std.log.err("cannot record input mappings before undo: {t}", .{err});
                return self.workspace.toast("Couldn't record input mappings: see the Console");
            };
            // Steps are the scene's, not a play's: stop first.
            self.stopPlaying();
            // A change not recorded yet (typing just now) becomes a step first.
            if (direction == .undo) {
                if (self.sceneText()) |text| self.history.watch(text, std.math.maxInt(u64), false);
                self.watchLayout();
            }
            const step = self.history.peek(direction) orelse {
                return self.workspace.toast(if (direction == .undo) "Nothing to undo" else "Nothing to redo");
            };
            const description = step.describe();
            _ = self.history.apply(direction, self, carry) catch |err| {
                std.log.err("cannot {s} {s}: {t}", .{ @tagName(direction), description, err });
                return self.workspace.toast("Couldn't do that: see the Console");
            };
            var message: [64]u8 = undefined;
            self.workspace.toast(std.fmt.bufPrint(&message, "{s} {s}", .{ if (direction == .undo) "Undid" else "Redid", description }) catch "Done");
        }

        /// Apply one direction, filling in where files went. History owns group traversal.
        /// Internal leaf handler for `History.apply/cancelGroup`; never pass `.group`.
        /// Borrows/mutates a history-owned step, using its allocator-compatible paths/text;
        /// `.undo` restores before-state, `.redo` reapplies it. Requires an open project and,
        /// for scene leaves, its loaded game. May recreate entities, write files/preferences,
        /// update trash locations, and refresh assets; errors propagate with possible effects.
        ///
        /// ```zig
        /// // History owns ordering, group traversal, and moving entries between stacks:
        /// _ = try host.history.apply(.undo, host, Self.carry);
        /// ```
        pub fn carry(self: *Self, step: *history_zig.Step, direction: eggy.Direction) !void {
            const back = direction == .undo;
            const opened = self.project orelse return error.NoProject;
            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.io();
            var files = try std.Io.Dir.cwd().openDir(io, opened.dir, .{});
            defer files.close(io);
            defer if (step.* == .input_map or step.* == .animation_clip or step.* == .ui_scene) self.assets_panel.refreshSoon() else if (step.* != .entity_visibility) self.filesChanged();
            switch (step.*) {
                .group => unreachable,
                .entity_visibility => |change| {
                    const game = self.gamePtr() orelse return error.NoGame;
                    var captured = try @import("entities/snapshot.zig").capture(self.gpa, &self.app.world, game.sceneAccess(), self.entity_editor.roots(&self.app.world));
                    defer captured.deinit();
                    if (change.place >= captured.sources.len) return error.EntityNotSaved;
                    try self.entity_editor.view_state.setHidden(captured.sources[change.place], if (back) change.before else change.after);
                    self.scene_view.drawn = &.{};
                    self.scene_2d.drawn = &.{};
                    self.scene_view.gizmo = null;
                },
                .scene => |change| {
                    const game = if (self.game) |*loaded| loaded else return error.NoGame;
                    const text = change.value(direction);
                    const source = try self.gpa.dupeZ(u8, text);
                    defer self.gpa.free(source);
                    var scene = try eggy.scene.Scene.parse(self.gpa, source);
                    defer scene.deinit();
                    // The world is made anew: the selection follows its entity's place.
                    const place = if (change.selection_recorded)
                        (if (back) change.selection_before else change.selection_after)
                    else
                        self.entity_editor.selectionPlace(&self.app, game);
                    game.restart(&self.app, &scene, self.plugin_switches.off(), .discard);
                    self.entity_editor.reselect(&self.app, game, place);
                    self.history.setBaseline(try self.gpa.dupe(u8, text));
                },
                .rename => |change| {
                    const from = if (back) change.to else change.from;
                    const to = if (back) change.from else change.to;
                    try file_ops.move(io, files, from, to);
                    self.assetsMoved(from, to);
                    if (self.open_scene) |*scene| scene.moved(from, to);
                    self.ui_designer.moved(from, to);
                    if (self.input_map_window) |window| try window.moved(from, to);
                },
                .delete => |*change| if (back) {
                    try file_ops.restore(io, files, change.trashed, change.path);
                    self.assetsMoved(change.trashed, change.path);
                } else {
                    try self.beforeAssetRemoval(change.path);
                    const trashed = try file_ops.trash(self.gpa, io, files, change.path);
                    self.assetsMoved(change.path, trashed);
                    self.gpa.free(change.trashed);
                    change.trashed = trashed;
                    if (self.open_scene) |*scene| scene.deleted(change.path);
                    self.ui_designer.deleted(change.path);
                },
                .create => |*change| if (back) {
                    try self.beforeAssetRemoval(change.path);
                    const trashed = try file_ops.trash(self.gpa, io, files, change.path);
                    self.assetsMoved(change.path, trashed);
                    if (change.trashed) |old| self.gpa.free(old);
                    change.trashed = trashed;
                } else if (change.trashed) |trashed| {
                    try file_ops.restore(io, files, trashed, change.path);
                    self.assetsMoved(trashed, change.path);
                    self.gpa.free(trashed);
                    change.trashed = null;
                },
                .plugin => |change| try self.switchPlugin(change.key, if (back) !change.on else change.on),
                .preference => |change| {
                    try self.app.preference_values.set(change.layer, change.key, change.field, if (back) change.before else change.after);
                    try preferences.save(self.gpa, &self.app.preference_values, self.preference_folders, change.layer, change.key);
                },
                .project_settings => |change| {
                    try files.writeFile(io, .{ .sub_path = eggy.project.file_name, .data = change.value(direction) });
                    if (self.project_settings) |settings| try settings.reload();
                    // Installing or uninstalling a plugin, undone or redone, builds the game again.
                    if (plugin_manager.pluginsDiffer(self.gpa, change.before, change.after)) {
                        if (self.plugins_window) |window| window.reloadInstalled();
                        self.rebuildForPlugins();
                    }
                    self.setGraphicsDefaults(try project_settings_zig.graphicsIn(self.gpa, change.value(direction)));
                    self.refreshProjectIcon();
                },
                .plugins => |change| {
                    try files.writeFile(io, .{ .sub_path = eggy.project.file_name, .data = change.project.value(direction) });
                    if (change.package) |package| try files.writeFile(io, .{ .sub_path = "build.zig.zon", .data = package.value(direction) });
                    if (self.project_settings) |settings| try settings.reload();
                    if (self.plugins_window) |window| window.reloadInstalled();
                    self.rebuildForPlugins();
                },
                .input_bindings => |change| {
                    const settings = self.input_settings orelse return error.NoProject;
                    try settings.restore(change.value(direction));
                },
                .input_map => |change| {
                    const expected = if (back) change.text.after else change.text.before;
                    if (self.input_map_window) |window| {
                        if (std.mem.eql(u8, window.path, change.path)) {
                            try window.restore(io, files, expected, change.text.value(direction));
                            return;
                        }
                    }
                    var restored = try input_map_asset.restoreFile(self.gpa, io, files, change.path, expected, change.text.value(direction));
                    restored.deinit();
                },
                .animation_clip => |change| {
                    const env = self.animationEnv() orelse return error.NoGame;
                    try self.animation.restore(env, io, files, change.path, change.text.value(direction));
                },
                .ui_scene => |change| {
                    const env = self.uiDesignerEnv() orelse return error.NoProject;
                    try self.ui_designer.restore(env, io, files, change.path, change.text.value(direction));
                },
                .layout => |change| {
                    const text = change.value(direction);
                    if (!layout_file.restore(self.gpa, text, &self.workspace.dock, &self.workspace.tabs)) return error.ParseZon;
                    if (self.layout_step) |old| self.gpa.free(old);
                    self.layout_step = try self.gpa.dupe(u8, text);
                    self.layout_step_arrangement = layout_file.arrangement(&self.workspace.dock, &self.workspace.tabs);
                },
                .open_scene => |*change| {
                    const game = if (self.game) |*loaded| loaded else return error.NoGame;
                    const scene = if (self.open_scene) |*open| open else return error.NoProject;
                    // A new scene's file goes with it, and comes back with it.
                    if (change.created) if (back) {
                        if (change.trashed) |old| self.gpa.free(old);
                        change.trashed = null;
                        change.trashed = try file_ops.trash(self.gpa, io, files, change.to);
                        self.assetsMoved(change.to, change.trashed.?);
                    } else if (change.trashed) |trashed| {
                        try file_ops.restore(io, files, trashed, change.to);
                        self.assetsMoved(trashed, change.to);
                        self.gpa.free(trashed);
                        change.trashed = null;
                    };
                    const text = if (back) change.from_world else change.to_world;
                    const source = try self.gpa.dupeZ(u8, text);
                    defer self.gpa.free(source);
                    var world = try eggy.scene.Scene.parse(self.gpa, source);
                    defer world.deinit();
                    game.restart(&self.app, &world, self.plugin_switches.off(), .discard);
                    try scene.reopenAs(if (back) change.from else change.to, if (back) change.from_saved else change.to_saved);
                    self.entity_editor.resetWorldView();
                    self.history.setBaseline(try self.gpa.dupe(u8, text));
                },
            }
        }

        /// File > Save (Ctrl+S): write the world to the open scene, or a new one.
        fn saveScene(self: *Self) void {
            // What happened while playing isn't the scene: stop first.
            if (self.play_mode.playing()) return std.log.info("save: stop playing first; Stop puts the scene back as it was", .{});
            const scene = if (self.open_scene) |*open| open else return std.log.info("save: open a project first; scenes are kept in it", .{});
            const game = if (self.game) |*loaded| loaded else return std.log.err("save: the game's library isn't loaded, so its components can't be saved", .{});
            scene.save(&self.app.world, game.sceneAccess(), self.entity_editor.roots(&self.app.world)) catch |err| {
                self.workspace.toast("Couldn't save the scene: see the Console");
                return std.log.err("cannot save the scene: {t}", .{err});
            };
            var message: [96]u8 = undefined;
            self.workspace.toast(std.fmt.bufPrint(&message, "Saved {s}", .{scene.name() orelse "the scene"}) catch "Saved");
            self.workspace.scene_unsaved = false;
        }

        /// Checked save entry point used by synchronous editor-extension requests.
        /// Internal bridge, not the plugin-facing API: rejects play with `NotEditing`,
        /// missing project with `NoProject`, or absent library with `NoGameLibrary`.
        /// Saves the current root order to the scene (creating a file if needed) and clears
        /// the status asterisk only on success; scene/I/O/allocation errors propagate.
        ///
        /// ```zig
        /// // Host implementation of an already-validated extension save request:
        /// try host.saveSceneForExtension();
        /// ```
        pub fn saveSceneForExtension(self: *Self) !void {
            if (self.play_mode.playing()) return error.NotEditing;
            const scene = if (self.open_scene) |*open| open else return error.NoProject;
            const game = if (self.game) |*loaded| loaded else return error.NoGameLibrary;
            try scene.save(&self.app.world, game.sceneAccess(), self.entity_editor.roots(&self.app.world));
            self.workspace.scene_unsaved = false;
        }

        /// Put the project's icon (as `eggy.zon` now has it) on the editor's main window and
        /// Preferences, the window it is chosen in; others take it as they next open.
        fn refreshProjectIcon(self: *Self) void {
            const opened = self.project orelse return;
            useProjectIcon(self.gpa, opened.dir);
            icon.apply(self.app.window.window);
            if (self.preferences_window) |window| icon.apply(window.window.popout.window.window);
        }

        /// File > Project Settings (and Export's button): Preferences on its Project section.
        fn showProjectSettings(self: *Self) !void {
            if (self.project == null) return;
            self.openPreferences();
            const window = self.preferences_window orelse return;
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            window.show(try self.preferenceSections(arena.allocator()), project_section);
        }

        /// Open Edit > Preferences, with the open project's `eggy.zon` for its Project section.
        fn openPreferences(self: *Self) void {
            if (self.preferences_window != null) return;
            self.preferences_window = preferences.PreferencesWindow.open(self.gpa, &self.app.graphics, self.ui.font) catch |err| {
                std.log.err("cannot open Preferences: {t}", .{err});
                return;
            };
            if (self.project) |opened| self.project_settings = ProjectSettings.open(self.gpa, opened.dir, self.app.graphics.capabilities()) catch |err| blk: {
                std.log.err("cannot read {s}: {t}", .{ eggy.project.file_name, err });
                break :blk null;
            };
        }

        /// Make `wanted` the project's graphics defaults, which the editor's view uses unless the
        /// user chose their own in Preferences. Backend and GPU changes wait for a restart.
        /// A default this machine can't use is said in the Project section and the log, not hidden.
        fn setGraphicsDefaults(self: *Self, wanted: eggy.render_settings.Settings) void {
            _ = self.app.setGraphicsDefaults(wanted) catch |err| {
                std.log.err("cannot use the project's graphics defaults: {t}", .{err});
                if (self.project_settings) |settings| settings.graphics.report(err);
            };
        }

        fn closePreferences(self: *Self) void {
            if (self.preferences_window) |window| window.close(&self.app.graphics);
            self.preferences_window = null;
            if (self.project_settings) |settings| settings.close();
            self.project_settings = null;
        }

        /// The Preferences window's sections: the editor's, then (with a project) its eggy.zon,
        /// each plugin's that has any, the game's titled after the project. In `arena`.
        fn preferenceSections(self: *Self, arena: std.mem.Allocator) ![]const preferences.Section {
            var sections: std.ArrayList(preferences.Section) = .empty;
            try sections.append(arena, .{ .title = "Editor", .subtitle = "How the editor looks and behaves.", .content = .{ .preferences = preferences.editor_manifest } });
            try sections.append(arena, .{ .title = "Graphics", .subtitle = "How the editor draws its view.", .content = .{ .graphics = &self.app } });
            // Plugins' switches and preferences are the project's: without one, there is nowhere to
            // keep them.
            if (self.project == null) return sections.items;
            if (self.project_settings) |settings| try sections.append(arena, .{ .title = project_section, .subtitle = "This project's title, version and how its game starts.", .content = .{ .project = settings } });
            const game = if (self.game) |*loaded| loaded else return sections.items;
            // Every plugin but the game, which can't be turned off.
            const plugins = try arena.alloc(preferences.Plugin, game.plugin_keys.len -| 1);
            for (plugins, game.plugin_keys[@min(1, game.plugin_keys.len)..]) |*plugin, key| plugin.* = .{ .key = key, .title = try preferences.displayName(arena, key), .on = self.plugin_switches.isOn(key) };
            try sections.append(arena, .{ .title = "Plugins", .subtitle = "Turn this project's plugins on or off.", .content = .{ .plugins = plugins } });
            for (game.preference_manifests) |manifest| {
                if (std.mem.eql(u8, manifest.key, "game")) {
                    try sections.append(arena, .{ .title = if (self.project) |opened| opened.title else "Game", .subtitle = "Your game's own preferences.", .content = .{ .preferences = manifest } });
                } else {
                    try sections.append(arena, .{ .title = try preferences.displayName(arena, manifest.key), .subtitle = try std.fmt.allocPrint(arena, "From the {s} plugin.", .{manifest.key}), .content = .{ .preferences = manifest } });
                }
            }
            return sections.items;
        }

        /// Help > DevTools (F12): open the DevTools window, or close it.
        fn toggleDevtools(self: *Self) void {
            if (self.devtools_window) |window| {
                window.close(&self.app.graphics);
                self.devtools_window = null;
                self.workspace.devtools = null;
                self.frame_start_ns = 0;
                return;
            }
            self.devtools_window = DevtoolsWindow.open(self.gpa, &self.app.graphics, self.ui.font) catch |err| {
                std.log.err("cannot open DevTools: {t}", .{err});
                return;
            };
        }

        /// Hide or show the main window and its pop-outs.
        fn setHidden(self: *Self, hidden: bool) void {
            if (hidden == self.hidden) return;
            self.hidden = hidden;
            const main = self.app.window.window;
            (if (hidden) main.hide() else main.show()) catch {};
            for (self.popouts) |popout| if (popout) |open| {
                (if (hidden) open.window.window.hide() else open.window.window.show()) catch {};
            };
        }

        /// Draw window `slot` into `surface`: its UI with the pages' (`pages`) in their panels,
        /// and the scene texture inside the Scene panel if that's in this window.
        fn present(self: *Self, slot: Slot, surface: *eggy.Surface, overlay: *weeoui_vitellus.Renderer, viewport: ui.Rect, pages: []const []const ui.Vertex) !void {
            const drawn = try self.workspace.draw(slot, &self.ui, pages);

            // Render the scene offscreen at the Scene panel's pixel size.
            const frame = try surface.beginFrame();
            const scene_px = if (self.workspace.placed.scene) |placed| if (placed.slot == slot) eggy.game_ui.pixelRect(placed.rect, viewport, frame.extent) else null else null;
            // Nothing at all without a camera to see it through.
            const preview_px = if (scene_px != null and self.scene_view.preview != null) eggy.game_ui.pixelRect(scene_view.previewRect(self.workspace.placed.scene.?.rect), viewport, frame.extent) else null;
            if (scene_px) |rect| {
                const gathered = if (self.game) |*game| game.gatherMeshes(&self.app, self.drawables) else self.drawables[0..0];
                if (self.game) |*game| game.gatherLights(&self.app, &self.app.graphics.lights);
                // UI scenes on entities: billboards in the scene, and screens over it while playing.
                if (self.game) |*game| game.gatherUiScenes(&self.app);
                self.billboards = .{ .state = &self.app.ui_scenes, .resources = self.app.resources(), .billboards = if (self.game != null) self.app.ui_scenes.shownBillboards() else &.{}, .time_ms = sdl3.timer.getMillisecondsSinceInit() };
                self.app.graphics.ui_billboards = &self.billboards;
                if (!self.play_mode.playing()) self.entity_editor.view_state.visibleLights(&self.app.world, &self.app.graphics.lights);
                const visible = if (self.play_mode.playing()) gathered else self.entity_editor.view_state.visibleMeshes(&self.app.world, gathered);
                const meshes = if (self.scene_view.no_camera) visible[0..0] else visible;
                // Lights and cameras get stand-ins after the game's meshes, only through the panel's own camera.
                const shown = if (self.game) |*game| if (!self.scene_view.throughGameCamera()) block: {
                    const count = scene_view.stand_ins.append(game, &self.app, &self.app.graphics.lights, self.drawables, meshes.len);
                    const stand_ins = self.entity_editor.view_state.visibleMeshes(&self.app.world, self.drawables[meshes.len..count]);
                    break :block self.drawables[0 .. meshes.len + stand_ins.len];
                } else meshes else meshes;
                self.scene_view.drawn = shown;
                // The ground grid only through the panel's own camera, not the game's.
                try self.scene.render(&self.app.graphics, frame.cmd, pixelSize(rect), shown, self.scene_view.view, self.entity_editor.selected, !self.scene_view.throughGameCamera());
                const game_overlay = self.build_window == null and self.play_mode.playing() and !self.workspace.simulating;
                const has_screens = self.app.ui_scenes.screen_count != 0;
                const has_game_overlay = game_overlay and if (self.game) |*game| game.hasDraw() or game.hasGameUi() or has_screens else false;
                if (has_game_overlay or self.app.debug_draw.line_count != 0 or self.app.debug_draw.label_count != 0) {
                    const logical = self.workspace.placed.scene.?.rect;
                    const draw_context = eggy.DrawContext{
                        .cmd = frame.cmd,
                        .target = try self.scene.beginOverlay(frame.cmd),
                        .extent_px = pixelSize(rect),
                        .viewport = .{ .x = 0, .y = 0, .w = logical.w, .h = logical.h },
                        .color_format = self.app.graphics.color_format,
                        .frame_owner = surface,
                        .frame_slot = surface.slot,
                    };
                    if (has_game_overlay) if (self.game) |*game| {
                        game.draw(&self.app, draw_context);
                        if (game.hasGameUi() or has_screens) {
                            const layer = try self.app.gameUi();
                            layer.begin(draw_context, sdl3.timer.getMillisecondsSinceInit());
                            game.gameUi(&self.app, &layer.context);
                            if (try layer.render(draw_context)) self.app.input.cancel();
                            try layer.syncClipboard();
                        }
                    };
                    try self.app.drawDebug(draw_context, self.scene_view.view);
                    try self.scene.endOverlay(frame.cmd);
                }
                // The selected camera's view, unoutlined. Rendering sorts `meshes`, which is no matter.
                if (preview_px) |inset| try self.camera_preview.render(&self.app.graphics, frame.cmd, pixelSize(inset), meshes, self.scene_view.preview.?, null, false);
            }

            const model_px = if (drawn.asset_preview_at != null) try self.renderModelPreview(frame.cmd, viewport, frame.extent) else null;
            const flat_px = if (drawn.page_starts[panels.scene_2d_page] != null) try self.renderScene2d(frame.cmd, viewport, frame.extent, scene_px != null) else null;

            // The UI, with each texture drawn in where its panel was painted (the scene after
            // what is under the Scene panel, the model after the Asset Preview's page, the 2D
            // view under its grid), so whatever covers them stays on top.
            try overlay.upload(frame.cmd, self.ui.font, drawn.vertices, viewport);
            try frame.cmd.beginRenderPass(.{ .label = "editor ui", .color_attachments = &.{.{ .view = frame.target, .load_op = .load, .store_op = .store }} });
            const Insert = struct { at: usize, texture: enum { scene, model, flat } };
            var inserts: [3]Insert = undefined;
            var insert_count: usize = 0;
            if (scene_px != null) {
                inserts[insert_count] = .{ .at = drawn.scene_at, .texture = .scene };
                insert_count += 1;
            }
            if (model_px != null) {
                inserts[insert_count] = .{ .at = drawn.asset_preview_at.?, .texture = .model };
                insert_count += 1;
            }
            if (flat_px != null) {
                inserts[insert_count] = .{ .at = drawn.page_starts[panels.scene_2d_page].? + self.scene_2d.mark.?, .texture = .flat };
                insert_count += 1;
            }
            std.mem.sort(Insert, inserts[0..insert_count], {}, struct {
                fn before(_: void, a: Insert, b: Insert) bool {
                    return a.at < b.at;
                }
            }.before);
            var from: usize = 0;
            for (inserts[0..insert_count]) |insert| {
                const at = @min(insert.at, drawn.vertices.len);
                overlay.draw(frame.cmd, frame.extent, from, at - from);
                switch (insert.texture) {
                    .scene => {
                        self.scene.draw(frame.cmd, scene_px.?, frame.extent);
                        if (preview_px) |inset| self.camera_preview.draw(frame.cmd, inset, frame.extent);
                    },
                    .model => self.model_view.?.draw(frame.cmd, model_px.?, frame.extent),
                    .flat => self.scene_2d_view.?.draw(frame.cmd, flat_px.?, frame.extent),
                }
                from = at;
            }
            overlay.draw(frame.cmd, frame.extent, from, drawn.vertices.len - from);
            frame.cmd.endRenderPass();
            try surface.endFrame(self.app.graphics.queue, frame);
        }

        /// Render the model the Asset Preview panel shows, if any, alone under the default
        /// light; returns where in the window's pixels it goes.
        fn renderModelPreview(self: *Self, cmd: eggy.vit.CommandBuffer, viewport: ui.Rect, extent: eggy.vit.Extent2D) !?ui.Rect {
            const shot = self.asset_preview.model.shot() orelse return null;
            const rect = eggy.game_ui.pixelRect(shot.rect, viewport, extent);
            if (self.model_view == null) self.model_view = try eggy.SceneTexture.init(&self.app.graphics);
            // None of the scene's lights, billboards or sprites, then the scene's back.
            const graphics = &self.app.graphics;
            const scene_lights = graphics.lights;
            const scene_billboards = graphics.ui_billboards;
            const scene_sprites = graphics.world_draw;
            defer {
                graphics.lights = scene_lights;
                graphics.ui_billboards = scene_billboards;
                graphics.world_draw = scene_sprites;
            }
            graphics.lights = .{ .ambient = .{ 1, 1, 1, 0.25 } };
            graphics.ui_billboards = null;
            graphics.world_draw = null;
            try self.model_view.?.render(graphics, cmd, pixelSize(rect), @as(*[1]eggy.mesh.Drawable, shot.drawable), shot.view, null, false);
            return rect;
        }

        /// Render the world flat for the 2D Scene panel, the selection outlined; returns where
        /// in the window's pixels it goes. `scene_lit` says the Scene panel gathered the lights
        /// and billboards this frame; without it the 2D view gathers the lights and shows none.
        fn renderScene2d(self: *Self, cmd: eggy.vit.CommandBuffer, viewport: ui.Rect, extent: eggy.vit.Extent2D, scene_lit: bool) !?ui.Rect {
            const shot = self.scene_2d.shot() orelse return null;
            const game = if (self.game) |*loaded| loaded else return null;
            const rect = eggy.game_ui.pixelRect(shot.rect, viewport, extent);
            if (self.scene_2d_view == null) self.scene_2d_view = try eggy.SceneTexture.init(&self.app.graphics);
            if (!scene_lit) {
                game.gatherLights(&self.app, &self.app.graphics.lights);
                self.app.graphics.ui_billboards = null;
            }
            const gathered = game.gatherMeshes(&self.app, self.drawables_2d);
            const shown = if (self.play_mode.playing()) gathered else self.entity_editor.view_state.visibleMeshes(&self.app.world, gathered);
            self.scene_2d.drawn = shown;
            try self.scene_2d_view.?.render(&self.app.graphics, cmd, pixelSize(rect), shown, shot.view, self.entity_editor.selected, false);
            return rect;
        }

        /// Badge the editor's icon with the icon `eggy.zon` in `project_dir` names, if any.
        fn useProjectIcon(gpa: std.mem.Allocator, project_dir: []const u8) void {
            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.io();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            var dir = std.Io.Dir.cwd().openDir(io, project_dir, .{}) catch return icon.useBadge(null);
            defer dir.close(io);
            const config = eggy.project.load(arena.allocator(), io, dir) catch return icon.useBadge(null);
            icon.useProjectIcon(gpa, project_dir, config.icon);
        }

        fn pixelSize(rect: ui.Rect) eggy.vit.Extent2D {
            return .{ .width = @intFromFloat(@max(1, @round(rect.w))), .height = @intFromFloat(@max(1, @round(rect.h))) };
        }

        /// Open an OS window for each panel the dock has popped out, and close those it took back.
        fn syncPopOuts(self: *Self) !void {
            for (self.workspace.dock.windows, &self.popouts, 0..) |wanted, *popout, i| {
                if (wanted == null) {
                    if (popout.*) |*open| {
                        if (self.viewport_mouse.confined) |confined| if (confined.window.value == open.window.window.value) self.releaseViewportMouse();
                        open.close(&self.app.graphics);
                    }
                    popout.* = null;
                } else if (popout.* == null) {
                    popout.* = try PopOut.open(&self.app.graphics, self.ui.font, self.workspace.windowTitle(i), wanted.?.size, .{ .resizable = true });
                    icon.apply(popout.*.?.window.window);
                }
            }
        }

        /// Route one borrowed SDL event through the initialized desktop host on its main thread.
        /// Handles tool/modal windows first, then Scene input, dock/menu commands, panel UI,
        /// and gameplay/App input as appropriate; may start jobs, change files/world, or
        /// prompt before leaving. Device/input/window/build errors propagate. Returns `.run`
        /// to continue or a terminal SDL result without destroying the host.
        ///
        /// ```zig
        /// // SDL callback adapter supplies current; do not bypass this with App.event:
        /// const result = try host.event(current);
        /// if (result != .run) return result;
        /// ```
        pub fn event(self: *Self, curr_event: sdl3.events.Event) !sdl3.AppResult {
            try self.app.deviceEvent(curr_event);
            if (self.about_window) |window| {
                if (window.closeRequested(curr_event)) {
                    window.close(&self.app.graphics);
                    self.about_window = null;
                    return .run;
                }
                if (window.handle(curr_event)) return self.toolWindowTook(curr_event);
            }
            if (self.input_map_window) |window| {
                if (window.closeRequested(curr_event)) {
                    window.close(&self.app.graphics);
                    self.input_map_window = null;
                    return .run;
                }
                if (window.handle(curr_event)) return self.toolWindowTook(curr_event);
            }
            if (curr_event == .window_focus_lost) {
                self.releaseViewportMouse();
                self.scene_view.camera.cancelNavigation();
                self.game_input = .{};
                self.app.input.releaseAll();
                if (self.app.ui_layer) |layer| layer.cancel();
            }
            if (self.save_prompt != null or self.project_flow != null or self.build_window != null) self.game_input.cancel(&self.app);
            // "Save changes?" takes its own events, and the editor no input meanwhile.
            if (self.save_prompt) |prompt| {
                if (prompt.keyAnswer(curr_event)) |answer| return if (try self.answerSavePrompt(answer)) .success else .run;
                if (prompt.handle(curr_event)) return .run;
                if (weeoui_sdl3.translate(curr_event) != null) return .run;
            }
            // File > New/Open Project's window takes its own events; closing it, or Escape, cancels.
            if (self.project_flow) |flow| {
                if (flow.closeRequested(curr_event)) {
                    flow.close(&self.app.graphics);
                    self.project_flow = null;
                    return .run;
                }
                if (flow.handle(curr_event)) return self.toolWindowTook(curr_event);
            }
            // While the Build progress window is up, it takes its own events and the editor no
            // input. Closing it cancels a build under way.
            if (self.build_window) |window| {
                if (curr_event == .window_close_requested and window.window.owns(curr_event)) {
                    if (self.buildRunning()) self.cancelBuild();
                    self.closeBuildWindow();
                    return .run;
                }
                if (window.handle(curr_event)) return self.toolWindowTook(curr_event);
                if (weeoui_sdl3.translate(curr_event) != null) return .run;
            }
            // Edit > Preferences' window takes its own events; closing it, or Escape, closes it.
            if (self.preferences_window) |window| {
                if (window.closeRequested(curr_event)) {
                    self.closePreferences();
                    return .run;
                }
                if (window.handle(curr_event)) return self.toolWindowTook(curr_event);
            }
            // Edit > Plugins' window takes its own events; closing it, or Escape, closes it.
            if (self.plugins_window) |window| {
                if (window.closeRequested(curr_event)) {
                    window.close(&self.app.graphics);
                    self.plugins_window = null;
                    return .run;
                }
                if (window.handle(curr_event)) return self.toolWindowTook(curr_event);
            }
            // File > Export's window takes its own events.
            if (self.export_window) |window| if (window.handle(curr_event)) return self.toolWindowTook(curr_event);
            // Help > DevTools' window takes its own events; while inspecting, the main window's
            // pointer moves and presses go to it too.
            if (self.devtools_window) |window| {
                if (window.closeRequested(curr_event)) {
                    self.toggleDevtools();
                    return .run;
                }
                if (window.handle(curr_event)) return self.toolWindowTook(curr_event);
                if (self.viewport_mouse.confined == null and self.slotOf(curr_event) == main_slot) if (weeoui_sdl3.translate(curr_event)) |input| switch (input) {
                    .pointer_move => |p| window.pointerMove(p.x, p.y),
                    .pointer_down => |down| if (window.pointerDown(down.position.x, down.position.y)) return .run,
                    else => {},
                };
            }
            try self.syncViewportMouse();
            if (self.play_mode.stopPressed(curr_event, preferences.editor(&self.app.preference_values).stop_play_key)) {
                self.stopPlaying();
                return .run;
            }
            const slot = if ((eggy.game_ui.isControllerInput(curr_event) or self.game_input.mouse_captured) and self.game_input.focused and self.workspace.placed.scene != null and eggy.game_ui.isInput(curr_event))
                self.workspace.placed.scene.?.slot
            else
                self.slotOf(curr_event);

            // F2 renames what is selected in the Hierarchy or Assets (Weeoui's keys don't include it).
            if (curr_event == .key_down) if (curr_event.key_down.key) |key| if (key == .func2) {
                if (self.focused_page == panels.hierarchy_page) self.entity_editor.renameSelected();
                if (self.focused_page == panels.assets_page) self.assets_panel.renameSelected();
                return .run;
            };

            // While the game plays, the Scene panel is the game's: the mouse over it goes to it.
            const game_has_scene = self.play_mode.playing() and !self.workspace.simulating;
            if (game_has_scene) if (self.sceneRect(slot)) |rect| {
                if (self.overScene(slot, curr_event) or ((self.game_input.mouse_captured or self.game_input.buttons != 0) and !eggy.game_ui.isTouchInput(curr_event) and pointerOf(curr_event) != null) or self.game_input.ownsTouch(curr_event)) {
                    if (self.game) |*game| try self.routeGameInput(game, curr_event, slot, rect);
                    return .run;
                }
            };
            if (curr_event == .mouse_button_down) {
                self.game_input.cancel(&self.app);
            }
            if (curr_event == .mouse_motion) if (self.app.ui_layer) |layer| {
                layer.pointer_active = false;
            };
            if (curr_event == .mouse_motion or curr_event == .window_mouse_leave) self.game_input.pointer_in_scene = false;

            // The Scene panel's camera takes presses, drags and wheels over it; F frames the
            // selection, and Delete deletes it.
            if (!game_has_scene) if (self.scene_view.handleFirst(curr_event, self.sceneRectFor(slot, curr_event))) {
                if (curr_event == .mouse_button_down) self.unfocusOnPress(slot, .{ .x = curr_event.mouse_button_down.x, .y = curr_event.mouse_button_down.y }, false);
                if (curr_event == .mouse_button_down and self.scene_view.camera.drag != null) {
                    if (self.windowOf(slot)) |window| try sdl3.mouse.setWindowRelativeMode(window, true);
                }
                try self.syncViewportMouse();
                return .run;
            };
            if (!game_has_scene and self.scene_view.camera.drag != null and eggy.game_ui.isInput(curr_event)) return .run;
            if (!game_has_scene) if (curr_event == .key_down) if (curr_event.key_down.key) |key| if (self.scene_view.camera.hovered and self.scene_view.camera.drag == null and self.scene_view.drag == null) switch (key) {
                .f => {
                    self.frameSelected();
                    return .run;
                },
                // Delete (or Backspace) deletes the selection, as the Hierarchy's Delete does.
                .delete, .backspace => if (self.entity_editor.selected != null) {
                    self.entity_editor.deleteSelected(&self.app, self.gamePtr());
                    return .run;
                },
                else => {},
            };

            // Ctrl+Shift+K while playing keeps the selected entity's Transform for after Stop.
            if (curr_event == .key_down) if (curr_event.key_down.key) |key| if (key == .k and !curr_event.key_down.repeat and curr_event.key_down.mod.controlDown() and curr_event.key_down.mod.shiftDown() and self.play_mode.playing()) {
                self.keepSelectedTransform();
                return .run;
            };

            // A pop-out window's close button docks its panels back into the main window.
            if (slot != main_slot and curr_event == .window_close_requested) {
                self.workspace.closeWindow(slot - 1);
                return .run;
            }

            // The title bar, menus and dock take their own input first.
            // Double-clicking the drawn title bar maximizes or restores, as a system one would.
            // The second press starts the window manager's move, which drops a maximize sent during
            // it (Wayland), so the toggle waits for the move to end; see `applyPendingMaximize`.
            if (slot == main_slot and self.titlebarPressed(curr_event)) {
                const now = sdl3.timer.getNanosecondsSinceInit();
                if (now - self.titlebar_press_ns < double_click_ns) {
                    self.maximize_pending_ns = now;
                    self.titlebar_press_ns = 0;
                } else self.titlebar_press_ns = now;
            } else if (slot == main_slot and curr_event == .window_mouse_enter) self.applyPendingMaximize(true);

            const outcome: workspace_zig.Outcome = if (weeoui_sdl3.translate(curr_event)) |input| self.workspace.handle(slot, input) else .ignored;
            switch (outcome) {
                .plugin_command => |command| if (self.game) |*game| {
                    var editor_context = extensions.context(self);
                    game.editorCommand(command, &editor_context);
                },
                .plugin_bar => |target| if (self.game) |*game| {
                    var editor_context = extensions.context(self);
                    game.barAction(target, &editor_context);
                },
                .quit => if (self.mayLeave(.quit)) return .success,
                .window => |button| if (button != .close or self.mayLeave(.quit)) {
                    if (weeoui_sdl3.windowAction(self.app.window.window, button)) return .success;
                },
                .play => |playing| if (playing) self.startPlaying() else self.stopPlaying(),
                .simulate => self.startPlaying(),
                .scene_button => |button| self.scene_view.press(button),
                .pause => |paused| {
                    self.play_mode.paused = paused;
                    self.app.input.cancel();
                },
                .new_project => if (self.project_flow == null and self.mayLeave(.new_project)) {
                    layout_file.save(self.gpa, self.preference_folders.global, &self.workspace.dock, &self.workspace.tabs, self.workspace.seen_plugin_panels.items);
                    self.project_flow = try ProjectFlow.create(self.gpa, &self.app.graphics, self.ui.font, self.mono);
                },
                .reload => if (try self.forceReload()) return .success,
                .open_project, .open_project_linked => |_, tag| if (self.project_flow == null and self.mayLeave(if (tag == .open_project) .open_project else .open_project_linked)) {
                    if (tag == .open_project_linked and self.upgrades.developer_dir == null) {
                        self.upgrades.logUnavailable(.link);
                    } else {
                        self.picking_to_link = tag == .open_project_linked;
                        sdl3.dialog.showOpenFolder(Self, pickedProject, self, self.app.window.window, null, false);
                    }
                },
                .open_project_folder => if (self.project) |opened| file_manager.showFolder(self.gpa, opened.dir) catch |err| {
                    std.log.err("cannot show {s} in the file manager: {t}", .{ opened.dir, err });
                },
                .upgrade_editor => if (self.upgrades.can_upgrade) try self.upgradeEditor() else self.upgrades.logUnavailable(.upgrade),
                .toggle_devtools => self.toggleDevtools(),
                .about => if (self.about_window == null) {
                    self.about_window = AboutWindow.open(self.gpa, &self.app.graphics, self.ui.font) catch |err| blk: {
                        std.log.err("cannot open About Eggy: {t}", .{err});
                        break :blk null;
                    };
                },
                .save => self.saveScene(),
                // Project Settings are the Preferences window's Project section.
                .project_settings => try self.showProjectSettings(),
                .plugins => _ = self.showPlugins(),
                .export_game => if (self.export_window == null) if (self.project) |opened| {
                    self.export_window = ExportWindow.open(self.gpa, &self.app.graphics, self.ui.font, self.mono, opened.dir) catch |err| blk: {
                        std.log.err("cannot open Export: {t}", .{err});
                        break :blk null;
                    };
                },
                .undo => self.undoOrRedo(.undo),
                .redo => self.undoOrRedo(.redo),
                .preferences => self.openPreferences(),
                .link_developer => if (self.upgrades.can_link) try self.linkDeveloper() else self.upgrades.logUnavailable(.link),
                else => {},
            }
            if (curr_event == .window_focus_lost and self.focus_lost_ms == null) self.focus_lost_ms = sdl3.timer.getMillisecondsSinceInit();
            if (curr_event == .window_focus_gained and self.cameBack()) {
                // Another editor may have unpacked a newer Eggy meanwhile.
                self.upgrades.refresh();
                if (self.input_settings) |settings| settings.reload() catch |err| std.log.err("cannot reload controls.zon: {t}; keeping active mappings", .{err});
                // Files may have changed outside: models and images import again, and the catalog catches up.
                self.app.graphics.forgetAssets();
                self.filesChanged();
                try self.rebuildOnFocus();
            }

            if (curr_event == .drop_file) self.importDropped(slot, curr_event.drop_file);
            // A press anywhere in the window, even on the dock or title bar, can take the keyboard
            // off a field.
            if (weeoui_sdl3.translate(curr_event)) |input| if (input == .pointer_down) self.unfocusOnPress(slot, input.pointer_down.position, outcome == .ignored);
            // Left presses on the Scene panel select, or take the gizmo; moves drag it.
            if (!game_has_scene and (outcome == .ignored or curr_event == .mouse_motion)) if (self.sceneTarget()) |target| {
                if (self.scene_view.handlePointer(curr_event, self.sceneRect(slot), target)) return .run;
            };
            // The pages get the rest, and every pointer move so their hover state stays current.
            const game_keyboard = game_has_scene and self.game_input.focused and self.sceneRect(slot) != null and eggy.game_ui.isInput(curr_event) and pointerOf(curr_event) == null and outcome == .ignored;
            if (game_keyboard) {
                if (self.game) |*game| try self.routeGameInput(game, curr_event, slot, self.sceneRect(slot).?);
            } else if (outcome == .ignored or curr_event == .mouse_motion) self.routeToPages(slot, curr_event);
            if (self.play_mode.running() and !eggy.game_ui.isInput(curr_event)) if (self.game) |*game| {
                game.event(&self.app, curr_event);
            };
            // Quitting from the system (or closing the window) asks about unsaved changes too.
            const quitting = curr_event == .quit or (curr_event == .window_close_requested and slot == main_slot);
            if (quitting and !self.mayLeave(.quit)) return .run;
            return self.app.event(curr_event);
        }

        fn routeGameInput(self: *Self, game: *HotGame, value: eggy.Event, slot: Slot, rect: ui.Rect) !void {
            const window = self.windowOf(slot) orelse return;
            const width, const height = try window.getSize();
            if (value == .mouse_button_down) self.unfocusOnPress(slot, .{ .x = value.mouse_button_down.x, .y = value.mouse_button_down.y }, false);
            self.clearEditorHover();
            try self.game_input.route(&self.app, game, value, rect, .{ @floatFromInt(width), @floatFromInt(height) }, self.play_mode.running(), self.scene_view.view);
            try self.syncViewportMouse();
        }

        fn clearEditorHover(self: *Self) void {
            self.workspace.pointer = .init(-1, -1);
            self.workspace.hover_id = 0;
            self.scene_view.hot = null;
            self.scene_view.hot_end = null;
            for (0..self.pageCount()) |index| self.page(index).pointer = .init(-1, -1);
        }

        /// How each plugin menu row, status item and status row looks this frame, asked of the
        /// game (only entries it declares; with no game, each as declared and disabled).
        fn askPluginBars(self: *Self, arena: std.mem.Allocator) !plugin_bars.States {
            const bars = self.workspace.plugin_bars;
            const states = try plugin_bars.States.declared(arena, bars);
            const game = if (self.game) |*loaded| loaded else {
                for (@constCast(states.menu_rows)) |*state| state.enabled = false;
                for (@constCast(states.status)) |*state| state.enabled = false;
                for (@constCast(states.status_rows)) |*state| state.enabled = false;
                return states;
            };
            var editor_context = extensions.context(self);
            var row: usize = 0;
            for (bars.menus, 0..) |menu, menu_index| for (menu.items, 0..) |_, item| {
                @constCast(states.menu_rows)[row] = game.barState(.{ .menu_item = .{ .menu = menu_index, .item = item } }, &editor_context);
                row += 1;
            };
            row = 0;
            for (bars.status_items, 0..) |entry, index| {
                @constCast(states.status)[index] = game.barState(.{ .status = index }, &editor_context);
                for (entry.items, 0..) |_, item| {
                    @constCast(states.status_rows)[row] = game.barState(.{ .status_item = .{ .status = index, .item = item } }, &editor_context);
                    row += 1;
                }
            }
            return states;
        }

        fn syncViewportMouse(self: *Self) !void {
            const game_owns_scene = self.play_mode.playing() and !self.workspace.simulating and self.game_input.focused;
            const navigating = self.scene_view.camera.drag != null;
            const allowed = (game_owns_scene or navigating) and self.save_prompt == null and self.project_flow == null and self.build_window == null;
            const scene = if (allowed) self.workspace.placed.scene else null;
            const window = if (scene) |placed| self.windowOf(placed.slot) else null;
            const focused_window = if (window) |target| if (target.getFlags().input_focus) target else null else null;
            try self.viewport_mouse.sync(self.app.window.window, focused_window, if (scene) |placed| placed.rect else null, self.game_input.pointer_in_scene or self.game_input.buttons != 0);
            self.game_input.mouse_captured = game_owns_scene and self.viewport_mouse.confined != null;
            self.game_input.relative_mouse = game_owns_scene and self.viewport_mouse.relative;
            if (self.viewport_mouse.confined != null) self.clearEditorHover();
            if (self.game_input.relative_mouse) if (self.app.ui_layer) |layer| {
                layer.context.pointer = .init(-1, -1);
                layer.pointer_active = false;
            };
        }

        fn releaseViewportMouse(self: *Self) void {
            self.viewport_mouse.release(self.app.window.window) catch |err| std.log.err("cannot release viewport mouse capture: {t}: {s}", .{ err, sdl3.errors.get() orelse "no SDL detail" });
            self.game_input.mouse_captured = false;
            self.game_input.relative_mouse = false;
        }

        /// Open the explicit project, else discover this editor's matching source project.
        /// Caller-owned (see `freeProject`); titles `window` after the project's `eggy.zon`.
        fn openProject(gpa: std.mem.Allocator, window: sdl3.video.Window, args: []const [*:0]const u8) !?workspace_zig.Project {
            const discovery = @import("projects/discovery.zig");
            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.io();
            const dir: [:0]u8 = if (try discovery.explicitDirectory(args)) |requested|
                try std.Io.Dir.cwd().realPathFileAlloc(io, requested, gpa)
            else
                (discovery.find(gpa, io, project.name, try sdl3.filesystem.getBasePath(), ".") catch |err| {
                    std.log.err("cannot discover project {s}: {t}", .{ project.name, err });
                    return err;
                }) orelse return null;
            defer gpa.free(dir);
            var project_root = std.Io.Dir.cwd().openDir(io, dir, .{}) catch |err| {
                std.log.err("cannot open project {s}: {t}", .{ dir, err });
                return err;
            };
            defer project_root.close(io);
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const config = eggy.project.load(arena.allocator(), io, project_root) catch |err| {
                std.log.err("cannot read {s}/{s}: {t}", .{ dir, eggy.project.file_name, err });
                return err;
            };
            const window_title = try std.fmt.allocPrintSentinel(arena.allocator(), "{s} - eggy editor", .{config.title}, 0);
            window.setTitle(window_title) catch {};
            std.log.info("opened {s} ({s})", .{ config.title, dir });
            const name_copy = try gpa.dupe(u8, config.name);
            errdefer gpa.free(name_copy);
            const title_copy = try gpa.dupe(u8, config.title);
            errdefer gpa.free(title_copy);
            return .{ .name = name_copy, .title = title_copy, .dir = try gpa.dupe(u8, dir) };
        }

        fn freeProject(gpa: std.mem.Allocator, opened: workspace_zig.Project) void {
            gpa.free(opened.name);
            gpa.free(opened.title);
            gpa.free(opened.dir);
        }

        /// The game's library, beside the editor, absolute. Caller-owned.
        fn libraryPath(gpa: std.mem.Allocator) ![]u8 {
            return std.fs.path.join(gpa, &.{ try sdl3.filesystem.getBasePath(), project.game_library.file_name });
        }

        /// When the file at `path` last changed, or null if it can't be read.
        fn modifiedAt(path: []const u8) ?std.Io.Timestamp {
            var threaded: std.Io.Threaded = .init_single_threaded;
            const stat = std.Io.Dir.cwd().statFile(threaded.io(), path, .{}) catch return null;
            return stat.mtime;
        }

        /// When `opened`'s editor executable last changed, or null if it can't be read.
        fn editorModified(gpa: std.mem.Allocator, opened: workspace_zig.Project) ?std.Io.Timestamp {
            var threaded: std.Io.Threaded = .init_single_threaded;
            const path = std.fmt.allocPrint(gpa, "{s}{c}zig-out{c}bin{c}{s}_editor{s}", .{ opened.dir, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, opened.name, builtin.target.exeFileExt() }) catch return null;
            defer gpa.free(path);
            const stat = std.Io.Dir.cwd().statFile(threaded.io(), path, .{}) catch return null;
            return stat.mtime;
        }

        /// Whether focus, just gained, comes back from another app rather than moving between the
        /// editor's own windows (or from one that closed), which happens within a moment.
        // ponytail: a switch away and back inside `away_ms` doesn't count; track app focus if SDL ever reports it.
        fn cameBack(self: *Self) bool {
            const away_ms = 500;
            const lost_ms = self.focus_lost_ms orelse return false;
            self.focus_lost_ms = null;
            return sdl3.timer.getMillisecondsSinceInit() - lost_ms > away_ms;
        }

        /// The editor came back into focus from another app: rebuild the project, in case its code changed.
        // ponytail: on Windows the build can't replace the running editor's executable; build to a side folder there.
        fn rebuildOnFocus(self: *Self) !void {
            const opened = self.project orelse return;
            if (self.project_flow != null or self.build_window != null or self.buildRunning()) return;
            if (!preferences.editor(&self.app.preference_values).rebuild_on_focus) return;
            // Nothing to build if no source changed since the last build.
            if (self.sourcesNow().eql(self.built_sources)) return;
            self.cancelBuild(); // the last one's result
            std.log.info("rebuilding {s}", .{opened.title});
            try self.startBuild(.rebuild);
        }

        /// File > Upgrade Editor: point the project at the newest Eggy and build it, replacing a
        /// rebuild under way. Once built, Reload opens the upgraded editor.
        fn upgradeEditor(self: *Self) !void {
            const opened = self.project orelse return;
            self.cancelBuild();
            std.log.info("upgrading {s} to the newest Eggy", .{opened.title});
            try self.startBuild(.upgrade);
        }

        /// File > Link Developer Eggy: once confirmed, link the project to the Eggy codebase being
        /// developed and build it, replacing a rebuild under way.
        fn linkDeveloper(self: *Self) !void {
            const opened = self.project orelse return;
            if (!self.upgrades.confirmLink(self.app.window.window, opened.title)) return;
            self.cancelBuild();
            std.log.info("linking {s} to the Eggy codebase at {s}", .{ opened.title, self.upgrades.developer_dir.? });
            try self.startBuild(.{ .link = self.upgrades.developer_dir.? });
        }

        /// Start `action`'s job on the open project as `rebuild`, and the Build progress window
        /// that follows it.
        /// Internal host/extension operation: call only after canceling/clearing any previous
        /// job; this does not dispose an existing `rebuild`. No project is a no-op. Captures
        /// source stamps, starts a background process, and opens a modal progress window;
        /// path/job/window errors propagate, cleaning the new job on failure.
        ///
        /// ```zig
        /// host.cancelBuild();
        /// try host.startBuild(.rebuild);
        /// // Keep iterate/event running so the modal window can update and cancel.
        /// ```
        pub fn startBuild(self: *Self, action: job_zig.Action) !void {
            const opened = self.project orelse return;
            const folders = try job_zig.editorFolders(self.gpa);
            defer self.gpa.free(folders.resources_dir);
            defer self.gpa.free(folders.engines_dir);
            const sources = self.sourcesNow();
            const job = try Job.start(self.gpa, .{ .dir = opened.dir, .resources_dir = folders.resources_dir, .engines_dir = folders.engines_dir, .action = action });
            errdefer job.deinit();
            self.built_sources = sources;
            if (self.build_window == null) self.build_window = try BuildWindow.open(self.gpa, &self.app.graphics, self.ui.font, self.mono, self.app.window.window, opened.title);
            self.rebuild = job;
        }

        /// The stamp of the open project's sources, and of the Eggy codebase it is linked to.
        fn sourcesNow(self: *Self) source_stamp.Stamp {
            const opened = self.project orelse return .{};
            var dirs: [2][]const u8 = .{ opened.dir, "" };
            var count: usize = 1;
            if (self.upgrades.current) |current| if (current == .linked) {
                dirs[1] = current.linked;
                count = 2;
            };
            var threaded: std.Io.Threaded = .init_single_threaded;
            return source_stamp.take(self.gpa, threaded.io(), dirs[0..count]);
        }

        /// Draw the Build progress window and act on its buttons; returns whether the editor
        /// should quit, as Reload opened the rebuilt one.
        fn updateBuildWindow(self: *Self, window: *BuildWindow, arena: std.mem.Allocator) !bool {
            // A build that changed nothing was dropped (see `rebuildState`): nothing to show.
            const job = self.rebuild orelse {
                self.closeBuildWindow();
                return false;
            };
            const status = try job.status(arena);
            // Reload asked for the editor as soon as it is built.
            if (self.reload_when_built and status.stage == .done) return try self.launchRebuilt(job);
            switch (try window.update(&self.app.graphics, &self.ui, status, self.workspace.build_state == .ready)) {
                .none => {},
                .close => self.closeBuildWindow(),
                .cancel => {
                    self.cancelBuild();
                    self.closeBuildWindow();
                },
                .reload => return try self.launchRebuilt(job),
            }
            return false;
        }

        fn closeBuildWindow(self: *Self) void {
            const window = self.build_window orelse return;
            window.close(&self.app.graphics);
            self.build_window = null;
        }

        /// Whether `rebuild` is still under way.
        /// Internal host query: snapshots job status using temporary arena storage.
        /// Returns false for no job, done/failed stages, or status retrieval failure.
        ///
        /// ```zig
        /// if (host.buildRunning()) host.cancelBuild();
        /// ```
        pub fn buildRunning(self: *Self) bool {
            const job = self.rebuild orelse return false;
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const stage = (job.status(arena.allocator()) catch return false).stage;
            return stage != .done and stage != .failed;
        }

        /// Stop `rebuild` (the build is killed) and forget it.
        /// Clears automatic reload intent and destroys the owned job; no job is a no-op.
        /// Does not close the progress window here; a later host frame notices the absent job.
        ///
        /// ```zig
        /// host.cancelBuild(); // Host/extension cancellation on the main thread.
        /// ```
        pub fn cancelBuild(self: *Self) void {
            self.reload_when_built = false;
            const job = self.rebuild orelse return;
            job.deinit();
            self.rebuild = null;
        }

        /// The title bar's Reload: open the rebuilt editor if a rebuild made one; otherwise
        /// rebuild (in the Build progress window) and open the result, changed or not. Returns
        /// whether the editor should quit, as the new one is open.
        /// Internal host/extension bridge: an existing running job is reused and scheduled
        /// to reload when done. A ready result still passes through save confirmation.
        /// False means keep servicing frames/events, not failure; launch/job/window errors
        /// propagate. Does not destroy this host; caller returns success to SDL when true.
        ///
        /// ```zig
        /// if (try host.forceReload()) return .success;
        /// return .run; // Rebuild or save confirmation is still pending.
        /// ```
        pub fn forceReload(self: *Self) !bool {
            if (self.workspace.build_state == .ready) if (self.rebuild) |job| return try self.launchRebuilt(job);
            if (self.buildRunning()) {
                self.reload_when_built = true;
                return false;
            }
            self.cancelBuild();
            try self.startBuild(.rebuild);
            self.reload_when_built = true;
            return false;
        }

        /// How the rebuild is going, for the status bar; its text lives in `arena`.
        fn rebuildState(self: *Self, arena: std.mem.Allocator) !workspace_zig.BuildState {
            const job = self.rebuild orelse return .idle;
            const status = try job.status(arena);
            return switch (status.stage) {
                .failed => .failed,
                .done => blk: {
                    const opened = self.project.?;
                    const changed = !std.meta.eql(editorModified(self.gpa, opened), self.editor_modified);
                    if (changed) break :blk .ready;
                    // Reload opens it anyway.
                    if (self.reload_when_built) break :blk .ready;
                    // The same editor: swap in the game if only it changed.
                    self.swapGameIfRebuilt();
                    // Nothing more: forget the build.
                    job.deinit();
                    self.rebuild = null;
                    break :blk .idle;
                },
                else => .{ .building = status.detail },
            };
        }

        /// Swap in the game's library if a build changed it, starting the game over in this
        /// editor. Only for a library built against this editor's Eggy: when the editor itself
        /// changed, Reload opens the new one instead.
        fn swapGameIfRebuilt(self: *Self) void {
            const library_path = libraryPath(self.gpa) catch return;
            defer self.gpa.free(library_path);
            const modified = modifiedAt(library_path);
            if (std.meta.eql(modified, self.game_modified)) return;
            self.game_modified = modified;
            // The world as it is (not as a play left it), to put back into the rebuilt game's:
            // entities and their values carry over the swap.
            self.stopPlaying();
            var kept: ?eggy.scene.Scene = null;
            defer if (kept) |*scene| scene.deinit();
            if (self.game) |*game| {
                kept = eggy.scene.Scene.capture(self.gpa, &self.app.world, game.sceneAccess(), self.entity_editor.roots(&self.app.world)) catch |err| blk: {
                    std.log.err("cannot keep the scene across the swap ({t}): the game starts over", .{err});
                    break :blk null;
                };
                game.reload(&self.app) catch |err| std.log.err("cannot load the rebuilt game: {t}", .{err});
            } else {
                self.game = HotGame.load(self.gpa, library_path) catch |err| {
                    std.log.err("cannot load the game from {s}: {t}", .{ library_path, err });
                    return;
                };
                if (self.project) |opened| {
                    if (self.open_scene == null) self.open_scene = .{ .gpa = self.gpa, .project_dir = opened.dir };
                    self.open_scene.?.reopen(&self.app.world, self.game.?.sceneAccess());
                }
            }
            const game = &self.game.?;
            if (kept) |*scene| if (scene.instantiate(self.gpa, &self.app.world, game.sceneAccess(), null)) |made| {
                self.gpa.free(made.entities);
                if (made.skipped > 0) std.log.warn("{d} components or fields didn't carry over the swap (see above)", .{made.skipped});
            } else |err| std.log.err("cannot put the scene back: {t}", .{err});
            self.workspace.setPluginPanels(game.panels);
            self.workspace.plugin_commands = game.commands;
            self.workspace.setPluginBars(.{ .menus = game.menus, .status_items = game.status_items });
            preferences.writeRegistry(self.gpa, self.preference_folders, game.plugin_keys, game.preference_manifests, self.plugin_switches.off()) catch |err| std.log.warn("cannot update .eggy/plugins.zon: {t}", .{err});
            game.start(&self.app, self.plugin_switches.off(), .discard);
        }

        /// Keep the Assets panel's view as the user's preference, for every project.
        fn rememberAssetsView(self: *Self) void {
            const literal = if (self.assets_panel.view == .grid) ".grid" else ".list";
            self.app.preference_values.set(.global, preferences.editor_key, "assets_view", literal) catch return;
            preferences.save(self.gpa, &self.app.preference_values, self.preference_folders, .global, preferences.editor_key) catch |err| std.log.warn("cannot keep the Assets view: {t}", .{err});
        }

        /// A plugin's switch in Preferences was flipped: carry it out, as a step to undo.
        fn flipPlugin(self: *Self, plugin: preferences.Switch) void {
            self.switchPlugin(plugin.key, plugin.on) catch |err| {
                self.workspace.toast("Couldn't switch the plugin: see the Console");
                return std.log.err("cannot turn {s} {s}: {t}", .{ plugin.key, if (plugin.on) "on" else "off", err });
            };
            const key = self.gpa.dupe(u8, plugin.key) catch return;
            self.history.record(.{ .plugin = .{ .key = key, .on = plugin.on } });
        }

        /// Turn plugin `key` on or off: save it to the project, and start the game over on the
        /// scene as it is, so the plugin starts or stops.
        fn switchPlugin(self: *Self, key: []const u8, on: bool) !void {
            self.stopPlaying();
            const game = if (self.game) |*loaded| loaded else return error.NoGame;
            try self.plugin_switches.set(key, on);
            try preferences.writeRegistry(self.gpa, self.preference_folders, game.plugin_keys, game.preference_manifests, self.plugin_switches.off());
            var scene = try eggy.scene.Scene.capture(self.gpa, &self.app.world, game.sceneAccess(), self.entity_editor.roots(&self.app.world));
            defer scene.deinit();
            const place = self.entity_editor.selectionPlace(&self.app, game);
            game.restart(&self.app, &scene, self.plugin_switches.off(), .discard);
            self.entity_editor.reselect(&self.app, game, place);
            // What a plugin's `init` does to the world comes with the switch, not as a step of its own.
            if (self.sceneText()) |text| self.history.setBaseline(text);
            std.log.info("turned {s} {s}", .{ key, if (on) "on" else "off" });
        }

        /// One of the editor's own windows (Preferences, DevTools, Build, a project's) took
        /// `curr_event`: a press there takes the keyboard off every page's field.
        fn toolWindowTook(self: *Self, curr_event: sdl3.events.Event) sdl3.AppResult {
            self.releaseViewportMouse();
            self.game_input.cancel(&self.app);
            if (curr_event == .mouse_button_down) for (0..self.pageCount()) |index| {
                self.page(index).focus = 0;
            };
            return .run;
        }

        /// Save the dock's layout once it has changed and then held still for a second, so it
        /// survives a crash or a reload, not only a clean close.
        fn keepLayout(self: *Self) void {
            const now = sdl3.timer.getMillisecondsSinceInit();
            if (now -| self.layout_checked_ms < 500) return;
            self.layout_checked_ms = now;
            const current = layout_file.fingerprint(&self.workspace.dock, &self.workspace.tabs, self.workspace.seen_plugin_panels.items);
            if (current == self.layout_saved) {
                self.layout_changed_ms = null;
                return;
            }
            const since = self.layout_changed_ms orelse now;
            self.layout_changed_ms = since;
            if (now -| since < 1000) return;
            layout_file.save(self.gpa, self.preference_folders.global, &self.workspace.dock, &self.workspace.tabs, self.workspace.seen_plugin_panels.items);
            self.layout_saved = current;
            self.layout_changed_ms = null;
        }

        /// What is being dragged between panels, if anything. In `arena`.
        fn dragging(self: *Self, arena: std.mem.Allocator) ?Dragged {
            // Only an asset a field can hold is dragged out: folders and what has no identity stay.
            if (self.assets_panel.dragged()) |path| {
                const reference = (self.project_assets orelse return null).referenceAt(path) orelse return null;
                return .{ .asset = reference };
            }
            return self.entity_editor.dragged(arena, &self.app, self.gamePtr());
        }

        /// A file or folder dropped onto the Assets panel from outside: copy it into the project,
        /// into the folder it landed on. Dropped anywhere else, it is left where it is.
        fn importDropped(self: *Self, slot: Slot, dropped: sdl3.events.DropFile) void {
            if (self.openDroppedPlugin(dropped.file_name)) return;
            const opened = self.project orelse return self.workspace.toast("Open a project to bring files into it");
            const at = ui.Vec2{ .x = dropped.x, .y = dropped.y };
            if (self.pageAt(slot, at.x, at.y) != panels.assets_page) return self.workspace.toast("Drop files on the Assets panel to add them to the project");
            const folder = self.assets_panel.importFolder(&self.assets_ui, at);
            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.io();
            var files = std.Io.Dir.cwd().openDir(io, opened.dir, .{}) catch return;
            defer files.close(io);
            const imported = file_ops.import(self.gpa, io, files, dropped.file_name, folder) catch |err| {
                std.log.err("cannot bring {s} into the project: {t}", .{ dropped.file_name, err });
                return self.workspace.toast("Couldn't bring that file in: see the Console");
            };
            var message: [128]u8 = undefined;
            self.workspace.toast(std.fmt.bufPrint(&message, "Added {s}", .{imported}) catch "Added the file");
            self.history.record(.{ .create = .{ .path = imported } });
            self.filesChanged();
        }

        /// A plugin's `eggy.zon` dropped anywhere opens in Edit > Plugins, to read and install;
        /// returns whether `path` was one.
        fn openDroppedPlugin(self: *Self, path: []const u8) bool {
            if (!std.mem.eql(u8, std.fs.path.basename(path), eggy.project.file_name)) return false;
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            var threaded: std.Io.Threaded = .init_single_threaded;
            const text = std.Io.Dir.cwd().readFileAllocOptions(threaded.io(), path, arena.allocator(), .limited(1 << 20), .of(u8), 0) catch return false;
            // A project's own eggy.zon, without a .plugin section, is just a file.
            _ = eggy.plugin_manifest.parse(arena.allocator(), text) catch |err| if (err == error.NotAPlugin) return false;
            const window = self.showPlugins() orelse {
                self.workspace.toast("Open a project to install plugins into it");
                return true;
            };
            window.fetchFrom(path);
            return true;
        }

        /// Edit > Plugins, opened if it isn't; null without a project, or if it can't open.
        fn showPlugins(self: *Self) ?*plugin_manager.PluginsWindow {
            if (self.plugins_window) |window| return window;
            const opened = self.project orelse return null;
            self.plugins_window = plugin_manager.PluginsWindow.open(self.gpa, &self.app.graphics, self.ui.font, opened.dir) catch |err| {
                std.log.err("cannot open Plugins: {t}", .{err});
                return null;
            };
            return self.plugins_window;
        }

        /// The project's plugins changed: build the game with them (the Build window shows it).
        fn rebuildForPlugins(self: *Self) void {
            if (self.project_flow != null or self.build_window != null) return;
            self.cancelBuild();
            self.startBuild(.rebuild) catch |err| std.log.err("cannot rebuild for the plugins: {t}", .{err});
        }

        /// A file dragged from Assets let go at `at` in window `slot`, over page `over` (if any):
        /// a model or scene becomes an entity, on the ground under the pointer in the Scene
        /// panel, or under the row it is let go on in the Hierarchy (at the top level off them);
        /// an image paints the mesh it is let go on, in either.
        fn spawnDropped(self: *Self, slot: Slot, at: ui.Vec2, dropped: Reference, over: ?usize) void {
            const game = self.gamePtr();
            if (dropped.kind == .image and eggy.assets.Kind.isTexture(dropped.name)) {
                const scene = self.sceneRect(slot);
                const target = if (scene != null and scene.?.contains(at.x, at.y) and over == null)
                    self.scene_view.entityAt(&self.app, scene.?, at)
                else if (over == panels.hierarchy_page) self.entity_editor.hierarchy.entityAt(&self.hierarchy_ui, at) else null;
                const entity = target orelse return;
                if (!self.entity_editor.paint(&self.app, game, entity, dropped)) self.workspace.toast("Only an entity with a Mesh can be painted");
                return;
            }
            if (dropped.kind != .model and dropped.kind != .scene) return;
            if (self.sceneRect(slot)) |scene| if (scene.contains(at.x, at.y) and over == null) {
                _ = self.entity_editor.spawnFrom(&self.app, game, dropped, self.scene_view.dropPoint(scene, at), null);
                return;
            };
            if (over == panels.hierarchy_page) _ = self.entity_editor.spawnFrom(&self.app, game, dropped, .{ 0, 0, 0 }, self.entity_editor.hierarchy.entityAt(&self.hierarchy_ui, at));
        }

        /// Bring each scene instance's entities up to date with its file (see `SceneInstances`).
        fn syncSceneInstances(self: *Self) void {
            const provider = self.project_assets orelse return;
            const game = if (self.game) |*loaded| loaded else return;
            var key_buffer: [eggy.assets.id.key_len]u8 = undefined;
            const open_key = if (self.openScenePath()) |path| provider.keyOf(&key_buffer, path) else null;
            self.app.sceneInstances().sync(provider.files(), &self.app.world, game.sceneAccess(), open_key);
        }

        /// The project's files changed: the Assets panel lists them again, the catalog keeps up,
        /// and scene instances are made again from their files.
        /// Internal host notification after external/extension asset mutations. May create
        /// or remove catalog entries and invalidate GPU asset caches; failures log rather than
        /// propagate. Instance rebuilding is deferred to subsequent synchronization.
        ///
        /// ```zig
        /// // After a host extension has written project resources:
        /// host.filesChanged();
        /// ```
        pub fn filesChanged(self: *Self) void {
            self.assets_panel.refreshSoon();
            self.syncAssets();
            self.app.sceneInstances().remakeAll();
        }

        /// Make the asset catalog match the project's `resources/` (new files get ids, gone files
        /// lose theirs). A model's settings or file may have changed with it, so the GPU's models
        /// and textures load again.
        fn syncAssets(self: *Self) void {
            const assets_of = self.project_assets orelse return;
            const changes = assets_of.sync() catch |err| return std.log.warn("cannot update the asset catalog: {t}", .{err});
            if (!changes.any()) return;
            self.app.graphics.forgetAssets();
        }

        /// Before files move or go: turn the path references of scenes and materials that were
        /// never opened into ids, so they still find their assets. Fails, with the reason in a
        /// toast, if one can't be, and then nothing has been written or moved.
        fn keepRefsValid(self: *Self, io: std.Io, project_folder: std.Io.Dir) !void {
            const provider = self.project_assets orelse return;
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            const types: []const eggy.components.Info = if (self.game) |game| game.sceneAccess().types() else &.{};
            const problem = try legacy_refs.normalize(self.gpa, arena_state.allocator(), io, project_folder, provider, types);
            if (problem) |why| {
                std.log.err("not moving: {s}", .{why});
                self.workspace.toast("Not moved: a scene or material holds a reference that can't be kept: see the Console");
                return error.UnmigratableReference;
            }
        }

        /// Tell the catalog that `from` now lives at `to`, keeping its asset ids.
        fn assetsMoved(self: *Self, from: []const u8, to: []const u8) void {
            if (self.project_assets) |assets_of| assets_of.moved(from, to);
        }

        /// Tell the catalog that `to` is a copy of `from`, so it gets ids of its own.
        fn assetsCopied(self: *Self, from: []const u8, to: []const u8) void {
            if (self.project_assets) |assets_of| assets_of.copied(from, to);
        }

        /// The chip beside the pointer while `dragged` is over page `index`: its name, or why
        /// letting go there won't take it.
        fn dragLabel(self: *Self, arena: std.mem.Allocator, dragged: Dragged, index: usize) []const u8 {
            const name = switch (dragged) {
                .entity => |entity| entity.name,
                .asset => |reference| reference.name,
            };
            switch (index) {
                panels.hierarchy_page => if (self.entity_editor.hierarchy.dragLabel(arena)) |label| return label,
                panels.ui_tree_page => if (self.ui_designer.dragLabel(arena)) |label| return label,
                panels.assets_page => if (self.assets_panel.dragLabel()) |label| return label,
                panels.inspector_page => if (self.entity_editor.inspector.targetAt(&self.ui, self.ui.pointer)) |target| if (!dragged.fits(target)) {
                    const requires = std.mem.span(target.requires);
                    return switch (target.kind) {
                        .entity => if (requires.len > 0) std.fmt.allocPrint(arena, "Needs an entity with {s}", .{requires}) catch name else "Takes an entity",
                        else => if (target.accepts == .any) "Takes a file" else std.fmt.allocPrint(arena, "Takes a {s} file", .{@tagName(target.accepts)}) catch name,
                    };
                },
                else => {},
            }
            return name;
        }

        /// A press at `at` in window `slot` takes the keyboard off every page's field but the one
        /// pressed, and closes the right-click menus of every other page: in every window, and in
        /// the pressed page too when it lands on nothing to focus there. `reaches_pages` is false when the workspace took the press (a tab, a menu, a
        /// splitter), which keeps no field.
        fn unfocusOnPress(self: *Self, slot: Slot, at: ui.Vec2, reaches_pages: bool) void {
            const pressed = if (reaches_pages) self.pageAt(slot, at.x, at.y) else null;
            if (pressed) |index| self.focused_page = index;
            // A right-click menu closes on a press anywhere else; its own page handles presses on it.
            if (pressed != panels.hierarchy_page) self.entity_editor.hierarchy.menu = null;
            if (pressed != panels.ui_tree_page) self.ui_designer.closeTreeMenus();
            if (pressed != panels.assets_page) self.assets_panel.menu = null;
            for (0..self.pageCount()) |index| {
                const page_ui = self.page(index);
                const keeps = if (pressed) |chosen| chosen == index and page_ui.last_root != null and hit_test.controlAt(page_ui.last_root.?, at.x, at.y) != 0 else false;
                if (!keeps) page_ui.focus = 0;
                // A dropdown open in another page closes too: that page never sees this press,
                // so it would stay open, taking that page's clicks, until pressed again.
                if (pressed != index) page_ui.open_popup = 0;
            }
        }

        /// Hand `curr_event` from window `slot` to the pages in that window that want it: pointer
        /// moves and releases to all of them, presses and wheels to the one they land on (a press
        /// also gives it the keyboard), keys and text to the focused one.
        fn routeToPages(self: *Self, slot: Slot, curr_event: sdl3.events.Event) void {
            const input = weeoui_sdl3.translate(curr_event) orelse {
                // Window events: the Inspector's handler attaches screen reader support with them.
                const inspector = self.workspace.placed.pages[panels.inspector_page] orelse return;
                if (inspector.slot == slot) weeoui_sdl3.handleEvent(&self.ui, curr_event);
                return;
            };
            // A drag let go over the Inspector sets the reference field there, before the panel
            // it came from ends the drag; a model or scene file let go over the Scene panel or
            // the Hierarchy becomes an entity there.
            if (input == .pointer_up) if (self.dragging(self.ui.builder().allocator)) |dragged| {
                const at = input.pointer_up.position;
                const over = self.pageAt(slot, at.x, at.y);
                if (over == panels.inspector_page) _ = self.entity_editor.dropOnInspector(&self.ui, &self.app, self.gamePtr(), at, dragged);
                if (over == panels.ui_properties_page) _ = self.ui_designer.dropOnProperties(&self.ui_properties_ui, at, dragged);
                if (over == panels.ui_designer_page) if (self.uiDesignerEnv()) |env| {
                    _ = self.ui_designer.dropOnPreview(env, at, dragged);
                };
                if (dragged == .asset) self.spawnDropped(slot, at, dragged.asset, over);
            };
            for (0..self.pageCount()) |index| {
                const placed = self.workspace.placed.pages[index] orelse continue;
                if (placed.slot != slot) continue;
                const wanted = switch (input) {
                    .pointer_move, .pointer_up => true,
                    .pointer_down => |down| placed.rect.contains(down.position.x, down.position.y),
                    .wheel => |wheel| placed.rect.contains(wheel.position.x, wheel.position.y),
                    .key_down, .text, .composition => index == self.focused_page,
                };
                if (!wanted) continue;
                // ponytail: only the Inspector is exposed to screen readers; give plugin pages AccessKit too once one adapter can serve several contexts.
                if (index == panels.console_page and self.console.terminal.handle(input)) continue;
                if (index == panels.asset_preview_page and self.asset_preview.handle(input)) continue;
                if (index == panels.scene_2d_page and self.scene_2d.handle(curr_event, self.sceneTarget())) continue;
                // Assets' right-clicks, double-clicks and keys, before its UI.
                if (index == panels.assets_page) {
                    const result = switch (input) {
                        .key_down => |key| self.assets_panel.key(key),
                        else => self.assets_panel.pointer(&self.assets_ui, input),
                    };
                    if (result.action) |action| self.applyAssetAction(action);
                    if (result.used) continue;
                }
                // The Hierarchy's right-clicks, double-clicks, drags and keys, before its UI.
                if (index == panels.hierarchy_page) {
                    const used = switch (input) {
                        .key_down => |key| self.entity_editor.hierarchyKey(&self.app, self.gamePtr(), key, self.hierarchy_ui.wants_text),
                        .pointer_down, .pointer_move, .pointer_up => self.entity_editor.hierarchyPointer(&self.hierarchy_ui, &self.app, self.gamePtr(), input),
                        else => false,
                    };
                    self.applyEntityCommands();
                    if (used) continue;
                }
                // The UI Tree's, likewise.
                if (index == panels.ui_tree_page) if (self.uiDesignerEnv()) |env| {
                    const used = switch (input) {
                        .key_down => |key| self.ui_designer.treeKey(env, key, self.ui_tree_ui.wants_text),
                        .pointer_down, .pointer_move, .pointer_up => self.ui_designer.treePointer(&self.ui_tree_ui, env, input),
                        else => false,
                    };
                    if (used) continue;
                };
                if (index == panels.inspector_page) weeoui_sdl3.handleEvent(&self.ui, curr_event) else self.page(index).handle(input);
            }
        }

        /// Have SDL send typed text to the window whose page has a text field focused, and only
        /// that one: it is what a text field types with, and the on-screen keyboard follows it.
        /// SDL's own state is checked each frame, as Weeoui's Inspector handling switches it too.
        fn syncTextInput(self: *Self) void {
            var wanted: ?Slot = null;
            if (self.play_mode.playing() and self.game_input.focused) if (self.app.ui_layer) |layer| {
                if (layer.context.wants_text) if (self.workspace.placed.scene) |scene| {
                    wanted = scene.slot;
                };
            };
            for (0..self.pageCount()) |index| {
                const placed = self.workspace.placed.pages[index] orelse continue;
                if (self.page(index).wants_text) wanted = placed.slot;
            }
            for (0..slot_count) |slot| {
                const window = self.windowOf(slot) orelse continue;
                const on = if (wanted) |chosen| chosen == slot else false;
                if (sdl3.keyboard.textInputActive(window) == on) continue;
                (if (on) sdl3.keyboard.startTextInput(window) else sdl3.keyboard.stopTextInput(window)) catch {};
            }
        }

        /// The OS window for `slot`, if it is open.
        fn windowOf(self: *Self, slot: Slot) ?sdl3.video.Window {
            if (slot == main_slot) return self.app.window.window;
            const popout = self.popouts[slot - 1] orelse return null;
            return popout.window.window;
        }

        /// The game's library, if loaded.
        fn gamePtr(self: *Self) ?*const HotGame {
            return if (self.game) |*game| game else null;
        }

        /// Page `index`'s UI (see `panels.max_pages`).
        fn page(self: *Self, index: usize) *ui.Context {
            if (index == panels.inspector_page) return &self.ui;
            if (index == panels.console_page) return &self.console_ui;
            if (index == panels.hierarchy_page) return &self.hierarchy_ui;
            if (index == panels.assets_page) return &self.assets_ui;
            if (index == panels.animation_page) return &self.animation_ui;
            if (index == panels.ui_designer_page) return &self.ui_designer_ui;
            if (index == panels.ui_tree_page) return &self.ui_tree_ui;
            if (index == panels.ui_properties_page) return &self.ui_properties_ui;
            if (index == panels.asset_preview_page) return &self.asset_preview_ui;
            if (index == panels.scene_2d_page) return &self.scene_2d_ui;
            return &self.plugin_pages[index - panels.first_plugin_page];
        }

        /// How many pages there are: the Inspector, the Console, the Hierarchy, and the game's
        /// panels.
        fn pageCount(self: *const Self) usize {
            return panels.first_plugin_page + self.workspace.plugin_panels.len;
        }

        /// The page whose panel holds (x, y) in window `slot`.
        fn pageAt(self: *const Self, slot: Slot, x: f32, y: f32) ?usize {
            for (self.workspace.placed.pages[0..self.pageCount()], 0..) |placement, index| {
                const placed = placement orelse continue;
                if (placed.slot == slot and placed.rect.contains(x, y)) return index;
            }
            return null;
        }

        /// Maximize or restore, as a title bar double-click asked, once the window manager's move
        /// has ended: the pointer came back (`move_ended`), or a moment passed for platforms
        /// that don't move or don't say.
        fn applyPendingMaximize(self: *Self, move_ended: bool) void {
            const asked_ns = self.maximize_pending_ns orelse return;
            const settle_ns = 250 * std.time.ns_per_ms;
            if (!move_ended and sdl3.timer.getNanosecondsSinceInit() - asked_ns < settle_ns) return;
            self.maximize_pending_ns = null;
            _ = weeoui_sdl3.windowAction(self.app.window.window, .maximize);
        }

        /// Whether `curr_event` is a press on the main title bar's draggable part. SDL hands such
        /// presses to the OS to move the window instead of to the app, so they show up only
        /// indirectly: X11 and macOS send `window_hit_test`, and on Wayland the move's pointer
        /// grab sends `window_mouse_leave` while the pointer was last over the bar. Windows
        /// handles caption double-clicks itself.
        // ponytail: the Wayland signal is a heuristic; replace it if SDL starts reporting these presses.
        fn titlebarPressed(self: *const Self, curr_event: sdl3.events.Event) bool {
            if (builtin.os.tag == .windows or !self.workspace.custom_frame) return false;
            const press = switch (curr_event) {
                .window_hit_test => true,
                .window_mouse_leave => std.mem.eql(u8, sdl3.video.getCurrentDriverName() orelse "", "wayland"),
                else => false,
            };
            if (!press) return false;
            const p = self.workspace.pointer;
            if (self.workspace.pointer_slot != main_slot or !self.frame.bar.contains(p.x, p.y)) return false;
            for (self.frame.buttons[0..self.frame.button_count]) |button| if (button.contains(p.x, p.y)) return false;
            return !self.frame.controls.contains(p.x, p.y);
        }

        /// Which of the editor's windows `curr_event` came from; the main window for events
        /// without one.
        fn slotOf(self: *const Self, curr_event: sdl3.events.Event) Slot {
            const id: sdl3.video.WindowId = switch (curr_event) {
                inline else => |payload| blk: {
                    const T = @TypeOf(payload);
                    if (T == sdl3.events.Window) break :blk payload.id;
                    if (@typeInfo(T) == .@"struct" and @hasField(T, "window_id")) {
                        const window_id: ?sdl3.video.WindowId = payload.window_id;
                        break :blk window_id orelse return main_slot;
                    }
                    if (@typeInfo(T) == .@"struct" and @hasField(T, "id")) {
                        if (@TypeOf(payload.id) == ?sdl3.video.WindowId) break :blk payload.id orelse return main_slot;
                    }
                    return main_slot;
                },
            };
            for (self.popouts, 0..) |popout, i| if (popout) |open| if (open.id == id) return workspace_zig.windowSlot(i);
            return main_slot;
        }

        /// The Inspector panel: the entity selected in the Hierarchy, else the project's name and
        /// whatever the game and plugins add.
        fn buildInspector(self: *Self) void {
            if (self.entity_editor.buildInspector(&self.ui, &self.app, self.gamePtr(), self.dragging(self.ui.builder().allocator), self.plugin_switches.off())) return;
            self.ui.heading(3, project.name);
            if (self.game) |*game| {
                var editor_context = extensions.context(self);
                game.editorUi(&editor_context, &self.ui);
            } else self.ui.muted("The game's library didn't load: see the Console.");
            self.ui.muted("Select an entity in the Hierarchy to see its components.");
        }

        /// Whether `curr_event` is the mouse over the Scene panel in window `slot`: a press, release,
        /// move or wheel there, and not on a workspace control floating over it (a panel menu, the
        /// Scene's toolbar), which takes it instead.
        fn overScene(self: *const Self, slot: Slot, curr_event: sdl3.events.Event) bool {
            const scene = self.sceneRect(slot) orelse return false;
            const at = pointerOf(curr_event) orelse return false;
            return scene.contains(at.x, at.y) and !self.workspace.hasControlAt(slot, at.x, at.y);
        }

        /// The Scene panel's rect in window `slot` for the scene camera: null when `curr_event` is a
        /// press or wheel on a workspace control floating over it, which takes it instead.
        fn sceneRectFor(self: *const Self, slot: Slot, curr_event: sdl3.events.Event) ?ui.Rect {
            const on_control = switch (curr_event) {
                .mouse_button_down, .mouse_wheel, .pinch_begin => if (pointerOf(curr_event)) |at| self.workspace.hasControlAt(slot, at.x, at.y) else false,
                else => false,
            };
            return if (on_control) null else self.sceneRect(slot);
        }

        /// Where the mouse is for a press, release, move or wheel; null for other events.
        fn pointerOf(curr_event: sdl3.events.Event) ?ui.Vec2 {
            return switch (curr_event) {
                .mouse_button_down, .mouse_button_up => |button| .{ .x = button.x, .y = button.y },
                .mouse_motion => |motion| .{ .x = motion.x, .y = motion.y },
                .mouse_wheel => |wheel| .{ .x = wheel.x, .y = wheel.y },
                .pinch_begin, .pinch_update, .pinch_end => blk: {
                    const mouse = sdl3.mouse.getState();
                    break :blk .{ .x = mouse[1], .y = mouse[2] };
                },
                .finger_down, .finger_up, .finger_motion, .finger_canceled => |finger| blk: {
                    const window = sdl3.video.Window.fromId(finger.window_id orelse break :blk null) catch break :blk null;
                    const width, const height = window.getSize() catch break :blk null;
                    break :blk .{ .x = finger.x * @as(f32, @floatFromInt(width)), .y = finger.y * @as(f32, @floatFromInt(height)) };
                },
                else => null,
            };
        }

        /// The Scene panel's rect in window `slot`; null when it is in another window or hidden.
        fn sceneRect(self: *const Self, slot: Slot) ?ui.Rect {
            const placed = self.workspace.placed.scene orelse return null;
            return if (placed.slot == slot) placed.rect else null;
        }

        /// What the Scene panel works on; null without the game's library.
        fn sceneTarget(self: *Self) ?scene_view.Target {
            const game = if (self.game) |*loaded| loaded else return null;
            return .{
                .game = game,
                .app = &self.app,
                .selected = &self.entity_editor.selected,
                .selection_hidden = !self.play_mode.playing() and if (self.entity_editor.selected) |entity| self.entity_editor.view_state.isHidden(&self.app.world, entity) else false,
            };
        }

        /// Point the scene camera at the entity selected in the Hierarchy, close enough to see it.
        fn frameSelected(self: *Self) void {
            const entity = self.entity_editor.selected orelse return;
            const game = if (self.game) |*loaded| loaded else return;
            const placed = game.worldMatrix(&self.app, entity) orelse return;
            // Its size: the longest of its axes, as scaled.
            var radius: f32 = 0.5;
            for (placed[0..3]) |axis| radius = @max(radius, @sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]));
            self.scene_view.camera.frame(.{ placed[3][0], placed[3][1], placed[3][2] }, radius);
        }

        /// `rect` (in UI points) in window pixels.
        // ponytail: uses the main window's pixel density for pop-outs too; read each window's if they sit on screens with different scales.
        fn toPixels(self: *const Self, rect: ui.Rect) ui.Rect {
            const sx, const sy = self.ui.pixel_scale;
            return .{ .x = rect.x * sx, .y = rect.y * sy, .w = rect.w * sx, .h = rect.h * sy };
        }

        /// The window in points, which is where SDL reports the pointer; null while minimized.
        /// Also points `ui` at the window's pixel density so text stays crisp.
        // ponytail: ignores the display's content scale (Windows 125%+); copy weeoui_sdl3.run's scaling if UI looks small there.
        fn uiViewport(self: *Self) !?ui.Rect {
            const width, const height = try self.app.window.window.getSize();
            if (width == 0 or height == 0) return null;
            const pixel_width, const pixel_height = try self.app.window.window.getSizeInPixels();
            const viewport = ui.Rect{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) };
            self.ui.pixel_scale = .{ @as(f32, @floatFromInt(pixel_width)) / viewport.w, @as(f32, @floatFromInt(pixel_height)) / viewport.h };
            self.ui.font.dpi_scale = self.ui.pixel_scale[0];
            self.mono.dpi_scale = self.ui.pixel_scale[0];
            return viewport;
        }
    };
}

test {
    _ = cli;
    _ = @import("input_mappings.zig");
    _ = @import("input_map_asset/input_map_asset.zig");
    _ = @import("animation_dock/animation_dock.zig");
    _ = @import("ui_designer/ui_designer.zig");
    _ = @import("asset_preview.zig");
    _ = @import("model_preview.zig");
    _ = @import("scene_2d.zig");
    _ = @import("tab_bar.zig");
    _ = @import("workspace_tabs.zig");
    _ = @import("assets/creation.zig");
    _ = @import("input_settings.zig");
    _ = @import("game_input.zig");
    _ = @import("viewport_mouse.zig");
    _ = extensions;
    _ = @import("workspace.zig");
    _ = @import("menus.zig");
    _ = @import("panels.zig");
    _ = @import("play_button.zig");
    _ = @import("projects/template.zig");
    _ = @import("projects/job.zig");
    _ = @import("projects/build_output.zig");
    _ = @import("projects/build_steps.zig");
    _ = @import("terminal_steps.zig");
    _ = @import("projects/discovery.zig");
    _ = @import("projects/wizard.zig");
    _ = @import("projects/flow.zig");
    _ = @import("projects/engine.zig");
    _ = @import("projects/upgrades.zig");
    _ = @import("file_manager.zig");
    _ = @import("build_window.zig");
    _ = @import("export/export.zig");
    _ = @import("project_settings.zig");
    _ = @import("devtools_window.zig");
    _ = @import("about_window.zig");
    _ = eggy.ui_hit_test;
    _ = @import("scene_file.zig");
    _ = @import("layout_file.zig");
    _ = @import("play_mode.zig");
    _ = @import("pause_button.zig");
    _ = @import("simulate_button.zig");
    _ = @import("code_editor.zig");
    _ = @import("history.zig");
    _ = @import("plugin_switches.zig");
    _ = icon;
    _ = @import("plugin_manager/plugin_manager.zig");
    _ = @import("dragged.zig");
    _ = @import("scene_view/scene_view.zig");
    _ = @import("save_prompt.zig");
    _ = @import("assets/assets.zig");
    _ = @import("assets/listing.zig");
    _ = @import("assets/icons.zig");
    _ = @import("assets/file_ops.zig");
    _ = @import("assets/project_assets.zig");
    _ = @import("assets/legacy_refs.zig");
    _ = @import("window_placement.zig");
    _ = @import("hot_reload/hot_reload.zig");
    _ = @import("preferences/preferences.zig");
    _ = @import("preferences/window.zig");
    _ = @import("entities/entities.zig");
    _ = @import("page_style.zig");
    _ = @import("projects/source_stamp.zig");
    _ = @import("terminal_view.zig");
    _ = @import("console_log.zig");
    _ = @import("console.zig");
    _ = @import("diagnostic.zig");
}

test "the editor compiles for a project" {
    const project = struct {
        pub const name = "test";
        pub const game_library = struct {
            pub const file_name = "libtest_game.so";
        };
    };
    std.testing.refAllDecls(Editor(project));
}

test "Nerd Font icons draw from the symbols font, and text from the UI's" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    const font = context.font;
    const strike = font.strike(14);
    const missing = strike.glyph('?');
    // Without the symbols font, Powerline's branch icon (private use) is missing.
    var i: usize = 0;
    try std.testing.expect(std.meta.eql(font.next(strike, "\u{e0a0}", &i), missing));
    // With it, Material Design's first icon draws.
    try font.setSymbolsFont(@embedFile("symbols_font"));
    i = 0;
    const material = font.next(strike, "\u{f0001}", &i);
    try std.testing.expect(!std.meta.eql(material, missing) and material.w > 0);
    // Text is still the UI font's.
    i = 0;
    try std.testing.expect(std.meta.eql(font.next(strike, "A", &i), strike.glyph('A')));
}
