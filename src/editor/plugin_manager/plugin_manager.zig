//! Edit > Plugins: the project's installed plugins, each with its switch, beside the chosen one
//! (what it is, where it comes from, an update when there is one, its preferences and read-me);
//! the plugins that ship inside Eggy; and any other, fetched by its `eggy.zon`'s address, path or
//! folder (or dropped on the editor). Install (or Update) adds a plugin to the project's
//! `eggy.zon`, which `addGame` builds the game with; a plugin on this computer is linked from its
//! folder. An installed plugin can be turned off and on (as in Settings > Plugins), and once off,
//! uninstalled: taken out of `eggy.zon`, with its package out of `build.zig.zon` unless another
//! installed plugin comes from it. Each is a step to undo. A filter keeps the plugins whose title
//! or description has it.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const build_options = @import("build_options");
const ToolWindow = @import("../tool_window.zig").ToolWindow;
const page_style = @import("../page_style.zig");
const restyle = page_style.restyle;
const smallText = page_style.smallText;
const fetch_zig = @import("fetch.zig");
const install_zig = @import("install.zig");
const source = @import("source.zig");
const package_entry = @import("package_entry.zig");
const project_plugins = @import("project_plugins.zig");
const PickedPaths = @import("../picked_paths.zig").PickedPaths;
const project_tile = @import("../projects/project_tile.zig");
const prefs_files = @import("../preferences/preferences.zig");
const PreferenceForm = @import("../preferences/preference_form.zig").PreferenceForm;
const History = @import("../history.zig").History;
const setting_rows = eggy.setting_rows;
const Fetched = fetch_zig.Fetched;
const Installed = eggy.plugin_manifest.Installed;
const Manifest = eggy.plugin_manifest.Manifest;
const log = std.log.scoped(.plugins);

const sidebar_width: f32 = 170;
/// The installed plugins' list, beside the chosen one.
const list_width: f32 = 300;
/// The least room right of the sidebar for the list and the chosen plugin side by side.
const side_by_side_width: f32 = 560;
const Location = ui.TextEdit(1024);
const Query = ui.TextEdit(64);

/// What the sidebar shows.
const Section = enum {
    installed,
    builtin,
    address,

    fn title(section: Section) []const u8 {
        return switch (section) {
            .installed => "Installed",
            .builtin => "Made by Eggy",
            .address => "From Elsewhere",
        };
    }
};

pub const AutoUpdate = @import("auto_update.zig").AutoUpdate;
pub const UpdateOffer = @import("auto_update.zig").Offer;
pub const UpdatePrompt = @import("update_prompt.zig").UpdatePrompt;
pub const updateKey = @import("update_prompt.zig").updateKey;
pub const Texts = project_plugins.Texts;
pub const Change = project_plugins.Change;
pub const freeChange = project_plugins.freeChange;

/// Where the chosen plugin's preferences live, for a frame: Settings' store and files, the undo
/// history, and the preferences each plugin of the loaded game declares.
pub const Preferences = struct {
    store: *eggy.preferences.Store,
    folders: prefs_files.Folders,
    history: *History,
    manifests: []const eggy.preferences.Manifest,
};

/// What a frame of the window asks of the editor.
pub const Outcome = struct {
    change: ?Change = null,
    /// A plugin to turn on or off (its module, borrowed until the next frame).
    switched: ?struct { module: []const u8, on: bool } = null,
};

pub const PluginsWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    /// The project's folder, owned.
    project_dir: []u8,
    section: Section = .installed,
    /// The plugins inside Eggy, read from what the editor embeds.
    builtins: []*Fetched = &.{},
    /// The project's `eggy.zon` `.plugins`, as last read (see `reloadInstalled`).
    installed_arena: std.heap.ArenaAllocator,
    installed: []const Installed = &.{},
    location: Location = Location.init("") catch unreachable,
    /// Keeps the plugins whose title or description has it.
    query: Query = Query.init("") catch unreachable,
    /// A plugin's folder chosen with Folder..., for the next frame to read.
    picked: PickedPaths = .{},
    /// The plugin being read by address or folder, then, read, `elsewhere` (owned).
    fetching: ?*fetch_zig.Fetch = null,
    elsewhere: ?*Fetched = null,
    /// The installed plugin the Installed page shows, by module (owned); empty for none.
    selected: std.ArrayList(u8) = .empty,
    /// The chosen installed plugin, read again from where it came from for its read-me and any
    /// update: being read, then read (owned). Eggy's own need no reading.
    detail_fetch: ?*fetch_zig.Fetch = null,
    detail: ?*Fetched = null,
    /// The plugin whose whole read-me fills the page until Back (borrowed).
    reading: ?*Fetched = null,
    /// The chosen plugin's preferences.
    form: PreferenceForm = .{},
    /// Where they live, for the frame being drawn.
    preferences: ?Preferences = null,
    /// Why the last fetch or install failed, owned.
    problem: std.ArrayList(u8) = .empty,
    installing: ?*install_zig.Install = null,
    /// The plugin `installing` installs (borrowed: Eggy's, `elsewhere` or `detail`, which are
    /// kept until it ends).
    installing_plugin: ?*Fetched = null,
    /// The project's `build.zig.zon` before `installing` saved its package, owned, for undo.
    package_before: ?[]u8 = null,
    /// What this frame asks of the editor, for `update` to return.
    outcome: Outcome = .{},
    /// The modules of the plugins turned off, borrowed from the editor for a frame.
    off: []const []const u8 = &.{},
    list_scroll: ui.Layout.ScrollState = .{},
    content_scroll: ui.Layout.ScrollState = .{},

    /// Open the window for the project in `project_dir`. On the heap, as its page keeps a pointer
    /// to it. Allocation and window failures propagate.
    ///
    /// ```zig
    /// const window = try PluginsWindow.open(gpa, graphics, font, project_dir);
    /// defer window.close(graphics);
    /// ```
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, project_dir: []const u8) !*PluginsWindow {
        const self = try gpa.create(PluginsWindow);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = undefined, .project_dir = try gpa.dupe(u8, project_dir), .installed_arena = .init(gpa) };
        errdefer gpa.free(self.project_dir);
        errdefer self.installed_arena.deinit();
        try self.readBuiltins();
        errdefer self.freeBuiltins();
        self.reloadInstalled();
        self.window = try ToolWindow.open(gpa, graphics, font, "Plugins", .{ 1040, 680 }, .{ .resizable = true });
        return self;
    }

    /// Close the window, stopping any fetch or install under way, and free it.
    pub fn close(self: *PluginsWindow, graphics: *eggy.Graphics) void {
        const gpa = self.gpa;
        self.window.close(graphics);
        if (self.fetching) |fetch| fetch.destroy();
        if (self.detail_fetch) |fetch| fetch.destroy();
        if (self.installing) |running| running.destroy();
        if (self.package_before) |text| gpa.free(text);
        if (self.elsewhere) |fetched| fetched.destroy();
        if (self.detail) |fetched| fetched.destroy();
        self.selected.deinit(gpa);
        self.freeBuiltins();
        self.installed_arena.deinit();
        self.problem.deinit(gpa);
        self.picked.deinit();
        if (self.outcome.change) |change| freeChange(gpa, change);
        gpa.free(self.project_dir);
        gpa.destroy(self);
    }

    /// Whether `curr_event` asks to close the window: its close button, or Escape.
    pub fn closeRequested(self: *const PluginsWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (curr_event == .window_close_requested) return true;
        const input = weeoui_sdl3.translate(curr_event) orelse return false;
        return input == .key_down and input.key_down.key == .escape;
    }

    /// Handle `curr_event` if it is for this window; returns whether it was.
    pub fn handle(self: *PluginsWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        self.window.handle(curr_event);
        return true;
    }

    /// Read the plugin whose `eggy.zon` is at `typed` (an address or a path), then show its
    /// read-me. Failures show in the window.
    ///
    /// ```zig
    /// window.fetchFrom("/home/me/plugins/stats/eggy.zon"); // A dropped file.
    /// ```
    pub fn fetchFrom(self: *PluginsWindow, typed: []const u8) void {
        self.section = .address;
        self.reading = null;
        self.location.set(typed[0..@min(typed.len, 1024)]) catch {};
        // What is being installed stays until the install ends.
        if (self.installing != null) return self.setProblem("Wait for the install under way to end first.");
        self.problem.clearRetainingCapacity();
        if (self.fetching) |fetch| fetch.destroy();
        self.fetching = null;
        self.fetching = fetch_zig.Fetch.start(self.gpa, typed, self.project_dir) catch |err| {
            self.setProblem(if (err == error.EmptyLocation) "Type the address of a plugin's eggy.zon, or a path to it." else "Couldn't start reading the plugin.");
            return;
        };
    }

    /// Read the project's installed plugins again, after its `eggy.zon` changed (an undo, say).
    pub fn reloadInstalled(self: *PluginsWindow) void {
        _ = self.installed_arena.reset(.retain_capacity);
        self.installed = &.{};
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, self.project_dir, .{}) catch return;
        defer dir.close(io);
        const config = eggy.project.load(self.installed_arena.allocator(), io, dir) catch |err| return log.warn("cannot read {s}: {t}", .{ eggy.project.file_name, err });
        self.installed = config.plugins;
    }

    /// Draw a frame, showing the plugins keyed in `off` as off and the chosen one's preferences
    /// from `preferences` (null without a game loaded); returns what it asks of the
    /// editor: an install or uninstall (the caller owns its texts and rebuilds the project), or a
    /// plugin to switch.
    pub fn update(self: *PluginsWindow, graphics: *eggy.Graphics, style: *const ui.Context, off: []const []const u8, preferences: ?Preferences) !Outcome {
        self.collect();
        self.off = off;
        self.preferences = preferences;
        const Page = struct {
            window: *PluginsWindow,
            /// ToolWindow callback for one frame of the Plugins window.
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.window.build(context);
            }
        };
        var page = Page{ .window = self };
        try self.window.present(graphics, style, &page);
        defer self.outcome = .{};
        return self.outcome;
    }

    /// Take what a fetch or install finished with.
    fn collect(self: *PluginsWindow) void {
        if (self.fetching) |fetch| if (fetch.take()) |outcome| {
            fetch.destroy();
            self.fetching = null;
            switch (outcome) {
                .fetched => |fetched| {
                    if (self.elsewhere) |old| old.destroy();
                    self.elsewhere = fetched;
                },
                .failed => |why| self.setProblem(why),
            }
        };
        if (self.detail_fetch) |fetch| if (fetch.take()) |outcome| {
            fetch.destroy();
            self.detail_fetch = null;
            switch (outcome) {
                .fetched => |fetched| self.detail = fetched,
                // The page says it has no read-me; the plugin itself is installed all the same.
                .failed => |why| log.warn("cannot read the installed plugin again: {s}", .{why}),
            }
        };
        if (self.installing) |running| {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const status = running.status(arena.allocator()) catch return;
            const outcome = status.outcome orelse return;
            running.destroy();
            self.installing = null;
            const package_before = self.package_before;
            self.package_before = null;
            const plugin = self.installing_plugin;
            self.installing_plugin = null;
            switch (outcome) {
                .saved => if (plugin) |fetched| {
                    self.record(fetched) catch |err| self.failInstall(err);
                    // What `zig fetch --save` did to build.zig.zon goes in the same step.
                    if (package_before) |before| if (self.outcome.change) |*change| {
                        change.package = project_plugins.packageChange(self.gpa, self.project_dir, before) catch null;
                    } else self.gpa.free(before);
                } else if (package_before) |before| self.gpa.free(before),
                .failed => |why| {
                    if (package_before) |before| self.gpa.free(before);
                    self.setProblem(why);
                },
            }
        }
    }

    // The page.

    fn build(self: *PluginsWindow, context: *ui.Context) void {
        const pane_height = page_style.pageHeight(context);
        context.begin(.row);
        self.buildSidebar(context);
        if (self.reading) |fetched| {
            context.beginScroll(&self.content_scroll, pane_height);
            self.buildReadme(context, fetched);
            context.end();
            restyle(context, .{ .grow = 1, .gap = 14 });
        } else switch (self.section) {
            .installed => self.buildInstalled(context, pane_height),
            .builtin => {
                context.beginScroll(&self.content_scroll, pane_height);
                self.buildBuiltins(context);
                context.end();
                restyle(context, .{ .grow = 1, .gap = 14 });
            },
            .address => {
                context.beginScroll(&self.content_scroll, pane_height);
                self.buildAddress(context);
                context.end();
                restyle(context, .{ .grow = 1, .gap = 14 });
            },
        }
        context.end();
        restyle(context, .{ .direction = .row, .gap = 20, .align_items = .start });
    }

    /// The filter, then each page with how many plugins it lists.
    fn buildSidebar(self: *PluginsWindow, context: *ui.Context) void {
        context.begin(.column);
        _ = context.textInput("##filter plugins", &self.query, "Filter plugins");
        for (std.enums.values(Section)) |section| self.sidebarItem(context, section);
        context.end();
        restyle(context, .{ .width = sidebar_width, .gap = 2 });
    }

    fn sidebarItem(self: *PluginsWindow, context: *ui.Context, section: Section) void {
        const b = context.builder();
        const id = context.idFor(section.title());
        if (context.activated(id)) {
            self.section = section;
            self.reading = null;
            self.content_scroll = .{};
        }
        const count: []const u8 = switch (section) {
            .installed => std.fmt.allocPrint(b.allocator, "{d}", .{self.installed.len}) catch "",
            .builtin => std.fmt.allocPrint(b.allocator, "{d}", .{self.builtins.len}) catch "",
            .address => "",
        };
        const children = [_]*ui.Layout.Element{
            b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = section.title(), .size = context.theme.text_size } }, &.{}) catch return,
            b.node(0, .{}, .{ .text = .{ .value = count, .size = 11, .tone = .muted } }, &.{}) catch return,
        };
        const row = b.node(id, .{ .height = 30, .direction = .row, .align_items = .center, .padding = .{ .left = 10, .right = 10 } }, page_style.highlight(b.allocator, id, self.section == section and self.reading == null, false), &children) catch return;
        row.cursor = .pointer;
        row.accessibility = .{ .role = .tab, .label = section.title() };
        context.element(row);
    }

    /// The installed plugins, each with its switch, beside the chosen one. Too narrow for both,
    /// the list alone until one is chosen, then that one with a way back.
    fn buildInstalled(self: *PluginsWindow, context: *ui.Context, pane_height: f32) void {
        const side_by_side = context.contentWidth() - sidebar_width >= side_by_side_width;
        // Side by side, one is always chosen, as after the chosen one is uninstalled.
        if (side_by_side and self.selectedInstalled() == null and self.installed.len > 0) self.select(self.installed[0].module);
        const chosen = self.selectedInstalled();
        if (side_by_side or chosen == null) {
            context.beginScroll(&self.list_scroll, pane_height);
            self.installedRows(context, if (side_by_side) list_width else context.contentWidth() - sidebar_width - 20);
            context.end();
            restyle(context, if (side_by_side) .{ .width = list_width, .gap = 2 } else .{ .grow = 1, .gap = 2 });
        }
        if (chosen) |installed| {
            context.beginScroll(&self.content_scroll, pane_height);
            if (!side_by_side and context.buttonVariant("Back##installed", .link)) self.selected.clearRetainingCapacity();
            self.buildChosen(context, installed);
            context.end();
            restyle(context, .{ .grow = 1, .gap = 14 });
        }
    }

    /// A row per installed plugin the filter keeps: its tile, title and what it does, and its switch.
    fn installedRows(self: *PluginsWindow, context: *ui.Context, width: f32) void {
        if (self.problem.items.len > 0 and self.selectedInstalled() == null) context.alert("Couldn't uninstall the plugin", self.problem.items, true);
        if (self.installed.len == 0) return context.muted("No plugins installed yet.");
        const b = context.builder();
        const arena = b.allocator;
        var shown: usize = 0;
        for (self.installed) |installed| {
            const title, const description = self.describeInstalled(installed);
            if (!setting_rows.matches(self.query.text(), title, description)) continue;
            shown += 1;
            const id = context.idFor(std.fmt.allocPrint(arena, "##row {s}", .{installed.module}) catch continue);
            if (context.activated(id)) self.select(installed.module);

            // What the row leaves the text: the scroll bar's room, the row's padding, the tile,
            // the gaps, and the switch with its own room.
            const text_room = @max(40, width - 12 - 16 - 32 - 10 - 8 - 8 - 72);
            const texts = [_]*ui.Layout.Element{
                b.node(0, .{}, .{ .text = .{ .value = page_style.fitText(arena, context.font, title, 13, text_room), .size = 13 } }, &.{}) catch continue,
                b.node(0, .{}, .{ .text = .{ .value = page_style.fitText(arena, context.font, if (self.isOff(installed.module)) "Off" else description, 12, text_room), .size = 12, .tone = .muted } }, &.{}) catch continue,
            };
            const children = [_]*ui.Layout.Element{
                project_tile.node(b, title, 32) catch continue,
                b.node(0, .{ .gap = 2, .grow = 1 }, .none, &texts) catch continue,
            };
            const selected = std.mem.eql(u8, self.selected.items, installed.module);
            const row = b.node(id, .{ .direction = .row, .align_items = .center, .gap = 10, .grow = 1, .padding = .{ .left = 10, .right = 6, .top = 8, .bottom = 8 } }, .none, &children) catch continue;
            row.cursor = .pointer;
            row.accessibility = .{ .role = .menu_item, .label = title };

            context.begin(.row);
            context.element(row);
            var on = !self.isOff(installed.module);
            if (context.toggle(std.fmt.allocPrint(arena, "##on {s}", .{installed.module}) catch continue, &on)) self.outcome.switched = .{ .module = installed.module, .on = on };
            context.end();
            restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center, .padding = .{ .right = 8 } });
            // The highlight takes in the switch too, lit while the text part is hovered.
            if (context.last_added) |whole| {
                whole.paint_kind = page_style.highlight(arena, id, selected, false);
                whole.style.wrap = false;
            }
        }
        if (shown == 0) context.muted("No installed plugin matches.");
    }

    /// The chosen installed plugin: its switch, where it comes from, an update when there is
    /// one, its preferences, then its read-me.
    fn buildChosen(self: *PluginsWindow, context: *ui.Context, installed: Installed) void {
        const arena = context.builder().allocator;
        const builtin = self.builtinFor(installed.module);
        const manifest_read = builtin orelse self.detailFor(installed.module);
        const title, _ = self.describeInstalled(installed);

        context.begin(.row);
        project_tile.add(context, title, 44);
        context.begin(.column);
        context.text(title);
        restyle(context, .{ .height = 26 });
        if (context.last_added) |heading| if (heading.paint_kind == .text) {
            heading.paint_kind.text.size = 20;
        };
        badges(context, .{ .version = installed.version, .dev = installed.dev, .in_eggy = installed.dependency == null, .off = self.isOff(installed.module) });
        context.end();
        restyle(context, .{ .grow = 1, .gap = 6 });
        context.end();
        restyle(context, .{ .direction = .row, .gap = 14, .align_items = .center });

        context.begin(.row);
        self.switchButtons(context, installed);
        if (manifest_read) |fetched| if (builtin == null and eggy.plugin_manifest.compareVersions(fetched.manifest.version, installed.version) == .gt) {
            if (self.installButton(context, std.fmt.allocPrint(arena, "Update to {s}", .{fetched.manifest.version}) catch "Update")) self.install(fetched);
        };
        page_style.endRow(context);
        if (installed.dependency != null) {
            context.muted(std.fmt.allocPrint(arena, "From {s}", .{if (installed.source.len > 0) installed.source else installed.dependency.?}) catch "");
            smallText(context, 12);
        }
        self.uninstallNote(context, installed);
        if (self.problem.items.len > 0) context.alert("Couldn't change the plugin", self.problem.items, true);
        if (self.installing) |running| {
            const status = running.status(arena) catch null;
            context.muted(if (status) |known| known.log else "Fetching...");
            smallText(context, 12);
        }

        // Its preferences, as Settings shows them; a plugin that is off isn't in the game, so
        // it declares none.
        if (self.preferences) |where| for (where.manifests) |manifest| {
            if (!std.mem.eql(u8, manifest.key, installed.module) or manifest.fields.len == 0) continue;
            self.form.build(context, manifest, "", .{ .gpa = self.gpa, .store = where.store, .folders = where.folders, .layer = .project, .history = where.history, .now_ms = self.window.ui.time_ms });
        };

        context.separator();
        if (manifest_read) |fetched| return readme(context, fetched);
        if (self.detail_fetch != null) return context.muted("Reading its read-me...");
        context.muted("No README.md was provided.");
    }

    /// The plugins inside Eggy the filter keeps, as cards: what each is and does, its read-me,
    /// and Install, or that it is installed.
    fn buildBuiltins(self: *PluginsWindow, context: *ui.Context) void {
        const arena = context.builder().allocator;
        context.beginGrid(if (context.contentWidth() - sidebar_width >= side_by_side_width) 2 else 1);
        var shown: usize = 0;
        for (self.builtins) |fetched| {
            const manifest = fetched.manifest;
            if (!setting_rows.matches(self.query.text(), manifest.title, manifest.description)) continue;
            shown += 1;
            context.begin(.card);
            context.begin(.row);
            project_tile.add(context, manifest.title, 36);
            context.begin(.column);
            context.text(manifest.title);
            context.muted(std.fmt.allocPrint(arena, "v{s}, {s}", .{ manifest.version, if (manifest.dev) "dev plugin" else "library plugin" }) catch "");
            smallText(context, 12);
            context.end();
            restyle(context, .{ .grow = 1, .gap = 2 });
            page_style.endRow(context);
            if (manifest.description.len > 0) {
                context.muted(manifest.description);
                smallText(context, 12);
                if (context.last_added) |line| if (line.paint_kind == .text) {
                    line.paint_kind.text.wrap = true;
                };
            }
            context.begin(.row);
            context.begin(.row);
            context.end();
            restyle(context, .{ .grow = 1 });
            if (context.buttonVariant(std.fmt.allocPrint(arena, "Read Me##b{s}", .{manifest.module}) catch "Read Me", .ghost)) self.read(fetched);
            if (self.installedFor(manifest.module) != null) {
                context.muted("Installed");
                smallText(context, 12);
            } else if (self.installButton(context, std.fmt.allocPrint(arena, "Install##b{s}", .{manifest.module}) catch "Install")) self.install(fetched);
            page_style.endRow(context);
            context.end();
            restyle(context, .{ .gap = 10 });
        }
        context.end();
        if (shown == 0) context.muted("No plugin made by Eggy matches.");
        if (self.problem.items.len > 0) context.alert("Not installed", self.problem.items, true);
    }

    /// A plugin's `eggy.zon` by address or folder, then what was read, to install.
    fn buildAddress(self: *PluginsWindow, context: *ui.Context) void {
        if (self.picked.take()) |dir| {
            defer PickedPaths.free(dir);
            self.fetchFrom(dir);
        }
        context.begin(.row);
        _ = context.textInput("##location", &self.location, "https://raw.githubusercontent.com/me/plugins/main/stats/eggy.zon");
        restyle(context, .{ .grow = 1 });
        if (context.button("Fetch") and self.fetching == null) self.fetchFrom(self.location.text());
        if (context.buttonVariant("Folder...", .outline) and self.fetching == null) self.picked.showFolder(self.window.popout.window.window, null);
        page_style.endRow(context);
        context.muted("An eggy.zon's address, its GitHub folder, or a folder on this computer, which is linked, so the game builds it as it is now.");
        smallText(context, 12);
        if (context.last_added) |line| if (line.paint_kind == .text) {
            line.paint_kind.text.wrap = true;
        };
        if (self.fetching) |fetch| {
            context.muted(std.fmt.allocPrint(context.builder().allocator, "Reading {s}...", .{fetch.location()}) catch "Reading...");
            smallText(context, 12);
        }
        if (self.problem.items.len > 0) context.alert("Couldn't fetch the plugin", self.problem.items, true);
        if (self.elsewhere) |fetched| self.buildFetched(context, fetched);
    }

    /// A plugin read by address or folder, as a card: what it is, where its package is, and
    /// Install or Update.
    fn buildFetched(self: *PluginsWindow, context: *ui.Context, fetched: *Fetched) void {
        const arena = context.builder().allocator;
        const manifest = fetched.manifest;
        context.begin(.card);
        context.begin(.row);
        project_tile.add(context, manifest.title, 44);
        context.begin(.column);
        context.text(manifest.title);
        if (manifest.description.len > 0) {
            context.muted(manifest.description);
            smallText(context, 12);
            if (context.last_added) |line| if (line.paint_kind == .text) {
                line.paint_kind.text.wrap = true;
            };
        }
        context.end();
        restyle(context, .{ .grow = 1, .gap = 4 });
        if (context.buttonVariant("Read Me##fetched", .ghost)) self.read(fetched);
        page_style.endRow(context);
        badges(context, .{ .version = manifest.version, .dev = manifest.dev, .in_eggy = fetched.package == .eggy, .installed = self.installedFor(manifest.module) != null, .off = self.isOff(manifest.module) });
        const package_at: ?[]const u8 = switch (fetched.package) {
            .eggy => null,
            .fetch => |package| package.url,
            .folder => |package| package.path,
        };
        if (package_at) |at| {
            context.muted(std.fmt.allocPrint(arena, "Package {s}, fingerprint 0x{x}", .{ at, manifest.fingerprint }) catch "");
            smallText(context, 12);
        }
        context.muted(std.fmt.allocPrint(arena, "Repository {s}", .{manifest.repository}) catch "");
        smallText(context, 12);
        self.buildInstallRow(context, fetched);
        if (self.installing) |running| {
            const status = running.status(arena) catch null;
            context.muted(if (status) |known| known.log else "Fetching...");
            smallText(context, 12);
        }
        context.end();
        restyle(context, .{ .gap = 10 });
    }

    /// A plugin's whole read-me, with a way back, and Install or Update.
    fn buildReadme(self: *PluginsWindow, context: *ui.Context, fetched: *Fetched) void {
        const manifest = fetched.manifest;
        if (context.buttonVariant("Back", .link)) {
            self.reading = null;
            return;
        }
        context.heading(2, manifest.title);
        badges(context, .{ .version = manifest.version, .dev = manifest.dev, .in_eggy = fetched.package == .eggy, .installed = self.installedFor(manifest.module) != null, .off = self.isOff(manifest.module) });
        self.buildInstallRow(context, fetched);
        if (self.problem.items.len > 0) context.alert("Not installed", self.problem.items, true);
        context.separator();
        readme(context, fetched);
    }

    fn buildInstallRow(self: *PluginsWindow, context: *ui.Context, fetched: *Fetched) void {
        const arena = context.builder().allocator;
        const manifest = fetched.manifest;
        if (project_plugins.needsNewerEggy(manifest)) {
            context.alert("Needs a newer Eggy", std.fmt.allocPrint(arena, "This plugin needs Eggy {s} or newer; the project is on {s}. Use File > Upgrade Editor first.", .{ manifest.minimum_eggy_version.?, build_options.version }) catch "", false);
            return;
        }
        context.begin(.row);
        const installed = self.installedFor(manifest.module) orelse {
            if (self.installButton(context, "Install")) self.install(fetched);
            page_style.endRow(context);
            return;
        };
        switch (eggy.plugin_manifest.compareVersions(manifest.version, installed.version)) {
            .gt => if (self.installButton(context, std.fmt.allocPrint(arena, "Update to {s}", .{manifest.version}) catch "Update")) self.install(fetched),
            .eq => context.muted(std.fmt.allocPrint(arena, "Version {s} is installed.", .{installed.version}) catch ""),
            .lt => context.muted(std.fmt.allocPrint(arena, "The installed version, {s}, is newer.", .{installed.version}) catch ""),
        }
        page_style.endRow(context);
    }

    fn installButton(self: *PluginsWindow, context: *ui.Context, label: []const u8) bool {
        if (self.installing != null) {
            context.spinner();
            context.muted("Installing...");
            return false;
        }
        return context.button(label);
    }

    /// An installed plugin's switch, Disable or Enable, and once it is off, Uninstall.
    fn switchButtons(self: *PluginsWindow, context: *ui.Context, installed: Installed) void {
        const arena = context.builder().allocator;
        const off = self.isOff(installed.module);
        if (context.buttonVariant(std.fmt.allocPrint(arena, "{s}##s{s}", .{ if (off) "Enable" else "Disable", installed.module }) catch "Switch", .outline)) {
            self.outcome.switched = .{ .module = installed.module, .on = off };
        }
        if (off and context.buttonVariant(std.fmt.allocPrint(arena, "Uninstall##u{s}", .{installed.module}) catch "Uninstall", .destructive) and self.installing == null) self.uninstall(installed);
    }

    /// What uninstalling an installed plugin that is off leaves behind, when it leaves anything.
    fn uninstallNote(self: *PluginsWindow, context: *ui.Context, installed: Installed) void {
        if (!self.isOff(installed.module)) return;
        const arena = context.builder().allocator;
        const note = if (installed.dependency) |dependency| note: {
            const sharing = self.sharingPackage(installed) orelse break :note null;
            break :note std.fmt.allocPrint(arena, "Its package, {s}, holds {s} too, so uninstalling leaves the package in build.zig.zon: remove it yourself once you no longer want any of them.", .{ dependency, sharing.module }) catch null;
        } else "Uninstalling takes it off this project; Eggy keeps it, to install again.";
        if (note) |text| {
            context.muted(text);
            smallText(context, 12);
            if (context.last_added) |line| if (line.paint_kind == .text) {
                line.paint_kind.text.wrap = true;
            };
        }
    }

    const Marks = struct { version: []const u8, dev: bool, in_eggy: bool = false, installed: bool = false, off: bool = false };

    /// The plugin's version and what kind it is (a library plugin, which ships in the game, or a
    /// dev plugin, which only helps make it), then whether it is inside Eggy, installed or off.
    fn badges(context: *ui.Context, marks: Marks) void {
        const arena = context.builder().allocator;
        context.begin(.row);
        if (marks.version.len > 0) badge(context, std.fmt.allocPrint(arena, "v{s}", .{marks.version}) catch "", .secondary);
        if (marks.dev) badge(context, "Dev plugin: not exported", .outline) else badge(context, "Library plugin", .default);
        if (marks.in_eggy) badge(context, "Inside Eggy", .secondary);
        if (marks.installed) badge(context, "Installed", .secondary);
        if (marks.off) badge(context, "Off", .destructive);
        page_style.endRow(context);
        // Narrow windows put the badges on more lines.
        if (context.last_added) |row| row.style.wrap = true;
    }

    // Installing.

    fn install(self: *PluginsWindow, fetched: *Fetched) void {
        if (self.installing != null) return;
        self.problem.clearRetainingCapacity();
        const manifest = fetched.manifest;
        if (self.installedFor(manifest.module)) |installed| if (project_plugins.replacementProblem(installed, manifest)) |why| return self.setProblem(why);
        switch (fetched.package) {
            // Eggy's own: nothing to fetch, but this Eggy must have it, with Eggy's fingerprint.
            .eggy => {
                const builtin = self.builtinFor(manifest.module) orelse return self.setProblem("This Eggy doesn't ship that plugin. A newer one might: try File > Upgrade Editor.");
                if (manifest.fingerprint != build_options.fingerprint) return self.setProblem("The plugin says it ships inside Eggy, but its fingerprint isn't Eggy's.");
                self.record(builtin) catch |err| self.failInstall(err);
            },
            .fetch => |package| {
                self.package_before = project_plugins.readPackageFile(self.gpa, self.project_dir) catch |err| blk: {
                    log.warn("cannot read build.zig.zon, so undoing this install leaves its package there: {t}", .{err});
                    break :blk null;
                };
                self.installing = install_zig.Install.start(self.gpa, .{
                    .project_dir = self.project_dir,
                    .url = package.url,
                    .dependency = package.dependency,
                    .fingerprint = manifest.fingerprint,
                }) catch |err| blk: {
                    self.failInstall(err);
                    break :blk null;
                };
                if (self.installing != null) self.installing_plugin = fetched;
            },
            .folder => |package| self.link(fetched, package.path, package.dependency) catch |err| switch (err) {
                error.NoFingerprint => self.setProblem("The package's build.zig.zon has no fingerprint, so it can't be checked."),
                error.FingerprintMismatch => self.setProblem("The plugin's fingerprint isn't its package's: its eggy.zon names another package."),
                error.NoDependencies => self.setProblem("The project's build.zig.zon has no .dependencies to add the plugin to."),
                else => self.failInstall(err),
            },
        }
    }

    /// Install `fetched` from its package's folder `package_path`, linked into the project's
    /// `build.zig.zon` as dependency `dependency` (by a path relative to the project), after
    /// checking the folder's fingerprint is the plugin's. Both files change in one step to undo.
    fn link(self: *PluginsWindow, fetched: *Fetched, package_path: []const u8, dependency: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();

        const package_zon_path = try std.fs.path.join(arena, &.{ package_path, "build.zig.zon" });
        const package_zon = try std.Io.Dir.cwd().readFileAllocOptions(io, package_zon_path, arena, .limited(1 << 20), .of(u8), 0);
        const fingerprint = install_zig.fingerprintIn(arena, package_zon) catch return error.NoFingerprint;
        if (fingerprint != fetched.manifest.fingerprint) return error.FingerprintMismatch;

        var dir = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer dir.close(io);
        const before = try dir.readFileAllocOptions(io, "build.zig.zon", arena, .limited(1 << 20), .of(u8), 0);
        // Both are absolute, so no working folder or environment is needed to resolve them.
        const relative = try std.fs.path.relativeAlloc(arena, self.project_dir, null, self.project_dir, package_path);
        // Zig reads `.path` with forward slashes on every system.
        std.mem.replaceScalar(u8, relative, '\\', '/');
        const after = try package_entry.withFolderDependency(arena, before, dependency, relative);
        try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = after });
        errdefer dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = before }) catch {};

        try self.record(fetched);
        const before_copy = try self.gpa.dupe(u8, before);
        errdefer self.gpa.free(before_copy);
        self.outcome.change.?.package = .{ .before = before_copy, .after = try self.gpa.dupe(u8, after) };
    }

    /// List `fetched` in the project's `eggy.zon` (replacing an older entry), for undo.
    fn record(self: *PluginsWindow, fetched: *Fetched) !void {
        const manifest = fetched.manifest;
        // Uninstalling takes a plugin that is off, and its switch stays; installing it again
        // means wanting it on. An update leaves the switch as it is.
        const reinstalled_off = self.installedFor(manifest.module) == null and self.isOff(manifest.module);
        try self.rewritePlugins(manifest.module, project_plugins.entryFor(fetched, self.builtinFor(manifest.module) == fetched));
        if (reinstalled_off) self.outcome.switched = .{ .module = manifest.module, .on = true };
        log.info("installed {s} {s}", .{ manifest.module, manifest.version });
    }

    /// Take `installed` out of the project's `eggy.zon`, and its package out of `build.zig.zon`
    /// unless another installed plugin comes from it (or it is Eggy's own).
    fn uninstall(self: *PluginsWindow, installed: Installed) void {
        self.problem.clearRetainingCapacity();
        // Copied, as `rewritePlugins` frees `installed`'s strings.
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const module = arena.dupe(u8, installed.module) catch |err| return self.failInstall(err);
        const package: ?[]const u8 = if (installed.dependency != null and self.sharingPackage(installed) == null)
            arena.dupe(u8, installed.dependency.?) catch |err| return self.failInstall(err)
        else
            null;

        self.rewritePlugins(module, null) catch |err| return self.failInstall(err);
        if (package) |name| self.removePackage(name) catch |err| {
            log.err("cannot take {s} out of build.zig.zon: {t}", .{ name, err });
            self.setProblem("The plugin is uninstalled, but its package is still in build.zig.zon: see the Console.");
        };
        log.info("uninstalled {s}", .{module});
    }

    /// Take dependency `name` out of the project's `build.zig.zon`, as this frame's change's
    /// `package`.
    fn removePackage(self: *PluginsWindow, name: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer dir.close(io);
        const before = try dir.readFileAllocOptions(io, "build.zig.zon", arena, .limited(1 << 20), .of(u8), 0);
        const after = try package_entry.withoutDependency(arena, before, name) orelse return;
        try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = after });
        const before_copy = try self.gpa.dupe(u8, before);
        errdefer self.gpa.free(before_copy);
        self.outcome.change.?.package = .{ .before = before_copy, .after = try self.gpa.dupe(u8, after) };
    }

    /// Write the project's `eggy.zon` with `module`'s entry replaced by `entry` (or removed), as
    /// this frame's `change`.
    fn rewritePlugins(self: *PluginsWindow, module: []const u8, entry: ?Installed) !void {
        self.outcome.change = .{ .project = try project_plugins.rewrite(self.gpa, self.project_dir, module, entry) };
        self.reloadInstalled();
    }

    fn failInstall(self: *PluginsWindow, err: anyerror) void {
        log.err("cannot install the plugin: {t}", .{err});
        self.setProblem("Couldn't change the project's eggy.zon: see the Console.");
    }

    fn setProblem(self: *PluginsWindow, why: []const u8) void {
        self.problem.clearRetainingCapacity();
        self.problem.appendSlice(self.gpa, why) catch {};
    }

    // What is known.

    /// Show `fetched`'s whole read-me in place of the page, until Back.
    fn read(self: *PluginsWindow, fetched: *Fetched) void {
        self.reading = fetched;
        self.problem.clearRetainingCapacity();
        self.content_scroll = .{};
    }

    /// Choose the installed plugin `module` for the Installed page, and read it again from where
    /// it came from unless it is Eggy's.
    fn select(self: *PluginsWindow, module: []const u8) void {
        if (std.mem.eql(u8, self.selected.items, module)) return;
        // The plugin being installed stays until the install ends.
        if (self.installing != null) return;
        self.selected.clearRetainingCapacity();
        self.selected.appendSlice(self.gpa, module) catch return;
        self.problem.clearRetainingCapacity();
        self.content_scroll = .{};
        if (self.detail_fetch) |fetch| fetch.destroy();
        self.detail_fetch = null;
        if (self.detail) |fetched| fetched.destroy();
        self.detail = null;
        const installed = self.installedFor(module) orelse return;
        if (installed.dependency == null or installed.source.len == 0) return;
        self.detail_fetch = fetch_zig.Fetch.start(self.gpa, installed.source, self.project_dir) catch null;
    }

    /// The chosen installed plugin, while it is still installed.
    fn selectedInstalled(self: *const PluginsWindow) ?Installed {
        if (self.selected.items.len == 0) return null;
        return self.installedFor(self.selected.items);
    }

    /// `module` as read again from where it came from, once read.
    fn detailFor(self: *const PluginsWindow, module: []const u8) ?*Fetched {
        const fetched = self.detail orelse return null;
        return if (std.mem.eql(u8, fetched.manifest.module, module)) fetched else null;
    }

    /// An installed plugin's title and what it does, from Eggy's manifest or the one read again,
    /// else its module.
    fn describeInstalled(self: *const PluginsWindow, installed: Installed) struct { []const u8, []const u8 } {
        const manifest = if (self.builtinFor(installed.module)) |found| found.manifest else if (self.detailFor(installed.module)) |found| found.manifest else return .{ installed.module, "" };
        return .{ manifest.title, manifest.description };
    }

    fn isOff(self: *const PluginsWindow, module: []const u8) bool {
        for (self.off) |key| if (std.mem.eql(u8, key, module)) return true;
        return false;
    }

    /// Another installed plugin from `installed`'s package, if any.
    fn sharingPackage(self: *const PluginsWindow, installed: Installed) ?Installed {
        const dependency = installed.dependency orelse return null;
        for (self.installed) |other| {
            if (std.mem.eql(u8, other.module, installed.module)) continue;
            if (other.dependency) |name| if (std.mem.eql(u8, name, dependency)) return other;
        }
        return null;
    }

    fn installedFor(self: *const PluginsWindow, module: []const u8) ?Installed {
        for (self.installed) |installed| if (std.mem.eql(u8, installed.module, module)) return installed;
        return null;
    }

    fn builtinFor(self: *const PluginsWindow, module: []const u8) ?*Fetched {
        for (self.builtins) |fetched| if (std.mem.eql(u8, fetched.manifest.module, module)) return fetched;
        return null;
    }

    fn readBuiltins(self: *PluginsWindow) !void {
        const embedded = @import("eggy_builtin_plugins").all;
        var list: std.ArrayList(*Fetched) = .empty;
        errdefer {
            for (list.items) |fetched| fetched.destroy();
            list.deinit(self.gpa);
        }
        for (embedded) |plugin| {
            const path = try std.fmt.allocPrint(self.gpa, "plugins/{s}/eggy.zon", .{plugin.folder});
            defer self.gpa.free(path);
            const fetched = Fetched.create(self.gpa, .{ .path = path }, plugin.manifest, plugin.readme, null) catch |err| {
                log.err("Eggy's plugin {s} has a broken manifest: {t}", .{ plugin.folder, err });
                continue;
            };
            try list.append(self.gpa, fetched);
        }
        self.builtins = try list.toOwnedSlice(self.gpa);
    }

    fn freeBuiltins(self: *PluginsWindow) void {
        for (self.builtins) |fetched| fetched.destroy();
        self.gpa.free(self.builtins);
        self.builtins = &.{};
    }
};

/// `fetched`'s read-me, set at the editor's text size, or that it has none.
fn readme(context: *ui.Context, fetched: *const Fetched) void {
    const text = withoutTitle(fetched.readme orelse return context.muted("No README.md was provided."), fetched.manifest.title);
    const arena = context.builder().allocator;
    const typeset = ui.widgets.typeset(context.builder(), withoutInlineMarks(arena, text) catch text, .{}) catch return;
    fitToTheme(typeset, context.theme.text_size);
    context.element(typeset);
}

/// `markdown` without its first heading when that only names the plugin, `title`, which the page
/// already shows.
fn withoutTitle(markdown: []const u8, title: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, markdown, " \r\n");
    if (!std.mem.startsWith(u8, trimmed, "# ")) return markdown;
    const line_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, trimmed[2..line_end], " \r"), title)) return markdown;
    return std.mem.trimStart(u8, trimmed[line_end..], " \r\n");
}

test "a read-me's heading that only repeats the plugin's title is left out" {
    try std.testing.expectEqualStrings("Body.", withoutTitle("# Frame Stats\n\nBody.", "Frame Stats"));
    try std.testing.expectEqualStrings("# Other\n\nBody.", withoutTitle("# Other\n\nBody.", "Frame Stats"));
}

/// The manifest of the plugin inside Eggy published as `module`, read into `arena`; null when
/// none is (a plugin from elsewhere) or its manifest is broken.
///
/// ```zig
/// const manifest = plugin_manager.builtinManifest(arena, "eggy_git"); // .title "Git", ...
/// ```
pub fn builtinManifest(arena: std.mem.Allocator, module: []const u8) ?Manifest {
    for (@import("eggy_builtin_plugins").all) |plugin| {
        const manifest = eggy.plugin_manifest.parse(arena, plugin.manifest) catch continue;
        if (std.mem.eql(u8, manifest.module, module)) return manifest;
    }
    return null;
}

/// A small badge, as wide as its text.
fn badge(context: *ui.Context, text: []const u8, variant: anytype) void {
    context.badge(text, variant);
    restyle(context, .{ .width = context.font.measure(text, context.theme.small_text_size) + 20 });
}

/// Shrink `typeset`'s read-me, set for a documentation page (16-point text, headings up to 34),
/// to the editor's text: body text becomes `text_size` and headings keep their order, closer
/// together; its spacing tightens to match.
// ponytail: weeoui's typeset hard-codes its sizes; drop this once it takes the theme's.
fn fitToTheme(element: *ui.Layout.Element, text_size: f32) void {
    const docs_body = 16;
    switch (element.paint_kind) {
        .text => |*text| text.size = text_size * @sqrt(text.size / docs_body),
        else => {},
    }
    const spacing = text_size / docs_body * 0.85;
    element.style.gap *= spacing;
    inline for (.{ "left", "right", "top", "bottom" }) |side| @field(element.style.padding, side) *= spacing;
    for (element.children) |child| fitToTheme(child, text_size);
}

test "a read-me's text is set at the editor's size, headings still larger" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    context.newFrame(.{ .x = 0, .y = 0, .w = 600, .h = 400 });
    const typeset = try ui.widgets.typeset(context.builder(), "# Title\n\nBody text.", .{});
    fitToTheme(typeset, 14);
    var sizes: [2]f32 = undefined;
    var found: usize = 0;
    var stack: [16]*ui.Layout.Element = @splat(typeset);
    var depth: usize = 1;
    while (depth > 0) {
        depth -= 1;
        const element = stack[depth];
        if (element.paint_kind == .text and found < sizes.len) {
            sizes[found] = element.paint_kind.text.size;
            found += 1;
        }
        for (element.children) |child| {
            stack[depth] = child;
            depth += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), found);
    try std.testing.expectApproxEqAbs(@as(f32, 14), @min(sizes[0], sizes[1]), 0.01);
    try std.testing.expect(@max(sizes[0], sizes[1]) > 18 and @max(sizes[0], sizes[1]) < 22);
}

/// `markdown` without the inline marks `typeset` would show as they are: `**` around bold text,
/// and `[text](address)` links as their text, in `arena`.
// ponytail: drop this once weeoui's typeset styles inline markdown.
fn withoutInlineMarks(arena: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < markdown.len) {
        if (std.mem.startsWith(u8, markdown[at..], "**")) {
            at += 2;
            continue;
        }
        // A link: keep its text, drop its address.
        if (markdown[at] == '[') if (std.mem.indexOfScalarPos(u8, markdown, at, ']')) |close| {
            if (close + 1 < markdown.len and markdown[close + 1] == '(') if (std.mem.indexOfScalarPos(u8, markdown, close, ')')) |end| {
                try out.appendSlice(arena, markdown[at + 1 .. close]);
                at = end + 1;
                continue;
            };
        };
        try out.append(arena, markdown[at]);
        at += 1;
    }
    return out.items;
}

test "a read-me's bold marks and link addresses are dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Open Window > Git, see the docs.\n* a list", try withoutInlineMarks(arena.allocator(), "Open **Window > Git**, see [the docs](https://x.y/z).\n* a list"));
}

/// Whether eggy.zon texts `before` and `after` install different plugins, so the game must be
/// built again. Unreadable texts count as different.
pub fn pluginsDiffer(gpa: std.mem.Allocator, before: []const u8, after: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old = eggy.project.parse(arena, arena.dupeSentinel(u8, before, 0) catch return true) catch return true;
    const new = eggy.project.parse(arena, arena.dupeSentinel(u8, after, 0) catch return true) catch return true;
    if (old.plugins.len != new.plugins.len) return true;
    for (old.plugins, new.plugins) |a, b| {
        if (!std.mem.eql(u8, a.module, b.module) or !std.mem.eql(u8, a.version, b.version) or a.dev != b.dev) return true;
    }
    return false;
}

test {
    _ = source;
    _ = fetch_zig;
    _ = install_zig;
    _ = package_entry;
    _ = project_plugins;
    _ = @import("auto_update.zig");
    _ = @import("update_prompt.zig");
}

test "Eggy's own plugins have readable manifests that name Eggy" {
    for (@import("eggy_builtin_plugins").all) |plugin| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const manifest = try eggy.plugin_manifest.parse(arena.allocator(), plugin.manifest);
        try std.testing.expect(manifest.inEggy());
        try std.testing.expectEqual(build_options.fingerprint, manifest.fingerprint);
    }
}

test "every page of the Plugins window fits it, narrow or wide" {
    const gpa = std.testing.allocator;
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    var window = PluginsWindow{ .gpa = gpa, .window = undefined, .project_dir = @constCast("/nowhere"), .installed_arena = .init(gpa) };
    defer window.installed_arena.deinit();
    try window.readBuiltins();
    defer window.freeBuiltins();
    defer window.problem.deinit(gpa);
    window.off = &.{ "eggy_git", "a_plugin_with_a_rather_long_module_name" };
    window.installed = &.{
        .{ .module = "eggy_git", .version = "0.1.0", .dev = true },
        .{ .module = "a_second_plugin_from_the_collection", .dependency = "someone_elses_plugin_collection", .version = "1.0.0" },
        .{ .module = "a_plugin_with_a_rather_long_module_name", .dependency = "someone_elses_plugin_collection", .version = "12.0.0-beta.3", .source = "https://raw.githubusercontent.com/someone/plugins/main/x/eggy.zon" },
    };
    // A plugin fetched from elsewhere, without a read-me.
    const elsewhere = try Fetched.create(gpa, .{ .url = "https://raw.githubusercontent.com/someone/eggy-plugins/0123456789abcdef/a/very/deep/folder/eggy.zon" }, ".{ .plugin = .{ .title = \"Elsewhere\", .module = \"elsewhere\", .version = \"2.0.0\", .repository = \"https://github.com/someone/eggy-plugins\", .fingerprint = 1, .minimum_eggy_version = \"99.0.0\" } }", null, null);
    defer elsewhere.destroy();

    window.elsewhere = elsewhere;
    defer window.elsewhere = null;
    defer window.selected.deinit(gpa);
    for ([_]f32{ 560, 820 }) |width| {
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = width, .h = 600 };
        for (std.enums.values(Section)) |section| for ([_]?*Fetched{ null, window.builtins[0], elsewhere }) |reading| for ([_][]const u8{ "", "eggy_git", "a_plugin_with_a_rather_long_module_name" }) |chosen| {
            window.section = section;
            window.reading = reading;
            window.selected.clearRetainingCapacity();
            try window.selected.appendSlice(gpa, chosen);
            window.setProblem(if (section == .address) "That eggy.zon is hosted outside the repository it names, so it can't be trusted." else "");
            context.newFrame(viewport);
            window.build(&context);
            _ = try context.render();
            try @import("../ui_checks.zig").expectFits(context.last_root.?, context.font, viewport);
        };
    }
}
