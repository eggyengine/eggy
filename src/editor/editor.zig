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
const PopOut = @import("popout.zig").PopOut;
const icon = @import("icon.zig");
const job_zig = @import("projects/job.zig");
const Job = job_zig.Job;
const Upgrades = @import("projects/upgrades.zig").Upgrades;
const file_manager = @import("file_manager.zig");
const BuildWindow = @import("build_window.zig").BuildWindow;
const DevtoolsWindow = @import("devtools_window.zig").DevtoolsWindow;
const window_placement = @import("window_placement.zig");
const source_stamp = @import("projects/source_stamp.zig");
const Console = @import("console.zig").Console;
const panels = @import("panels.zig");

/// `std.Options.logFn` for editor executables: keeps every message for the Console panel.
pub const logFn = @import("console_log.zig").logFn;
const ProjectFlow = @import("projects/flow.zig").ProjectFlow;
const HotGame = @import("hot_reload/hot_reload.zig").HotGame;
const preferences = @import("preferences/preferences.zig");
const entities = @import("entities/entities.zig");
const scene_file = @import("scene_file.zig");
const layout_file = @import("layout_file.zig");
const PlayMode = @import("play_mode.zig").PlayMode;
const assets = @import("assets/assets.zig");
const AssetIcons = @import("assets/icons.zig").Icons;

/// The editor for `project`, which declares `name` and `game_library` (the game library's
/// `file_name`, beside the editor). The game and its plugins run as they do in the runtime,
/// inside a window of dockable panels, from a library the editor swaps for a rebuilt one when
/// their code changes; each can add to the Inspector through `editorUi`.
pub fn Editor(comptime project: type) type {
    return struct {
        gpa: std.mem.Allocator,
        app: eggy.App,
        /// The game and its plugins, from their library; null if it couldn't load (logged).
        game: ?HotGame,
        /// When the game's library was built, to tell whether a rebuild changed it.
        game_modified: ?std.Io.Timestamp = null,
        /// Whether the game is playing, and the scene to go back to when it stops.
        play_mode: PlayMode = .{},
        /// The scene open in the project, if any (with no project, none).
        open_scene: ?scene_file.OpenScene = null,
        /// Where the user's and the project's preferences are (their values are in `app`).
        preference_folders: preferences.Folders,
        /// Edit > Preferences, while open.
        preferences_window: ?*preferences.PreferencesWindow = null,
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
        /// The project this editor opened (`--project <dir>`), from its `eggy.zon`.
        project: ?workspace_zig.Project = null,
        /// The build started when the window regains focus, while it runs or once it made a new
        /// editor (see `rebuildState`).
        rebuild: ?*Job = null,
        /// The project's sources as the last build (or the one that made this editor) saw them;
        /// refocusing rebuilds only once they change.
        built_sources: source_stamp.Stamp = .{},
        /// Help > DevTools' window, while open.
        devtools_window: ?*DevtoolsWindow = null,
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
        /// The window SDL is sending typed text to (see `syncTextInput`), by slot; null when none.
        text_input_slot: ?Slot = null,
        /// When a double-click on the title bar asked to maximize or restore, until that is done.
        maximize_pending_ns: ?u64 = null,

        const Self = @This();
        /// SDL's default double-click time.
        const double_click_ns = 500 * std.time.ns_per_ms;
        const title = project.name ++ " - eggy editor";

        pub fn init(gpa: std.mem.Allocator, args: []const [*:0]const u8) !Self {
            var app = try eggy.App.init(gpa, title);
            errdefer app.deinit();
            const opened_project = try openProject(gpa, app.window.window, args);
            errdefer if (opened_project) |opened| freeProject(gpa, opened);
            // Where the editor that reloaded into this one was (see `launchRebuilt`), else maximized.
            if (window_placement.fromArgs(args)) |placement| placement.apply(app.window.window) else app.window.window.maximize() catch |err| std.log.warn("cannot maximize the editor: {t}", .{err});
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
            var console_ui = ui.Context.initWithFont(gpa, context.font);
            errdefer console_ui.deinit();
            var hierarchy_ui = ui.Context.initWithFont(gpa, context.font);
            errdefer hierarchy_ui.deinit();
            var assets_ui = ui.Context.initWithFont(gpa, context.font);
            errdefer assets_ui.deinit();
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
            _ = layout_file.load(gpa, preference_folders.global, &workspace.dock);
            preferences.load(gpa, &app.preference_values, preference_folders);
            console.levels[@intFromEnum(std.log.Level.debug)] = preferences.editor(&app.preference_values).show_debug_logs;

            // The game, from its library beside the editor, and the scene open last.
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
                preferences.writeRegistry(gpa, preference_folders, loaded.preference_manifests) catch |err| std.log.warn("cannot update .eggy/plugins.zon: {t}", .{err});
            }
            // The project's scene first, so the game's plugins start among its entities.
            if (game) |*loaded| {
                if (opened_project) |opened| {
                    open_scene = .{ .gpa = gpa, .project_dir = opened.dir };
                    open_scene.?.reopen(&app.world, loaded.sceneAccess());
                }
                loaded.start(&app);
            }
            const upgrades = Upgrades.init(gpa, if (opened_project) |opened| opened.dir else null, @import("build_options").source_dir);
            var self = Self{ .gpa = gpa, .game = game, .game_modified = modifiedAt(library_path), .app = app, .ui = context, .mono = mono, .console_ui = console_ui, .hierarchy_ui = hierarchy_ui, .assets_ui = assets_ui, .assets_panel = .init(gpa), .asset_icons = asset_icons, .entity_editor = .init(gpa), .console = console, .plugin_pages = plugin_pages, .workspace = workspace, .frame = frame, .scene = scene, .overlay = overlay, .project = opened_project, .editor_modified = if (opened_project) |opened| editorModified(gpa, opened) else null, .upgrades = upgrades, .preference_folders = preference_folders, .open_scene = open_scene };
            self.built_sources = self.sourcesNow();
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.game) |*game| game.deinit(&self.app);
            if (self.project_flow) |flow| flow.close(&self.app.graphics);
            if (self.build_window) |window| window.close(&self.app.graphics);
            if (self.devtools_window) |window| window.close(&self.app.graphics);
            if (self.preferences_window) |window| window.close(&self.app.graphics);
            // The dock as this user left it, for the next editor.
            layout_file.save(self.gpa, self.preference_folders.global, &self.workspace.dock);
            self.preference_folders.deinit(self.gpa);
            if (self.open_scene) |*scene| scene.deinit();
            self.play_mode.deinit();
            if (self.rebuild) |job| job.deinit();
            if (self.picked_project.swap(null, .acq_rel)) |path| std.heap.c_allocator.free(std.mem.span(path));
            if (self.project) |opened| freeProject(self.gpa, opened);
            self.upgrades.deinit();
            for (&self.popouts) |*popout| if (popout.*) |*open| {
                open.close(&self.app.graphics);
                popout.* = null;
            };
            // The overlay's and scene's GPU resources must outlive any frame still in flight.
            self.app.graphics.queue.waitIdle() catch {};
            self.scene.deinit();
            self.overlay.deinit();
            self.workspace.deinit();
            for (&self.plugin_pages) |*page_ui| page_ui.deinit();
            self.console.deinit();
            self.console_ui.deinit();
            self.hierarchy_ui.deinit();
            self.assets_ui.deinit();
            self.assets_panel.deinit();
            self.asset_icons.deinit(self.gpa);
            self.entity_editor.deinit();
            self.mono.deinit();
            self.gpa.destroy(self.mono);
            self.ui.deinit();
            self.app.deinit();
            self.gpa.destroy(self.frame);
        }

        pub fn iterate(self: *Self) !sdl3.AppResult {
            // While a new project is created, only its loading screen shows. Hidden windows aren't
            // drawn to: presenting to one can block until it is shown again.
            if (self.project_flow) |flow| if (flow.isWorking()) {
                self.setHidden(true);
                return self.updateProjectFlow(flow);
            };
            self.setHidden(false);

            try self.app.graphics.syncSize(self.app.window);
            self.applyPendingMaximize(false);
            const viewport = try self.uiViewport() orelse return .run; // minimized
            // The game stays paused while the Build progress window is up.
            // The game runs only while playing; otherwise only its editor tools do.
            if (self.build_window == null) if (self.game) |*game| {
                if (self.play_mode.playing()) game.update(&self.app) else game.editorUpdate(&self.app);
            };
            try self.syncPopOuts();

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
            self.ui.theme = switch (preferences.editor(&self.app.preference_values).theme) {
                .system => weeoui_sdl3.systemTheme(),
                .light => .{},
                .dark => ui.Theme.dark,
            };
            self.ui.theme.text_size = 12;
            self.ui.theme.small_text_size = 11;
            self.workspace.engine_label = self.upgrades.label;
            self.workspace.scene_name = if (self.open_scene) |*scene| scene.name() else null;
            self.workspace.can_upgrade = self.upgrades.can_upgrade;
            self.workspace.can_link = self.upgrades.can_link;
            self.workspace.developer_known = self.upgrades.developer_dir != null;
            const modifiers = sdl3.keyboard.getModState();
            self.workspace.shift_held = modifiers.left_shift or modifiers.right_shift;
            try self.workspace.build(viewport, window_viewports, self.ui.font);
            // Help > DevTools, on this frame's main window, before that draws their highlight.
            self.workspace.devtools = null;
            if (self.devtools_window) |window| {
                const now = sdl3.timer.getNanosecondsSinceInit();
                if (self.frame_start_ns != 0) window.tools.recordFrame(@as(f32, @floatFromInt(now - self.frame_start_ns)) / std.time.ns_per_ms);
                self.frame_start_ns = now;
                try window.update(&self.app.graphics, &self.ui, self.workspace.roots[main_slot].?);
                self.workspace.devtools = &window.tools;
            }
            self.frame.* = self.workspace.titlebarFrame();

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
                    panels.console_page => self.console.build(page_ui),
                    panels.hierarchy_page => self.entity_editor.buildHierarchy(page_ui, &self.app, self.gamePtr()),
                    panels.assets_page => if (self.assets_panel.build(page_ui, if (self.project) |opened| opened.dir else null, &self.asset_icons, self.openScenePath())) |action| self.applyAssetAction(action),
                    else => if (self.game) |*game| game.editorPanelUi(index - panels.first_plugin_page, page_ui),
                }
                vertices.* = try page_ui.render();
            }
            self.syncTextInput();

            // Draw each window.
            try self.present(main_slot, &self.app.graphics.surface, &self.overlay, viewport, pages);
            for (&self.popouts, 0..) |*popout, i| if (popout.*) |*open| {
                const area = window_viewports[i] orelse continue;
                try open.surface.syncSize(self.app.graphics.queue, open.window);
                try self.present(workspace_zig.windowSlot(i), &open.surface, &open.overlay, area, pages);
            };
            // A folder chosen in File > Open Project's picker: open it, linking it first for Open
            // Project with Developer Eggy once that is confirmed.
            if (self.picked_project.swap(null, .acq_rel)) |path| {
                defer std.heap.c_allocator.free(std.mem.span(path));
                const dir = std.mem.span(path);
                const action: job_zig.Action = if (self.picking_to_link) .{ .link = self.upgrades.developer_dir orelse "" } else .open;
                const confirmed = action == .open or self.upgrades.confirmLink(self.app.window.window, std.fs.path.basename(dir));
                if (self.project_flow == null and confirmed) self.project_flow = try ProjectFlow.open(self.gpa, &self.app.graphics, self.ui.font, self.mono, dir, action);
            }
            // File > New/Open Project's window, if open.
            if (self.project_flow) |flow| if (try self.updateProjectFlow(flow) == .success) return .success;
            // Edit > Preferences, if open.
            if (self.preferences_window) |window| try window.update(&self.app.graphics, &self.ui, try self.preferenceSections(frame_arena.allocator()), &self.app.preference_values, self.preference_folders);
            // The Build progress window, if open.
            if (self.build_window) |window| if (try self.updateBuildWindow(window, frame_arena.allocator())) return .success;

            const pointer = self.workspace.pointer;
            const hovered = self.pageAt(self.workspace.pointer_slot, pointer.x, pointer.y);
            weeoui_sdl3.setCursor(self.workspace.dock.cursor() orelse if (hovered) |index| self.page(index).cursor else .default);
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

        fn pickedProject(self: ?*Self, files: ?[]const [*:0]const u8, _: ?usize, failed: bool) void {
            const chosen = files orelse return;
            if (failed or chosen.len == 0) return;
            const copy = std.heap.c_allocator.dupeZ(u8, std.mem.span(chosen[0])) catch return;
            if (self.?.picked_project.swap(copy.ptr, .acq_rel)) |old| std.heap.c_allocator.free(std.mem.span(old));
        }

        /// Open the editor `job` rebuilt in place of this one, where this one's window is.
        fn launchRebuilt(self: *Self, job: *Job) !void {
            var buffer: [64]u8 = undefined;
            const placement = window_placement.Placement.of(self.app.window.window) orelse return job.launchEditor(&.{});
            try job.launchEditor(&.{ window_placement.flag, try placement.format(&buffer) });
        }

        /// Play: keep the scene, then run the game.
        fn startPlaying(self: *Self) void {
            const game = if (self.game) |*loaded| loaded else {
                self.workspace.playing = false;
                return std.log.err("play: the game's library isn't loaded", .{});
            };
            self.play_mode.play(self.gpa, &self.app, game) catch |err| {
                self.workspace.playing = false;
                return std.log.err("cannot start playing: {t}", .{err});
            };
            self.workspace.playing = true;
        }

        /// Stop: the game starts over on the scene kept by Play. Entities are made anew, so the
        /// selection goes.
        fn stopPlaying(self: *Self) void {
            self.workspace.playing = false;
            if (!self.play_mode.playing()) return;
            const game = if (self.game) |*loaded| loaded else return;
            self.play_mode.stop(&self.app, game);
            self.entity_editor.selected = null;
        }

        /// The open scene's path, relative to the project; null with none.
        fn openScenePath(self: *const Self) ?[]const u8 {
            return if (self.open_scene) |*scene| scene.path else null;
        }

        /// Carry out what the Assets panel asked: open or start a scene, or show a file.
        fn applyAssetAction(self: *Self, action: assets.Action) void {
            const opened = self.project orelse return;
            switch (action) {
                .open_scene, .create_scene => {
                    self.stopPlaying();
                    const scene = if (self.open_scene) |*open| open else return;
                    const game = if (self.game) |*loaded| loaded else return std.log.err("the game's library isn't loaded, so scenes can't be opened", .{});
                    const result = switch (action) {
                        .open_scene => |path| scene.open(path, &self.app.world, game.sceneAccess()),
                        else => scene.create(&self.app.world, game.sceneAccess()),
                    };
                    result catch |err| return std.log.err("cannot open the scene: {t}", .{err});
                    self.entity_editor.selected = null;
                },
                .reveal => |path| {
                    // A file shows as its folder.
                    const folder = std.fs.path.join(self.gpa, &.{ opened.dir, if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[0..slash] else "" }) catch return;
                    defer self.gpa.free(folder);
                    file_manager.showFolder(self.gpa, folder) catch |err| std.log.err("cannot show {s}: {t}", .{ path, err });
                },
            }
        }

        /// File > Save (Ctrl+S): write the world to the open scene, or a new one.
        fn saveScene(self: *Self) void {
            // What happened while playing isn't the scene: stop first.
            if (self.play_mode.playing()) return std.log.info("save: stop playing first; Stop puts the scene back as it was", .{});
            const scene = if (self.open_scene) |*open| open else return std.log.info("save: open a project first; scenes are kept in it", .{});
            const game = if (self.game) |*loaded| loaded else return std.log.err("save: the game's library isn't loaded, so its components can't be saved", .{});
            scene.save(&self.app.world, game.sceneAccess()) catch |err| std.log.err("cannot save the scene: {t}", .{err});
        }

        /// The Preferences window's sections: the editor's, then (with a project) each plugin's that
        /// has any, the game's titled after the project. In `arena`.
        fn preferenceSections(self: *const Self, arena: std.mem.Allocator) ![]const preferences.Section {
            var sections: std.ArrayList(preferences.Section) = .empty;
            try sections.append(arena, .{ .title = "Editor", .subtitle = "How the editor looks and behaves.", .manifest = preferences.editor_manifest });
            // Plugins' preferences are the project's: without one, there is nowhere to keep them.
            if (self.project == null) return sections.items;
            if (self.game) |game| for (game.preference_manifests) |manifest| {
                if (std.mem.eql(u8, manifest.key, "game")) {
                    try sections.append(arena, .{ .title = if (self.project) |opened| opened.title else "Game", .subtitle = "Your game's own preferences.", .manifest = manifest });
                } else {
                    try sections.append(arena, .{ .title = try preferences.displayName(arena, manifest.key), .subtitle = try std.fmt.allocPrint(arena, "From the {s} plugin.", .{manifest.key}), .manifest = manifest });
                }
            };
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
            const scene_px = if (self.workspace.placed.scene) |placed| if (placed.slot == slot) self.toPixels(placed.rect) else null else null;
            if (scene_px) |rect| try self.scene.render(&self.app.graphics, frame.cmd, .{ .width = @intFromFloat(@round(rect.w)), .height = @intFromFloat(@round(rect.h)) });

            // The UI under the Scene panel, the scene texture, then the UI over it.
            try overlay.upload(frame.cmd, self.ui.font, drawn.vertices, viewport);
            try frame.cmd.beginRenderPass(.{ .label = "editor ui", .color_attachments = &.{.{ .view = frame.target, .load_op = .load, .store_op = .store }} });
            overlay.draw(frame.cmd, frame.extent, 0, drawn.scene_at);
            if (scene_px) |rect| self.scene.draw(frame.cmd, rect, frame.extent);
            overlay.draw(frame.cmd, frame.extent, drawn.scene_at, drawn.vertices.len - drawn.scene_at);
            frame.cmd.endRenderPass();
            try surface.endFrame(self.app.graphics.queue, frame);
        }

        /// Open an OS window for each panel the dock has popped out, and close those it took back.
        fn syncPopOuts(self: *Self) !void {
            for (self.workspace.dock.windows, &self.popouts, 0..) |wanted, *popout, i| {
                if (wanted == null) {
                    if (popout.*) |*open| open.close(&self.app.graphics);
                    popout.* = null;
                } else if (popout.* == null) {
                    popout.* = try PopOut.open(&self.app.graphics, self.ui.font, self.workspace.windowTitle(i), wanted.?.size, .{ .resizable = true });
                    icon.apply(popout.*.?.window.window);
                }
            }
        }

        pub fn event(self: *Self, curr_event: sdl3.events.Event) !sdl3.AppResult {
            // File > New/Open Project's window takes its own events; closing it, or Escape, cancels.
            if (self.project_flow) |flow| {
                if (flow.closeRequested(curr_event)) {
                    flow.close(&self.app.graphics);
                    self.project_flow = null;
                    return .run;
                }
                if (flow.handle(curr_event)) return .run;
            }
            // While the Build progress window is up, it takes its own events and the editor no
            // input. Closing it cancels a build under way.
            if (self.build_window) |window| {
                if (curr_event == .window_close_requested and window.window.owns(curr_event)) {
                    if (self.buildRunning()) self.cancelBuild();
                    self.closeBuildWindow();
                    return .run;
                }
                if (window.handle(curr_event)) return .run;
                if (weeoui_sdl3.translate(curr_event) != null) return .run;
            }
            // Edit > Preferences' window takes its own events; closing it, or Escape, closes it.
            if (self.preferences_window) |window| {
                if (window.closeRequested(curr_event)) {
                    window.close(&self.app.graphics);
                    self.preferences_window = null;
                    return .run;
                }
                if (window.handle(curr_event)) return .run;
            }
            // Help > DevTools' window takes its own events; while inspecting, the main window's
            // pointer moves and presses go to it too.
            if (self.devtools_window) |window| {
                if (window.closeRequested(curr_event)) {
                    self.toggleDevtools();
                    return .run;
                }
                if (window.handle(curr_event)) return .run;
                if (self.slotOf(curr_event) == main_slot) if (weeoui_sdl3.translate(curr_event)) |input| switch (input) {
                    .pointer_move => |p| window.pointerMove(p.x, p.y),
                    .pointer_down => |down| if (window.pointerDown(down.position.x, down.position.y)) return .run,
                    else => {},
                };
            }
            const slot = self.slotOf(curr_event);

            // F2 renames the entity selected in the Hierarchy (Weeoui's keys don't include it).
            if (curr_event == .key_down and self.focused_page == panels.hierarchy_page) if (curr_event.key_down.key) |key| if (key == .func2) {
                self.entity_editor.renameSelected();
                return .run;
            };

            // A pop-out window's close button docks its panels back into the main window.
            if (slot != main_slot and curr_event == .window_close_requested) {
                self.workspace.dock.redock(.{ .window = @intCast(slot - 1) });
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
                .quit => return .success,
                .window => |button| if (weeoui_sdl3.windowAction(self.app.window.window, button)) return .success,
                .play => |playing| if (playing) self.startPlaying() else self.stopPlaying(),
                .new_project => if (self.project_flow == null) {
                    self.project_flow = try ProjectFlow.create(self.gpa, &self.app.graphics, self.ui.font, self.mono);
                },
                .reload => if (try self.forceReload()) return .success,
                .open_project, .open_project_linked => |_, tag| if (self.project_flow == null) {
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
                .save => self.saveScene(),
                .preferences => if (self.preferences_window == null) {
                    self.preferences_window = preferences.PreferencesWindow.open(self.gpa, &self.app.graphics, self.ui.font) catch |err| blk: {
                        std.log.err("cannot open Preferences: {t}", .{err});
                        break :blk null;
                    };
                },
                .link_developer => if (self.upgrades.can_link) try self.linkDeveloper() else self.upgrades.logUnavailable(.link),
                else => {},
            }
            if (curr_event == .window_focus_lost and self.focus_lost_ms == null) self.focus_lost_ms = sdl3.timer.getMillisecondsSinceInit();
            if (curr_event == .window_focus_gained and self.cameBack()) {
                // Another editor may have unpacked a newer Eggy meanwhile.
                self.upgrades.refresh();
                try self.rebuildOnFocus();
            }

            // The pages get the rest, and every pointer move so their hover state stays current.
            if (outcome == .ignored or curr_event == .mouse_motion) self.routeToPages(slot, curr_event);
            // Input reaches the game only while it plays.
            if (self.play_mode.playing()) if (self.game) |*game| game.event(&self.app, curr_event);
            return self.app.event(curr_event);
        }

        /// The project named by `--project <dir>` in `args`, if any, read from its `eggy.zon`
        /// (caller-owned; see `freeProject`), after titling `window` after it.
        fn openProject(gpa: std.mem.Allocator, window: sdl3.video.Window, args: []const [*:0]const u8) !?workspace_zig.Project {
            const dir = for (args, 0..) |arg, i| {
                if (std.mem.eql(u8, std.mem.span(arg), "--project") and i + 1 < args.len) break std.mem.span(args[i + 1]);
            } else return null;
            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.io();
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
        fn startBuild(self: *Self, action: job_zig.Action) !void {
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
            if (self.reload_when_built and status.stage == .done) {
                try self.launchRebuilt(job);
                return true;
            }
            switch (try window.update(&self.app.graphics, &self.ui, status, self.workspace.build_state == .ready)) {
                .none => {},
                .close => self.closeBuildWindow(),
                .cancel => {
                    self.cancelBuild();
                    self.closeBuildWindow();
                },
                .reload => {
                    try self.launchRebuilt(job);
                    return true;
                },
            }
            return false;
        }

        fn closeBuildWindow(self: *Self) void {
            const window = self.build_window orelse return;
            window.close(&self.app.graphics);
            self.build_window = null;
        }

        /// Whether `rebuild` is still under way.
        fn buildRunning(self: *Self) bool {
            const job = self.rebuild orelse return false;
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const stage = (job.status(arena.allocator()) catch return false).stage;
            return stage != .done and stage != .failed;
        }

        /// Stop `rebuild` (the build is killed) and forget it.
        fn cancelBuild(self: *Self) void {
            self.reload_when_built = false;
            const job = self.rebuild orelse return;
            job.deinit();
            self.rebuild = null;
        }

        /// The title bar's Reload: open the rebuilt editor if a rebuild made one; otherwise
        /// rebuild (in the Build progress window) and open the result, changed or not. Returns
        /// whether the editor should quit, as the new one is open.
        fn forceReload(self: *Self) !bool {
            if (self.workspace.build_state == .ready) if (self.rebuild) |job| {
                try self.launchRebuilt(job);
                return true;
            };
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
                kept = eggy.scene.Scene.capture(self.gpa, &self.app.world, game.sceneAccess(), null) catch |err| blk: {
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
            preferences.writeRegistry(self.gpa, self.preference_folders, game.preference_manifests) catch |err| std.log.warn("cannot update .eggy/plugins.zon: {t}", .{err});
            game.start(&self.app);
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
            if (input == .pointer_down) {
                const at = input.pointer_down.position;
                if (self.pageAt(slot, at.x, at.y)) |index| self.focused_page = index;
            }
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
                // Assets' double-clicks, before its UI.
                if (index == panels.assets_page) {
                    const result = self.assets_panel.pointer(&self.assets_ui, input);
                    if (result.action) |action| self.applyAssetAction(action);
                    if (result.used) continue;
                }
                // The Hierarchy's right-clicks, double-clicks, drags and keys, before its UI.
                if (index == panels.hierarchy_page) {
                    const used = switch (input) {
                        .key_down => |key| self.entity_editor.hierarchyKey(&self.app, self.gamePtr(), key),
                        .pointer_down, .pointer_move, .pointer_up => self.entity_editor.hierarchyPointer(&self.hierarchy_ui, &self.app, self.gamePtr(), input),
                        else => false,
                    };
                    if (used) continue;
                }
                if (index == panels.inspector_page) weeoui_sdl3.handleEvent(&self.ui, curr_event) else self.page(index).handle(input);
            }
        }

        /// Have SDL send typed text to the window whose page has a text field focused, and only
        /// then: it is what a text field types with, and the on-screen keyboard follows it.
        fn syncTextInput(self: *Self) void {
            var wanted: ?Slot = null;
            for (0..self.pageCount()) |index| {
                const placed = self.workspace.placed.pages[index] orelse continue;
                if (self.page(index).wants_text) wanted = placed.slot;
            }
            if (std.meta.eql(wanted, self.text_input_slot)) return;
            if (self.text_input_slot) |slot| if (self.windowOf(slot)) |window| sdl3.keyboard.stopTextInput(window) catch {};
            if (wanted) |slot| if (self.windowOf(slot)) |window| sdl3.keyboard.startTextInput(window) catch {};
            self.text_input_slot = wanted;
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
                    return main_slot;
                },
            };
            for (self.popouts, 0..) |popout, i| if (popout) |open| if (open.id == id) return workspace_zig.windowSlot(i);
            return main_slot;
        }

        /// The Inspector panel: the entity selected in the Hierarchy, else the project's name and
        /// whatever the game and plugins add.
        fn buildInspector(self: *Self) void {
            if (self.entity_editor.buildInspector(&self.ui, &self.app, self.gamePtr())) return;
            self.ui.heading(3, project.name);
            if (self.game) |*game| game.editorUi(&self.ui) else self.ui.muted("The game's library didn't load: see the Console.");
            self.ui.muted("Select an entity in the Hierarchy to see its components.");
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
    _ = @import("workspace.zig");
    _ = @import("menus.zig");
    _ = @import("panels.zig");
    _ = @import("play_button.zig");
    _ = @import("projects/template.zig");
    _ = @import("projects/job.zig");
    _ = @import("projects/wizard.zig");
    _ = @import("projects/flow.zig");
    _ = @import("projects/engine.zig");
    _ = @import("projects/upgrades.zig");
    _ = @import("file_manager.zig");
    _ = @import("build_window.zig");
    _ = @import("devtools_window.zig");
    _ = @import("hit_test.zig");
    _ = @import("scene_file.zig");
    _ = @import("layout_file.zig");
    _ = @import("play_mode.zig");
    _ = @import("assets/assets.zig");
    _ = @import("assets/listing.zig");
    _ = @import("assets/icons.zig");
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
