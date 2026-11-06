//! Edit > Settings: pages down a sidebar in groups (this computer, the open project, its plugins),
//! with a search over every page's rows. Each page is a list of rows (`eggy.setting_rows`) in
//! cards: the editor's preferences, the graphics the editor draws with or the game ships with,
//! the project's `eggy.zon` (`project_settings.zig`), its plugins with their switches, and each
//! plugin's preferences. A row that differs from where its value would otherwise come from is
//! marked and can be reset. The editor's preferences apply to every project (the global layer) or
//! to this one (its `.eggy/`), which overrides the global value; a plugin's apply to the project
//! only. Every change is saved as it is made.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const prefs = eggy.preferences;
const Store = prefs.Store;
const weeoui_sdl3 = @import("weeoui_sdl3");
const ToolWindow = @import("../tool_window.zig").ToolWindow;
const files = @import("preferences.zig");
const History = @import("../history.zig").History;
const preference_form = @import("preference_form.zig");
const PreferenceForm = preference_form.PreferenceForm;
const page_style = @import("../page_style.zig");
const project_tile = @import("../projects/project_tile.zig");
const ProjectSettings = @import("../project_settings.zig").ProjectSettings;
const graphics_settings = eggy.graphics_settings;
const setting_rows = eggy.setting_rows;
const SettingRows = setting_rows.SettingRows;
const restyle = page_style.restyle;
const smallText = page_style.smallText;
const log = std.log.scoped(.preferences);

/// A page of the window: its heading, the sidebar group it is listed under, and what it holds.
pub const Section = struct {
    title: []const u8,
    /// The group's label in the sidebar: "This computer", the project's title, "Plugins".
    group: []const u8,
    content: Content,
};

pub const Content = union(enum) {
    /// Whose preferences.
    preferences: prefs.Manifest,
    /// The project's plugins, each with its switch.
    plugins: []const Plugin,
    /// The project's `eggy.zon`, which the caller saves after each frame.
    project: *ProjectSettings,
    /// The graphics the editor draws with, and those the game ships with.
    graphics: Graphics,
    /// Another window, which picking it in the sidebar opens.
    link: Opening,
};

/// The Graphics page: the user's own choices for `app`, and, with a project, the ones it ships
/// with in its `eggy.zon` (saved by the caller, as the Project page's are).
pub const Graphics = struct { app: *eggy.App, shipped: ?*ProjectSettings = null };

/// A plugin the project has: whether it is on, and what its manifest says of it.
pub const Plugin = struct {
    key: []const u8,
    title: []const u8,
    on: bool,
    version: []const u8 = "",
    description: []const u8 = "",
    /// Left out of exported games.
    dev: bool = false,
    /// The title of the page of its preferences, when it has any.
    settings: ?[]const u8 = null,
};

/// A plugin's switch flipped: turn `key` on or off.
pub const Switch = struct { key: []const u8, on: bool };

/// Windows the Settings window opens through the editor.
pub const Opening = enum { export_game, plugins };

/// What a frame asks of the editor.
pub const Action = union(enum) {
    none,
    flip: Switch,
    open: Opening,
    /// Restart the editor, for graphics that wait for a restart.
    restart,
};

const SearchEdit = ui.TextEdit(64);
const scopes = [_][]const u8{ "All projects##scope", "This project##scope" };
const graphics_scopes = [_][]const u8{ "This computer##graphics scope", "Shipped with the game##graphics scope" };
const sidebar_width: f32 = 232;
const nav_height: f32 = 32;
const reset_glyph = "\u{f0e2}";
const gear_glyph = "\u{f013}";
const search_glyph = "\u{f002}";

pub const PreferencesWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    /// The page shown, an index into the sections given to `update`.
    section: usize = 0,
    /// 0 for the global layer, 1 for the project's.
    scope: usize = 0,
    /// The Graphics page's: 0 for this computer's, 1 for what the game ships with.
    graphics_scope: usize = 0,
    search: SearchEdit = SearchEdit.init("") catch unreachable,
    /// The page's preferences, when it shows a manifest's.
    form: PreferenceForm = .{},
    /// Where changes are recorded for undo, given each frame.
    history: ?*History = null,
    /// What this frame asks of the editor, for `update` to return.
    action: Action = .none,
    /// Whether the scope was picked yet: with a project, the window starts on This project,
    /// where changes usually belong.
    scope_picked: bool = false,
    /// This computer's graphics, as the Graphics page edits them, loaded when it is first shown.
    graphics: graphics_settings.Form = .{},
    graphics_loaded: bool = false,
    /// The sidebar and the page shown scroll apart.
    sidebar_scroll: ui.Layout.ScrollState = .{},
    section_scroll: ui.Layout.ScrollState = .{},

    /// Open the window. On the heap, as its page keeps a pointer to it.
    /// Desktop editor only: borrows live graphics/font resources and returns a caller-managed
    /// pointer to close once. Allocation/window failures propagate with partial state cleaned up.
    ///
    /// ```zig
    /// const window = try PreferencesWindow.open(gpa, graphics, font);
    /// defer window.close(graphics); // Existing editor allocator, graphics and font.
    /// ```
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font) !*PreferencesWindow {
        const self = try gpa.create(PreferencesWindow);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "Settings", .{ 1000, 700 }, .{ .resizable = true }) };
        return self;
    }

    /// Show the page titled `title`, if `sections` has one.
    /// Desktop editor only: exact-match lookup resets field synchronization; no match no-ops.
    /// The same section ordering must be supplied on the following update.
    ///
    /// ```zig
    /// window.show(sections, "General"); // Existing PreferencesWindow and current sections.
    /// ```
    pub fn show(self: *PreferencesWindow, sections: []const Section, title: []const u8) void {
        for (sections, 0..) |section, i| if (std.mem.eql(u8, section.title, title) and section.content != .link) {
            self.showSection(i);
        };
    }

    /// Destroy the desktop preference window/render surface and free this heap instance once.
    /// Preferences were saved as edited; the pointer must not be used after this call.
    ///
    /// ```zig
    /// window.close(graphics); // Existing PreferencesWindow and owning Graphics pointer.
    /// ```
    pub fn close(self: *PreferencesWindow, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.gpa.destroy(self);
    }

    /// Whether `curr_event` asks to close the window: its close button, or Escape.
    /// Desktop editor only: accepts raw SDL events, ignores other windows and does not close it.
    ///
    /// ```zig
    /// if (window.closeRequested(event)) window.close(graphics); // Host SDL event/graphics.
    /// ```
    pub fn closeRequested(self: *const PreferencesWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (curr_event == .window_close_requested) return true;
        const input = weeoui_sdl3.translate(curr_event) orelse return false;
        return !self.form.wantsEscape() and input == .key_down and input.key_down.key == .escape;
    }

    /// Handle `curr_event` if it is for this window; returns whether it was.
    /// Desktop editor only: routes raw SDL events to the tool UI; does not process close intent.
    ///
    /// ```zig
    /// const used = window.handle(event); // PreferencesWindow and raw SDL event.
    /// ```
    pub fn handle(self: *PreferencesWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (self.form.takeKey(curr_event)) return true;
        self.window.handle(curr_event);
        return true;
    }

    /// Draw a frame of `sections` (the editor's first), whose values are in `store`; changes set
    /// them there and save them to `folders`, recording each in `history`. Returns what the frame
    /// asks of the editor (a switch's key lives as long as `sections`).
    /// Desktop editor only: borrows style, sections/metadata, store/folders and history for the
    /// frame (history must remain valid while referenced by this window). Presentation errors
    /// propagate; preference-save errors log in the page. Project settings are edited in their
    /// Section pointer and must be saved by the caller.
    ///
    /// ```zig
    /// // Given window, graphics/style, current sections, store, Folders and History:
    /// const action = try window.update(graphics, style, sections, store, folders, &history);
    /// ```
    pub fn update(self: *PreferencesWindow, graphics: *eggy.Graphics, style: *const ui.Context, sections: []const Section, store: *Store, folders: files.Folders, history: *History) !Action {
        self.history = history;
        self.action = .none;
        const Page = struct {
            window: *PreferencesWindow,
            sections: []const Section,
            store: *Store,
            folders: files.Folders,
            /// ToolWindow callback for one desktop preference frame; borrows page inputs and
            /// context synchronously, updating store/history and saving changed preferences.
            /// Failures handled by the page are logged rather than returned.
            ///
            /// ```zig
            /// // Inside PreferencesWindow.update, with its local Page and UI context:
            /// page.build(context);
            /// ```
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.window.build(context, page.sections, page.store, page.folders);
            }
        };
        var page = Page{ .window = self, .sections = sections, .store = store, .folders = folders };
        try self.window.present(graphics, style, &page);
        return self.action;
    }

    fn showSection(self: *PreferencesWindow, index: usize) void {
        if (self.section == index) return;
        self.section = index;
        self.form.forget();
        self.section_scroll = .{};
    }

    /// The page: the sidebar on the left, the page shown on the right.
    fn build(self: *PreferencesWindow, context: *ui.Context, sections: []const Section, store: *Store, folders: files.Folders) void {
        if (sections.len == 0) return;
        self.section = @min(self.section, sections.len - 1);
        if (folders.project == null) self.scope = 0;
        if (!self.scope_picked) {
            self.scope = if (folders.project != null) 1 else 0;
            self.scope_picked = true;
        }

        // Two panes the window's height, each scrolling on its own.
        const pane_height = page_style.pageHeight(context);
        context.begin(.row);
        self.buildSidebar(context, sections, store, folders, pane_height);
        context.beginScroll(&self.section_scroll, pane_height);
        self.buildSection(context, sections, store, folders);
        context.end();
        restyle(context, .{ .grow = 1, .gap = 16, .padding = .{ .left = 32, .right = 16, .top = 8, .bottom = 24 } });
        context.end();
        restyle(context, .{ .direction = .row, .gap = 0, .align_items = .start });
    }

    /// The search, then each page under its group's label, the pages a search leaves out
    /// hidden; at the bottom, that changes save as they are made.
    fn buildSidebar(self: *PreferencesWindow, context: *ui.Context, sections: []const Section, store: *Store, folders: files.Folders, height: f32) void {
        const arena = context.builder().allocator;
        context.begin(.column);
        context.beginScroll(&self.sidebar_scroll, height);
        if (context.textInput("##search settings", &self.search, search_glyph ++ "  Search settings")) self.followSearch(sections);
        restyle(context, .{ .width = sidebar_width - 24 });
        const query_text = self.query();
        var group: ?[]const u8 = null;
        var listed: usize = 0;
        for (sections, 0..) |section, i| {
            if (!sectionMatches(section, query_text)) continue;
            listed += 1;
            if (group == null or !std.mem.eql(u8, group.?, section.group)) {
                group = section.group;
                context.muted(section.group);
                smallText(context, 12);
                restyle(context, .{ .padding = .{ .left = 10, .top = 14, .bottom = 4 } });
            }
            const count = self.changedCount(section, store, folders);
            self.navItem(context, arena, section, i, count);
        }
        if (listed == 0) {
            context.muted(std.fmt.allocPrint(arena, "No setting has \"{s}\" in it.", .{query_text}) catch "");
            smallText(context, 12);
        }
        context.end();
        restyle(context, .{ .gap = 2 });
        context.end();
        if (context.last_added) |rail| rail.style = .{ .width = sidebar_width, .height = height, .padding = .{ .right = 12 } };
        page_style.railBackdrop(context);
    }

    /// A page's row in the sidebar, lit while it is shown, with how many of its settings were
    /// changed; pressing it shows the page, or opens the window it stands for.
    fn navItem(self: *PreferencesWindow, context: *ui.Context, arena: std.mem.Allocator, section: Section, index: usize, count: usize) void {
        const id = context.idFor(std.fmt.allocPrint(arena, "section {s} {s}", .{ section.group, section.title }) catch return);
        if (context.activated(id)) switch (section.content) {
            .link => |opening| self.action = .{ .open = opening },
            else => self.showSection(index),
        };
        const nav = arena.create(Nav) catch return;
        nav.* = .{ .id = id, .title = section.title, .on = self.section == index, .count = if (count > 0) std.fmt.allocPrint(arena, "{d}", .{count}) catch "" else "", .link = section.content == .link };
        const row = context.builder().node(id, .{ .width = sidebar_width - 24, .height = nav_height }, .{ .custom = .{ .context = nav, .draw = Nav.draw } }, &.{}) catch return;
        row.cursor = .pointer;
        row.accessibility = .{ .role = .tab, .label = if (count > 0) std.fmt.allocPrint(arena, "{s}, {d} changed", .{ section.title, count }) catch section.title else section.title };
        context.element(row);
    }

    /// The search's text, trimmed.
    fn query(self: *const PreferencesWindow) []const u8 {
        return std.mem.trim(u8, self.search.text(), " ");
    }

    /// When the search leaves out the page shown, show the first page it keeps.
    fn followSearch(self: *PreferencesWindow, sections: []const Section) void {
        const query_text = self.query();
        if (sectionMatches(sections[@min(self.section, sections.len - 1)], query_text)) return;
        for (sections, 0..) |section, i| if (section.content != .link and sectionMatches(section, query_text)) return self.showSection(i);
    }

    /// How many of `section`'s settings differ from where they'd otherwise come from, for its
    /// count in the sidebar.
    fn changedCount(self: *const PreferencesWindow, section: Section, store: *const Store, folders: files.Folders) usize {
        _ = self;
        switch (section.content) {
            .preferences => |manifest| {
                const layer: Store.Layer = if (folders.project != null) .project else .global;
                var count: usize = 0;
                for (manifest.fields) |field| {
                    if (!std.mem.eql(u8, preference_form.current(store, layer, manifest.key, field), field.default)) count += 1;
                }
                return count;
            },
            .graphics => |graphics| return graphics_settings.changedRows(graphics.app.graphics_options.requested, graphics.app.graphics_options.defaults),
            else => return 0,
        }
    }

    /// The page shown: its heading and what it holds, a scope switch where it has one, then its
    /// settings. Rows a search leaves out are hidden, unless the page's own title matches.
    fn buildSection(self: *PreferencesWindow, context: *ui.Context, sections: []const Section, store: *Store, folders: files.Folders) void {
        const section = sections[self.section];
        // Only the editor's preferences also apply to every project; a plugin's are the project's.
        const is_editor = section.content == .preferences and std.mem.eql(u8, section.content.preferences.key, files.editor_key);
        const shipped = if (section.content == .graphics) section.content.graphics.shipped else null;
        const query_text = if (setting_rows.matches(self.query(), section.title, "")) "" else self.query();

        context.begin(.row);
        context.begin(.column);
        // A heading's size without its rule, which would stop short of the scope switch.
        if (context.builder().node(0, .{}, .{ .text = .{ .value = section.title, .size = 22 } }, &.{})) |heading| {
            heading.accessibility = .{ .role = .heading, .label = section.title };
            context.element(heading);
        } else |_| {}
        context.end();
        restyle(context, .{ .grow = 1, .gap = 4 });
        if (is_editor and folders.project != null) {
            if (context.tabs(&scopes, &self.scope)) self.form.forget();
        } else if (shipped != null) {
            if (context.tabs(&graphics_scopes, &self.graphics_scope)) self.graphics_loaded = false;
        } else if (section.content == .plugins) {
            if (context.buttonVariant("Install plugin", .outline)) self.action = .{ .open = .plugins };
        }
        context.end();
        restyle(context, .{ .direction = .row, .gap = 16, .align_items = .end, .padding = .{ .bottom = 8 } });

        const manifest = switch (section.content) {
            .preferences => |manifest| manifest,
            .plugins => |plugins| return self.pluginRows(context, plugins, query_text, sections),
            .project => |settings| return settings.build(context, query_text),
            .graphics => |graphics| return if (shipped != null and self.graphics_scope == 1) shipped.?.buildGraphics(context, query_text) else self.graphicsRows(context, graphics, query_text),
            .link => return,
        };
        if (manifest.fields.len == 0) return context.muted("Nothing to set here.");
        const scope: usize = if (is_editor) self.scope else 1;
        const layer: Store.Layer = if (scope == 1) .project else .global;

        self.form.build(context, manifest, query_text, .{ .gpa = self.gpa, .store = store, .folders = folders, .layer = layer, .history = self.history, .now_ms = self.window.ui.time_ms });
    }

    /// The Graphics page for this computer: the user's own choices, on top of the game's (the
    /// project's defaults), applied and saved as they change. A choice that waits for a restart
    /// says so under the rows, with a button restarting the editor.
    fn graphicsRows(self: *PreferencesWindow, context: *ui.Context, graphics: Graphics, query_text: []const u8) void {
        const app = graphics.app;
        if (!self.graphics_loaded) {
            self.graphics.load(app.graphics_options.requested);
            self.graphics_loaded = true;
        }
        if (app.graphics_options.warning) context.alert("Saved settings not used", "They couldn't be applied, so the defaults are in use.", true);
        const caps = app.graphics.capabilities();
        const changed = self.graphics.build(context, .{
            .caps = &caps,
            .adapters_backend = app.graphics.render_settings.backend,
            .baseline = app.graphics_options.defaults,
            .baseline_label = if (graphics.shipped != null) "Game ships" else "Default is",
            .query = query_text,
            .cards = true,
        });
        // A number half typed waits until it is one.
        if (changed) if (self.graphics.read()) |draft| {
            _ = app.saveGraphicsSettings(draft) catch |err| self.graphics.report(err);
        } else |_| {};
        self.graphics.notice(context);

        if (!app.graphics_options.requested.requiresRestart(app.graphics.render_settings)) return;
        context.begin(.card);
        context.text("Some changes take effect after a restart.");
        restyle(context, .{ .grow = 1 });
        if (context.button("Restart now")) self.action = .restart;
        context.end();
        restyle(context, .{ .direction = .row, .gap = 14, .align_items = .center, .padding = .{ .left = 20, .right = 14, .top = 12, .bottom = 12 } });
    }

    /// The Plugins page: a row per plugin with its tile, version, what it does, a way to its
    /// settings and its switch.
    fn pluginRows(self: *PreferencesWindow, context: *ui.Context, plugins: []const Plugin, query_text: []const u8, sections: []const Section) void {
        if (plugins.len == 0) return context.muted("No plugins yet.");
        const arena = context.builder().allocator;
        var rows = SettingRows{ .query = query_text };
        var card_open = false;
        for (plugins) |plugin| {
            if (!rows.shows(plugin.title, plugin.description)) continue;
            if (!card_open) setting_rows.beginGroup(context);
            card_open = true;
            rows.divide(context);
            context.begin(.row);

            project_tile.add(context, plugin.title, 36);

            context.begin(.column);
            context.begin(.row);
            context.text(plugin.title);
            if (plugin.version.len > 0) {
                context.muted(plugin.version);
                smallText(context, 12);
            }
            if (plugin.dev) context.badge("Editor only", .secondary);
            context.end();
            restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center });
            if (plugin.description.len > 0) {
                context.muted(plugin.description);
                smallText(context, 12);
                if (context.last_added) |line| if (line.paint_kind == .text) {
                    line.paint_kind.text.wrap = true;
                };
            }
            context.end();
            restyle(context, .{ .grow = 1, .gap = 3 });

            if (plugin.settings) |title| {
                if (context.buttonVariant(std.fmt.allocPrint(arena, gear_glyph ++ "##settings {s}", .{plugin.key}) catch gear_glyph, .ghost)) self.show(sections, title);
                if (context.last_added) |button| {
                    button.style.width = SettingRows.reset_width;
                    button.accessibility.label = std.fmt.allocPrint(arena, "{s} settings", .{plugin.title}) catch "Settings";
                }
            }
            var on = plugin.on;
            if (context.toggle(std.fmt.allocPrint(arena, "##plugin {s}", .{plugin.key}) catch continue, &on)) self.action = .{ .flip = .{ .key = plugin.key, .on = on } };
            context.end();
            restyle(context, .{ .direction = .row, .gap = 14, .align_items = .center, .padding = .{ .top = 12, .bottom = 12 } });
        }
        if (card_open) setting_rows.endGroup(context);
    }
};

/// A sidebar row: its title, lit while shown or hovered, with a count of changes in a pill.
const Nav = struct {
    id: u32,
    title: []const u8,
    on: bool,
    count: []const u8,
    /// Opens another window rather than a page.
    link: bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Nav = @ptrCast(@alignCast(context));
        const t = c.theme;
        if (self.on or c.hot_id == self.id) try c.roundRect(r, t.muted, t.radiusMd());
        const size = t.text_size;
        try c.textIn(.{ .x = r.x + 10, .y = r.y, .w = r.w - 20, .h = r.h }, self.title, size, t.foreground, .start);
        if (self.link) try c.textIn(.{ .x = r.x + 10, .y = r.y, .w = r.w - 20, .h = r.h }, "\u{f08e}", 11, t.muted_foreground, .end);
        if (self.count.len == 0) return;
        const pill_w = @max(18, c.font.measure(self.count, 11) + 10);
        const pill = ui.Rect{ .x = r.x + r.w - 8 - pill_w, .y = r.y + (r.h - 18) / 2, .w = pill_w, .h = 18 };
        try c.roundRect(pill, t.primary, 9);
        try c.textIn(pill, self.count, 11, t.primary_foreground, .center);
    }
};

/// Whether `section` has `query` in its title or any of its rows; an empty query keeps all.
fn sectionMatches(section: Section, query_text: []const u8) bool {
    if (setting_rows.matches(query_text, section.title, "")) return true;
    switch (section.content) {
        .preferences => |manifest| for (manifest.fields) |field| {
            var buffer: [64]u8 = undefined;
            const title = displayNameInto(&buffer, field.name);
            if (setting_rows.matches(query_text, title, field.description)) return true;
        },
        .graphics => return graphics_settings.anyRowMatches(query_text),
        .project => return ProjectSettings.matches(query_text),
        .plugins => |plugins| for (plugins) |plugin| {
            if (setting_rows.matches(query_text, plugin.title, plugin.description)) return true;
        },
        .link => {},
    }
    return false;
}

/// `name` as `files.displayName` shows it, in `buffer` (cut to fit).
fn displayNameInto(buffer: []u8, name: []const u8) []const u8 {
    var fixed = std.heap.FixedBufferAllocator.init(buffer);
    return files.displayName(fixed.allocator(), name[0..@min(name.len, buffer.len)]) catch name;
}

test "field names become labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Show gizmos", try files.displayName(arena.allocator(), "show_gizmos"));
}

test "a search keeps the pages with a matching row" {
    const section = Section{ .title = "Editor", .group = "This computer", .content = .{ .preferences = files.editor_manifest } };
    try std.testing.expect(sectionMatches(section, ""));
    try std.testing.expect(sectionMatches(section, "autosave"));
    try std.testing.expect(!sectionMatches(section, "anisotropic"));
}
