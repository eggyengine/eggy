//! File > Export: the open project's game built to ship, laid out like a build-settings window.
//! The platforms run down the left (Eggy's own and those plugins add), the chosen one's settings
//! (and any plugins add) on the right, the scene the game starts in above them, and Export
//! below. It asks which scene starts first only when the project has no default scene yet.
//! Export runs `zig build export` (see `src/build/export.zig`) in the background, showing a bar
//! for the whole build, the step under way and, on request, Zig's output. Exports land in the
//! project's `zig-out/export/`.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const ToolWindow = @import("../tool_window.zig").ToolWindow;
const job_zig = @import("../projects/job.zig");
const sdk_location = @import("sdk_location.zig");
const Job = job_zig.Job;
const terminal_view = @import("../terminal_view.zig");
const TerminalView = terminal_view.TerminalView;
const file_manager = @import("../file_manager.zig");
const listing = @import("../assets/listing.zig");
const project_settings = @import("../project_settings.zig");
const page_style = @import("../page_style.zig");
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
pub const platforms = @import("platforms.zig");
const Icons = @import("icons.zig").Icons;
const setting_rows = eggy.setting_rows;
const SettingRows = setting_rows.SettingRows;
const restyle = page_style.restyle;
const smallText = page_style.smallText;

const sidebar_width: f32 = 190;
const icon_size: f32 = 20;
/// The footer: its line, the gap under it and its buttons.
const footer_height: f32 = 1 + page_gap + 36;
const page_gap: f32 = 12;

/// The platform shown: one of Eggy's, or a plugin's by its key (owned).
const Selected = union(enum) { builtin: platforms.Platform, plugin: []u8 };

/// What a frame left for the editor to do.
pub const Result = struct {
    /// The project's default scene changed (caller-owned, for the editor to record).
    change: ?project_settings.Change,
    /// Whether the window stays open.
    open: bool,
    /// Project Settings was pressed: show Preferences on its Project section.
    project_settings: bool,
};

pub const ExportWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    terminal: TerminalView,
    icons: Icons,
    /// The project's folder, owned.
    project_dir: []u8,
    selected: Selected = .{ .builtin = platforms.this_system },
    /// Each of Eggy's platforms' settings, and one set shared by plugins' platforms.
    settings: [platforms.count]platforms.Settings = platforms.Settings.defaults(),
    plugin_settings: platforms.Settings = .{ .architecture = .x86_64 },
    /// The project's scenes (in `scenes_arena`), and which it starts in.
    scenes: []const []const u8 = &.{},
    /// Each scene as the window names it: inside `resources/`, without `.scene.zon`.
    scene_labels: []const []const u8 = &.{},
    scenes_arena: std.heap.ArenaAllocator,
    scene: usize = 0,
    /// Whether the project names a default scene; without one the window asks for it first.
    has_default_scene: bool = false,
    /// The default scene changed this frame, for `update` to hand back.
    change: ?project_settings.Change = null,
    /// The export under way or finished; none until Export is pressed.
    job: ?*Job = null,
    /// The platform being exported for, as the progress heading names it.
    exporting_for: [128]u8 = undefined,
    exporting_for_len: usize = 0,
    show_output: bool = false,
    /// Why the last Export didn't start.
    problem: ?[]const u8 = null,
    closing: bool = false,
    wants_project_settings: bool = false,
    /// The platforms and the one shown scroll apart.
    sidebar_scroll: ui.Layout.ScrollState = .{},
    platform_scroll: ui.Layout.ScrollState = .{},
    /// The SDK folder chosen in the system's picker, set from its thread and taken on the
    /// next frame (C allocator).
    picked_sdk: std.atomic.Value(?[*:0]u8) = .init(null),

    /// Open the window for the project in `project_dir`. On the heap, as the output view keeps a
    /// pointer to itself.
    /// Copies `project_dir`; shared graphics/fonts must outlive the window.
    /// Allocation/window errors propagate; failure to discover scenes leaves an empty list.
    ///
    /// ```zig
    /// // Editor host with an open project:
    /// const export_ui = try ExportWindow.open(gpa, graphics, font, mono, project_dir);
    /// defer export_ui.close(graphics);
    /// ```
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, mono: *const ui.Font, project_dir: []const u8) !*ExportWindow {
        const self = try gpa.create(ExportWindow);
        errdefer gpa.destroy(self);
        const dir = try gpa.dupe(u8, project_dir);
        errdefer gpa.free(dir);
        self.* = .{
            .gpa = gpa,
            .window = try ToolWindow.open(gpa, graphics, font, "Export", .{ 780, 500 }, .{ .resizable = true }),
            .terminal = .init(gpa, mono),
            .icons = .load(gpa, font),
            .project_dir = dir,
            .scenes_arena = .init(gpa),
        };
        self.findScenes();
        // The macOS SDK this computer was last given, in any project.
        var sdk_buffer: [512]u8 = undefined;
        if (sdk_location.load(&sdk_buffer)) |path| self.settings[@backingInt(platforms.Platform.macos)].sdk.set(path) catch {};
        return self;
    }

    /// Close the window, stopping an export under way.
    /// Releases any unclaimed settings change and all owned state, including `self`;
    /// call before destroying shared fonts or graphics.
    ///
    /// ```zig
    /// export_ui.close(graphics); // Do not use the pointer afterward.
    /// ```
    pub fn close(self: *ExportWindow, graphics: *eggy.Graphics) void {
        self.rememberSdk();
        if (self.job) |job| job.deinit();
        if (self.change) |change| {
            self.gpa.free(change.before);
            self.gpa.free(change.after);
        }
        if (self.selected == .plugin) self.gpa.free(self.selected.plugin);
        if (self.picked_sdk.swap(null, .acq_rel)) |path| std.heap.c_allocator.free(std.mem.span(path));
        self.icons.deinit();
        self.scenes_arena.deinit();
        self.terminal.deinit();
        self.window.close(graphics);
        self.gpa.free(self.project_dir);
        self.gpa.destroy(self);
    }

    /// Handle `curr_event` if it is for this window; returns whether it was. The output view
    /// sees input first, so it can select and copy. Closing the window asks to close it.
    /// The host must read `update().open` and perform destruction; events are not retained.
    ///
    /// ```zig
    /// if (export_ui.handle(event)) return; // Editor event loop.
    /// ```
    pub fn handle(self: *ExportWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (curr_event == .window_close_requested) {
            self.closing = true;
            return true;
        }
        if (self.show_output) if (weeoui_sdl3.translate(curr_event)) |input| if (self.terminal.handle(input)) return true;
        self.window.handle(curr_event);
        return true;
    }

    /// Draw a frame, with the plugins' platforms and settings from `game` (null while the
    /// game's library isn't loaded) through `editor`, a context for this frame only.
    /// The change's texts were allocated with the window's `gpa`; transfer them to history or
    /// free them. Status/render failures propagate before any pending change transfers.
    ///
    /// ```zig
    /// const result = try export_ui.update(graphics, style, game, &editor_context);
    /// if (result.change) |change|
    ///     history.recordProjectSettings(change.before, change.after, now_ms);
    /// if (!result.open) export_ui.close(graphics);
    /// ```
    pub fn update(self: *ExportWindow, graphics: *eggy.Graphics, style: *const ui.Context, game: ?*HotGame, editor: *eggy.editor.Context) !Result {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const status: ?job_zig.Status = if (self.job) |job| try job.status(arena.allocator()) else null;
        const Page = struct {
            window: *ExportWindow,
            status: ?job_zig.Status,
            game: ?*HotGame,
            editor: *eggy.editor.Context,
            /// Internal synchronous tool-page adapter; borrows its fields for this frame.
            ///
            /// ```zig
            /// // Inside update, with its current status snapshot:
            /// try self.window.present(graphics, style, &page);
            /// ```
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.window.build(context, page.status, page.game, page.editor);
            }
        };
        var page = Page{ .window = self, .status = status, .game = game, .editor = editor };
        try self.window.present(graphics, style, &page);
        defer {
            self.change = null;
            self.wants_project_settings = false;
        }
        return .{ .change = self.change, .open = !self.closing, .project_settings = self.wants_project_settings };
    }

    fn build(self: *ExportWindow, context: *ui.Context, status: ?job_zig.Status, game: ?*HotGame, editor: *eggy.editor.Context) void {
        if (status) |current| return self.buildProgress(context, current);
        if (!self.has_default_scene) return self.chooseScene(context);
        // A plugin platform gone with a rebuilt library falls back to this system.
        if (self.selected == .plugin and self.pluginIndex(game) == null) self.select(.{ .builtin = platforms.this_system });

        self.takePickedSdk();

        // The platforms and the one shown, each scrolling on its own above the footer.
        const pane_height = page_style.pageHeight(context) - footer_height - page_gap;
        context.begin(.column);
        context.begin(.row);
        self.buildSidebar(context, game, pane_height);
        context.beginScroll(&self.platform_scroll, pane_height);
        self.buildStartScene(context);
        self.buildPlatform(context, game, editor);
        context.end();
        restyle(context, .{ .grow = 1, .gap = 16 });
        context.end();
        restyle(context, .{ .direction = .row, .gap = 20, .align_items = .start });
        self.buildFooter(context, game);
        context.end();
        restyle(context, .{ .gap = page_gap });
    }

    /// First, without a default scene: which scene the game starts in, kept as the default.
    fn chooseScene(self: *ExportWindow, context: *ui.Context) void {
        context.heading(3, "Which scene starts first?");
        if (self.scenes.len == 0) {
            context.muted("The project has no scenes. Make one in the Assets panel, then export.");
            if (context.buttonVariant("Close", .outline)) self.closing = true;
            return;
        }
        context.muted("The game opens in this scene on launch. It is kept as the project's default scene, which you can change here or in Project Settings.");
        _ = context.select("Starts in", self.scene_labels, &self.scene);
        context.begin(.row);
        defer page_style.endRow(context);
        if (context.button("Continue")) {
            self.keepDefaultScene();
            self.has_default_scene = true;
        }
        if (context.buttonVariant("Cancel", .outline)) self.closing = true;
    }

    /// The scene the game starts in, above the platforms: changing it changes the default.
    fn buildStartScene(self: *ExportWindow, context: *ui.Context) void {
        var rows = SettingRows{};
        setting_rows.beginGroup(context);
        rows.begin(context, "Starts in", "The scene the game opens in: the project's default scene.");
        if (context.select("##start scene", self.scene_labels, &self.scene)) self.keepDefaultScene();
        rows.end(context);
        setting_rows.endGroup(context);
    }

    /// The platforms, each with its icon, the one shown lit.
    fn buildSidebar(self: *ExportWindow, context: *ui.Context, game: ?*HotGame, height: f32) void {
        context.beginScroll(&self.sidebar_scroll, height);
        context.muted("Platforms");
        smallText(context, 12);
        restyle(context, .{ .padding = .{ .left = 8, .bottom = 4 } });
        inline for (comptime std.enums.values(platforms.Platform)) |platform| {
            const shown = self.selected == .builtin and self.selected.builtin == platform;
            if (self.sidebarItem(context, platforms.title(platform), "builtin " ++ @tagName(platform), self.icons.builtin(platform, context.theme), shown)) self.select(.{ .builtin = platform });
        }
        if (game) |loaded| for (loaded.export_platforms) |platform| {
            const shown = self.selected == .plugin and std.mem.eql(u8, self.selected.plugin, platform.key);
            const id_text = std.fmt.allocPrint(context.builder().allocator, "plugin {s}", .{platform.key}) catch continue;
            if (self.sidebarItem(context, platform.title, id_text, self.icons.plugin(platform.key, platform.icon_png, context.theme), shown)) {
                const key = self.gpa.dupe(u8, platform.key) catch continue;
                self.select(.{ .plugin = key });
            }
        };
        context.end();
        restyle(context, .{ .width = sidebar_width, .gap = 2 });
    }

    /// A platform's row: its icon and title, lit while `shown`. Returns whether it was pressed.
    fn sidebarItem(_: *ExportWindow, context: *ui.Context, title: []const u8, id_text: []const u8, icon: ui.Layout.Paint, shown: bool) bool {
        const b = context.builder();
        const id = context.idFor(id_text);
        const image = b.node(0, .{ .width = icon_size, .height = icon_size }, icon, &.{}) catch return false;
        // The inset indicator leaves room on the left for the icon.
        const row = b.node(id, .{ .height = 34, .direction = .row, .align_items = .center, .padding = .{ .left = 8 } }, .{ .menu_item = .{ .label = title, .hot = shown, .indicator = .inset } }, &.{image}) catch return false;
        row.cursor = .pointer;
        row.accessibility = .{ .role = .tab, .label = title };
        context.element(row);
        return context.activated(id) and !shown;
    }

    /// The platform shown: its icon, title and what it builds, then its settings and the
    /// plugins' for it.
    fn buildPlatform(self: *ExportWindow, context: *ui.Context, game: ?*HotGame, editor: *eggy.editor.Context) void {
        const shown = self.shownPlatform(game);

        // The header: icon, title and a line on what it builds.
        const b = context.builder();
        const icon = switch (self.selected) {
            .builtin => |platform| self.icons.builtin(platform, context.theme),
            .plugin => |key| self.icons.plugin(key, shown.icon_png, context.theme),
        };
        context.begin(.row);
        if (b.node(0, .{ .width = 40, .height = 40 }, icon, &.{})) |image| context.element(image) else |_| {}
        context.begin(.column);
        context.heading(3, shown.title);
        context.muted(shown.note);
        smallText(context, 12);
        context.end();
        restyle(context, .{ .grow = 1, .gap = 2 });
        context.end();
        restyle(context, .{ .direction = .row, .gap = 14, .align_items = .center });

        if (self.problem) |why| context.alert("Couldn't export", why, true);

        // Eggy's settings for it.
        const settings = self.shownSettings();
        var rows = SettingRows{};
        setting_rows.beginGroup(context);
        const arena = b.allocator;
        if (self.selected == .builtin) {
            const platform = self.selected.builtin;
            const choices = platforms.architectures(platform);
            if (choices.len > 1) {
                rows.begin(context, "Architecture", "The processor the game runs on.");
                const labels = arena.alloc([]const u8, choices.len) catch return;
                var index: usize = 0;
                for (labels, choices, 0..) |*label, choice, i| {
                    label.* = choice.label(platform);
                    if (choice == settings.architecture) index = i;
                }
                if (context.select("##architecture", labels, &index)) settings.architecture = choices[index];
                rows.end(context);
            }
            if (platform == .linux) {
                rows.begin(context, "C library", "glibc for most desktop Linux; musl for Alpine and other small systems.");
                var libc: usize = @backingInt(settings.libc);
                if (context.select("##libc", &platforms.Libc.labels, &libc)) settings.libc = @fromBackingInt(@intCast(libc));
                if (platforms.libcNote(settings.libc)) |why| {
                    context.muted(why);
                    page_style.noteText(context);
                }
                rows.end(context);
            }
        } else {
            rows.begin(context, "Target", "The Zig target the plugin builds it for, unless its settings pick another.");
            context.text(shown.target);
            rows.end(context);
        }

        rows.begin(context, "Optimize for", "Speed suits a release. Debugging keeps debug info and safety checks, and runs slower.");
        var optimize: usize = @backingInt(settings.optimize);
        if (context.select("##optimize", &platforms.Optimize.labels, &optimize)) settings.optimize = @fromBackingInt(@intCast(optimize));
        rows.end(context);

        if (self.selected == .builtin and platforms.buildsForThisCpu(self.selected.builtin, settings.*)) {
            rows.begin(context, "Tune for this computer", "Faster here, but the game may not start on older processors of its kind.");
            _ = context.toggle("##this cpu", &settings.this_cpu);
            rows.end(context);
        }
        if (if (self.selected == .plugin) shown.zips else platforms.zips(self.selected.builtin)) {
            rows.begin(context, "ZIP archive", "Also pack the game's folder into a ZIP, to hand out.");
            _ = context.toggle("##zip", &settings.zip);
            rows.end(context);
        }
        if (self.selected == .builtin and self.selected.builtin == .macos and platforms.needs_macos_sdk) {
            rows.begin(context, "macOS SDK", "The MacOSX.sdk folder to build with, from Xcode. On a Mac, Eggy uses its own.");
            const default = platforms.defaultMacSdk(arena) orelse "";
            context.begin(.row);
            _ = context.textInput("##macos sdk", &settings.sdk, default);
            restyle(context, .{ .grow = 1 });
            if (self.folderButton(context, "Choose the macOS SDK folder")) {
                const start_in = arena.dupeSentinel(u8, self.macSdk(arena) orelse default, 0) catch null;
                sdl3.dialog.showOpenFolder(ExportWindow, pickedSdk, self, self.window.popout.window.window, start_in, false);
            }
            page_style.endRow(context);
            if (!self.sdkExists(self.macSdk(arena))) {
                context.muted("No SDK there yet");
                page_style.noteText(context);
            }
            rows.end(context);
        }
        setting_rows.endGroup(context);

        // What plugins add for it.
        if (game) |loaded| {
            context.begin(.column);
            loaded.exportUi(self.platformIndex(game), shown.target, editor, context);
            context.end();
            restyle(context, .{ .gap = 12 });
        }
    }

    /// Project Settings on the left, Export on the right.
    fn buildFooter(self: *ExportWindow, context: *ui.Context, game: ?*HotGame) void {
        context.begin(.column);
        context.separator();
        context.begin(.row);
        if (context.buttonVariant("Project Settings...", .ghost)) self.wants_project_settings = true;
        context.begin(.row);
        context.end();
        restyle(context, .{ .grow = 1 });
        if (context.buttonVariant("Close", .outline)) self.closing = true;
        if (context.button("Export")) self.start(game);
        page_style.endRow(context);
        context.end();
        restyle(context, .{ .height = footer_height, .gap = page_gap });
    }

    /// The export under way, or how it ended.
    fn buildProgress(self: *ExportWindow, context: *ui.Context, status: job_zig.Status) void {
        const arena = context.builder().allocator;
        const platform = self.exporting_for[0..self.exporting_for_len];
        context.heading(3, switch (status.stage) {
            .done => std.fmt.allocPrint(arena, "Exported for {s}", .{platform}) catch "Exported",
            .failed => std.fmt.allocPrint(arena, "The export for {s} failed", .{platform}) catch "The export failed",
            else => std.fmt.allocPrint(arena, "Exporting for {s}", .{platform}) catch "Exporting",
        });

        // The bar for the whole build, with how far it is.
        const fraction: f32 = if (status.stage == .done) 1 else status.fraction;
        context.begin(.row);
        context.progress(fraction);
        restyle(context, .{ .grow = 1 });
        context.label("{d}%", .{@as(u32, @intFromFloat(@round(fraction * 100)))});
        restyle(context, .{ .width = 44 });
        page_style.endRow(context);
        switch (status.stage) {
            .failed => {
                context.alert("Zig stopped with an error", status.detail, true);
                self.show_output = true;
            },
            .done => context.muted("It's in the project's zig-out/export/ folder."),
            else => {
                context.muted(if (status.detail.len > 0) std.fmt.allocPrint(arena, "{s}: {s}", .{ status.stage.label(), status.detail }) catch status.stage.label() else status.stage.label());
                smallText(context, 12);
            },
        }

        // Zig's output, on request.
        if (context.buttonVariant(if (self.show_output) "Hide output" else "Show output", .link)) self.show_output = !self.show_output;
        if (self.show_output) {
            // The output only grows, so its length tells when it changed.
            self.terminal.showSteps(status.steps, sdl3.timer.getMillisecondsSinceInit());
            self.terminal.add(context, status.log, status.log.len, @max(120, context.viewport.h - 280));
        }

        context.begin(.row);
        defer page_style.endRow(context);
        switch (status.stage) {
            .done, .failed => {
                if (status.stage == .done and context.button("Show in file manager")) self.showExports();
                if (context.buttonVariant("Back to settings", .outline)) self.forgetJob();
                if (self.show_output and context.buttonVariant("Copy output", .ghost)) terminal_view.copyToClipboard(status.log);
                if (context.buttonVariant("Close", .outline)) self.closing = true;
            },
            else => if (context.buttonVariant("Cancel", .outline)) self.forgetJob(),
        }
    }

    /// Start exporting for the platform shown, with its settings and the plugins' arguments.
    fn start(self: *ExportWindow, game: ?*HotGame) void {
        self.problem = null;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const shown = self.shownPlatform(game);
        const settings = self.shownSettings().*;
        const scene = self.scenes[self.scene];

        // Eggy's arguments for it.
        var args = switch (self.selected) {
            .builtin => |platform| blk: {
                var sdk: ?[]const u8 = null;
                if (platform == .macos and platforms.needs_macos_sdk) {
                    sdk = self.macSdk(arena);
                    if (!self.sdkExists(sdk)) {
                        self.problem = "Set the macOS SDK to a MacOSX.sdk folder first.";
                        return;
                    }
                    self.rememberSdk();
                }
                break :blk platforms.exportArgs(arena, platform, settings, scene, sdk) catch return self.fail(error.OutOfMemory);
            },
            .plugin => blk: {
                var list: std.ArrayList([]const u8) = .empty;
                list.appendSlice(arena, &.{
                    std.fmt.allocPrint(arena, "-Dtarget={s}", .{shown.target}) catch return self.fail(error.OutOfMemory),
                    std.fmt.allocPrint(arena, "-Dscene={s}", .{scene}) catch return self.fail(error.OutOfMemory),
                    std.fmt.allocPrint(arena, "-Dexport-optimize={t}", .{settings.optimize.mode()}) catch return self.fail(error.OutOfMemory),
                }) catch return self.fail(error.OutOfMemory);
                if (shown.zips and !settings.zip) list.append(arena, "-Dexport-zip=false") catch return self.fail(error.OutOfMemory);
                break :blk list;
            },
        };

        // And the plugins'. A plugin's own platform can't export without them.
        var plugin_args = eggy.plugins.ExportArgs{ .arena = arena };
        if (game) |loaded| {
            loaded.exportArgs(self.platformIndex(game), shown.target, &plugin_args) catch |err| {
                self.problem = if (err == error.GameNotRunning)
                    "The game's code isn't running, so its plugins can't add their export settings. Fix it (see the Console), then export."
                else
                    "A plugin couldn't add its export settings: see the Console.";
                if (self.selected == .plugin or err != error.GameNotRunning) return;
                self.problem = null;
                std.log.warn("exporting without plugins' export settings: the game isn't running", .{});
            };
        }
        args.appendSlice(arena, plugin_args.list.items) catch return self.fail(error.OutOfMemory);
        // A plugin platform may build for a target its settings pick; `-Dtarget` comes first.
        if (self.selected == .plugin) if (plugin_args.target) |target| {
            args.items[0] = std.fmt.allocPrint(arena, "-Dtarget={s}", .{target}) catch return self.fail(error.OutOfMemory);
        };

        const folders = job_zig.editorFolders(self.gpa) catch |err| return self.fail(err);
        defer self.gpa.free(folders.resources_dir);
        defer self.gpa.free(folders.engines_dir);
        self.job = Job.start(self.gpa, .{ .dir = self.project_dir, .resources_dir = folders.resources_dir, .engines_dir = folders.engines_dir, .action = .{ .export_game = args.items } }) catch |err| return self.fail(err);
        self.exporting_for_len = @min(shown.title.len, self.exporting_for.len);
        @memcpy(self.exporting_for[0..self.exporting_for_len], shown.title[0..self.exporting_for_len]);
        self.show_output = false;
    }

    fn fail(self: *ExportWindow, err: anyerror) void {
        std.log.err("cannot export: {t}", .{err});
        self.problem = "The export couldn't start: see the Console.";
    }

    /// What the window shows of the selected platform.
    const Shown = struct { title: []const u8, note: []const u8, target: []const u8, icon_png: []const u8 = "", zips: bool = true };

    fn shownPlatform(self: *ExportWindow, game: ?*HotGame) Shown {
        return switch (self.selected) {
            .builtin => |platform| .{
                .title = platforms.title(platform),
                .note = platforms.note(platform),
                .target = platforms.target(platform, self.settings[@backingInt(platform)]),
            },
            .plugin => {
                const platform = game.?.export_platforms[self.pluginIndex(game).?];
                return .{ .title = platform.title, .note = platform.note, .target = platform.target, .icon_png = platform.icon_png, .zips = platform.zips };
            },
        };
    }

    fn shownSettings(self: *ExportWindow) *platforms.Settings {
        return switch (self.selected) {
            .builtin => |platform| &self.settings[@backingInt(platform)],
            .plugin => &self.plugin_settings,
        };
    }

    /// The selected plugin platform's index in `game.export_platforms`; null if it has none.
    fn pluginIndex(self: *const ExportWindow, game: ?*HotGame) ?usize {
        const loaded = game orelse return null;
        for (loaded.export_platforms, 0..) |platform, i| {
            if (std.mem.eql(u8, platform.key, self.selected.plugin)) return i;
        }
        return null;
    }

    /// The shown platform as plugins number it: Eggy's first, then theirs.
    fn platformIndex(self: *const ExportWindow, game: ?*HotGame) usize {
        return switch (self.selected) {
            .builtin => |platform| @backingInt(platform),
            .plugin => platforms.count + self.pluginIndex(game).?,
        };
    }

    fn select(self: *ExportWindow, selected: Selected) void {
        if (self.selected == .plugin) self.gpa.free(self.selected.plugin);
        self.selected = selected;
        self.problem = null;
        self.platform_scroll = .{};
    }

    /// A square button showing a folder, labelled `label` for screen readers. Returns whether it
    /// was pressed.
    fn folderButton(self: *ExportWindow, context: *ui.Context, label: []const u8) bool {
        const b = context.builder();
        const id = context.idFor(label);
        const image = b.node(0, .{ .width = icon_size, .height = icon_size }, self.icons.folder(context.theme), &.{}) catch return false;
        image.accessibility.role = .ignored;
        const button = b.node(id, .{ .width = 36, .height = 36, .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 } }, .{ .button = .{ .label = "", .variant = .outline } }, &.{image}) catch return false;
        button.cursor = .pointer;
        button.accessibility = .{ .role = .button, .label = label };
        context.element(button);
        return context.activated(id);
    }

    /// Called on the picker's thread: keep the folder chosen for the next frame.
    fn pickedSdk(self: ?*ExportWindow, files: ?[]const [*:0]const u8, _: ?usize, failed: bool) void {
        const chosen = files orelse return;
        if (failed or chosen.len == 0) return;
        const copy = std.heap.c_allocator.dupeSentinel(u8, std.mem.span(chosen[0]), 0) catch return;
        if (self.?.picked_sdk.swap(copy.ptr, .acq_rel)) |old| std.heap.c_allocator.free(std.mem.span(old));
    }

    /// Put a folder chosen in the picker into the macOS SDK field.
    fn takePickedSdk(self: *ExportWindow) void {
        const path = self.picked_sdk.swap(null, .acq_rel) orelse return;
        const chosen = std.mem.span(path);
        defer std.heap.c_allocator.free(chosen);
        self.settings[@backingInt(platforms.Platform.macos)].sdk.set(chosen[0..@min(chosen.len, 512)]) catch {};
        self.rememberSdk();
    }

    /// Keep the macOS SDK field's path for the next Export window; an empty field forgets it.
    fn rememberSdk(self: *ExportWindow) void {
        if (!platforms.needs_macos_sdk) return;
        sdk_location.save(std.mem.trim(u8, self.settings[@backingInt(platforms.Platform.macos)].sdk.text(), " "));
    }

    /// The macOS SDK to build with: the one typed, else `~/SDKs`.
    fn macSdk(self: *ExportWindow, arena: std.mem.Allocator) ?[]const u8 {
        const typed = std.mem.trim(u8, self.settings[@backingInt(platforms.Platform.macos)].sdk.text(), " ");
        return if (typed.len > 0) sdk_location.expandHome(arena, typed) else platforms.defaultMacSdk(arena);
    }

    fn sdkExists(_: *ExportWindow, path: ?[]const u8) bool {
        const sdk = path orelse return false;
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, sdk, .{}) catch return false;
        dir.close(io);
        return true;
    }

    /// Keep the scene chosen as the project's default: a change for the editor to record.
    fn keepDefaultScene(self: *ExportWindow) void {
        if (self.change) |change| {
            self.gpa.free(change.before);
            self.gpa.free(change.after);
        }
        self.change = project_settings.setDefaultScene(self.gpa, self.project_dir, self.scenes[self.scene]) catch |err| blk: {
            std.log.err("cannot keep the default scene: {t}", .{err});
            break :blk null;
        };
    }

    /// The project's scenes to start in, its default scene picked if it has one.
    fn findScenes(self: *ExportWindow) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const arena = self.scenes_arena.allocator();
        var project = std.Io.Dir.cwd().openDir(io, self.project_dir, .{}) catch return;
        defer project.close(io);
        self.scenes = listing.scenes(arena, io, project, eggy.project.resources_dir) catch &.{};
        const labels = arena.alloc([]const u8, self.scenes.len) catch return;
        for (labels, self.scenes) |*label, scene| label.* = sceneLabel(scene);
        self.scene_labels = labels;
        const config = eggy.project.load(arena, io, project) catch return;
        const default = config.default_scene orelse return;
        for (self.scenes, 0..) |scene, i| if (std.mem.eql(u8, scene, default)) {
            self.scene = i;
            self.has_default_scene = true;
        };
    }

    /// Stop the export, if it is still going, and go back to the settings.
    fn forgetJob(self: *ExportWindow) void {
        if (self.job) |job| job.deinit();
        self.job = null;
    }

    fn showExports(self: *ExportWindow) void {
        const folder = std.fs.path.join(self.gpa, &.{ self.project_dir, "zig-out", "export" }) catch return;
        defer self.gpa.free(folder);
        file_manager.showFolder(self.gpa, folder) catch |err| std.log.err("cannot show {s}: {t}", .{ folder, err });
    }
};

/// `resources/levels/one.scene.zon` as `levels/one`.
fn sceneLabel(path: []const u8) []const u8 {
    const inside = if (std.mem.startsWith(u8, path, eggy.project.resources_dir ++ "/")) path[eggy.project.resources_dir.len + 1 ..] else path;
    return if (std.mem.endsWith(u8, inside, ".scene.zon")) inside[0 .. inside.len - ".scene.zon".len] else inside;
}

test "scenes are named inside resources, without their extension" {
    try std.testing.expectEqualStrings("levels/one", sceneLabel("resources/levels/one.scene.zon"));
}

test {
    _ = platforms;
    _ = @import("icons.zig");
    _ = sdk_location;
}
