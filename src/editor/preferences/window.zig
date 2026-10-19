//! Edit > Preferences: a section for the editor's preferences, one for how the editor draws
//! (graphics) and, with a project open, one for its `eggy.zon` (`project_settings.zig`), one with
//! a switch for each of its plugins and one for each plugin's preferences: each a list of rows
//! (`eggy.setting_rows`), each field with the control its kind calls for. The editor's apply to every
//! project (the global layer) or to this one (its `.eggy/`), which overrides the global value; a
//! plugin's apply to the project only. Reset drops a scope's value. Every change is saved as it
//! is made.
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
const page_style = @import("../page_style.zig");
const ProjectSettings = @import("../project_settings.zig").ProjectSettings;
const graphics_settings = eggy.graphics_settings;
const setting_rows = eggy.setting_rows;
const SettingRows = setting_rows.SettingRows;
const restyle = page_style.restyle;
const smallText = page_style.smallText;
const noteText = page_style.noteText;
const log = std.log.scoped(.preferences);

/// A section of the window: what it holds, as the window titles it, and a line on what that is.
pub const Section = struct {
    title: []const u8,
    subtitle: []const u8,
    content: union(enum) {
        /// Whose preferences.
        preferences: prefs.Manifest,
        /// The project's plugins, each with its switch.
        plugins: []const Plugin,
        /// The project's `eggy.zon`, which the caller saves after each frame.
        project: *ProjectSettings,
        /// How the editor itself draws: the user's own graphics choices, applied with a button.
        graphics: *eggy.App,
    },
};

/// A plugin the project has, and whether it is on.
pub const Plugin = struct { key: []const u8, title: []const u8, on: bool };

/// A plugin's switch flipped: turn `key` on or off.
pub const Switch = struct { key: []const u8, on: bool };

/// The most number fields a section shows.
const max_fields = 64;
const NumberEdit = ui.TextEdit(64);
const scopes = [_][]const u8{ "All projects", "This project" };
const sidebar_width: f32 = 160;
/// Which tab and scope the window shows.
const Showing = struct { section: usize, scope: usize };

pub const PreferencesWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    /// The tab shown, an index into the sections given to `update`.
    section: usize = 0,
    /// 0 for the global layer, 1 for the project's.
    scope: usize = 0,
    /// The number fields' text for the section and scope shown, which `synced` names.
    edits: [max_fields]NumberEdit = undefined,
    synced: ?Showing = null,
    /// Where changes are recorded for undo, given each frame.
    history: ?*History = null,
    /// A switch flipped this frame, for `update` to return.
    flipped: ?Switch = null,
    /// Whether the scope was picked yet: with a project, the window starts on This project,
    /// where changes usually belong.
    scope_picked: bool = false,
    /// The Graphics section's draft, loaded when it is first shown.
    graphics: graphics_settings.Form = .{},
    graphics_loaded: bool = false,
    capturing_stop_key: bool = false,
    captured_stop_key: ?eggy.Key = null,
    /// The sections' list and the section shown scroll apart.
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
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "Preferences", .{ 760, 560 }, .{ .resizable = true }) };
        return self;
    }

    /// Show the section titled `title`, if `sections` has one.
    /// Desktop editor only: exact-match lookup resets field synchronization; no match no-ops.
    /// The same section ordering must be supplied on the following update.
    ///
    /// ```zig
    /// window.show(sections, "Project"); // Existing PreferencesWindow and current sections.
    /// ```
    pub fn show(self: *PreferencesWindow, sections: []const Section, title: []const u8) void {
        for (sections, 0..) |section, i| if (std.mem.eql(u8, section.title, title)) {
            self.section = i;
            self.synced = null;
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
        return !self.capturing_stop_key and input == .key_down and input.key_down.key == .escape;
    }

    /// Handle `curr_event` if it is for this window; returns whether it was.
    /// Desktop editor only: routes raw SDL events to the tool UI; does not process close intent.
    ///
    /// ```zig
    /// const used = window.handle(event); // PreferencesWindow and raw SDL event.
    /// ```
    pub fn handle(self: *PreferencesWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (self.capturing_stop_key and curr_event == .key_down) {
            if (!curr_event.key_down.repeat) if (curr_event.key_down.scancode) |key| {
                self.captured_stop_key = key;
                self.capturing_stop_key = false;
            };
            return true;
        }
        self.window.handle(curr_event);
        return true;
    }

    /// Draw a frame of `sections` (the editor's first), whose values are in `store`; changes set
    /// them there and save them to `folders`, recording each in `history`. Returns a plugin's
    /// switch flipped this frame (its key lives as long as `sections`), for the caller to carry out.
    /// Desktop editor only: borrows style, sections/metadata, store/folders and history for the
    /// frame (history must remain valid while referenced by this window). Presentation errors
    /// propagate; preference-save errors log in the page. Project settings are edited in their
    /// Section pointer and must be saved by the caller.
    ///
    /// ```zig
    /// // Given window, graphics/style, current sections, store, Folders and History:
    /// const flipped = try window.update(graphics, style, sections, store, folders, &history);
    /// ```
    pub fn update(self: *PreferencesWindow, graphics: *eggy.Graphics, style: *const ui.Context, sections: []const Section, store: *Store, folders: files.Folders, history: *History) !?Switch {
        self.history = history;
        self.flipped = null;
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
        return self.flipped;
    }

    /// The page: the sections down the left, the one shown on the right.
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
        context.beginScroll(&self.sidebar_scroll, pane_height);
        for (sections, 0..) |section, i| self.sidebarItem(context, section.title, i);
        context.end();
        restyle(context, .{ .width = sidebar_width, .gap = 2 });
        context.beginScroll(&self.section_scroll, pane_height);
        self.buildSection(context, sections[self.section], store, folders);
        context.end();
        restyle(context, .{ .grow = 1, .gap = 16 });
        context.end();
        restyle(context, .{ .direction = .row, .gap = 24, .align_items = .start });
    }

    /// A section's row in the sidebar, lit while it is shown; pressing it shows it.
    fn sidebarItem(self: *PreferencesWindow, context: *ui.Context, title: []const u8, index: usize) void {
        const id_text = std.fmt.allocPrint(context.builder().allocator, "section {d}", .{index}) catch return;
        const id = context.idFor(id_text);
        if (context.activated(id) and self.section != index) {
            self.section = index;
            self.synced = null;
            self.section_scroll = .{};
        }
        const row = context.builder().node(id, .{ .height = 30 }, .{ .menu_item = .{ .label = title, .hot = self.section == index } }, &.{}) catch return;
        row.cursor = .pointer;
        row.accessibility = .{ .role = .tab, .label = title };
        context.element(row);
    }

    /// The section shown: its title, what it is and where its values are saved, then its settings.
    fn buildSection(self: *PreferencesWindow, context: *ui.Context, section: Section, store: *Store, folders: files.Folders) void {
        // Only the editor's preferences also apply to every project; a plugin's are the project's.
        const is_editor = section.content == .preferences and std.mem.eql(u8, section.content.preferences.key, files.editor_key);
        const scope: usize = if (is_editor) self.scope else 1;
        const saved_where: []const u8 = switch (section.content) {
            .preferences => if (!is_editor)
                "Saved in this project and built into the game."
            else if (scope == 0)
                "Your defaults for every project. A project can override them."
            else
                "For this project only, overriding All projects.",
            .plugins => "Saved in this project. A plugin that is off doesn't run in the editor or the game; its components and preferences keep their values.",
            .project => "Saved in eggy.zon as you change them.",
            .graphics => "Saved for you, not the project. Players choose their own in the game.",
        };

        // The header: the section and what it holds, and (for the editor's, with a project)
        // which layer the values go to.
        const arena = context.builder().allocator;
        context.begin(.row);
        context.begin(.column);
        context.heading(3, section.title);
        context.muted(std.fmt.allocPrint(arena, "{s} {s}", .{ section.subtitle, saved_where }) catch section.subtitle);
        smallText(context, 12);
        context.end();
        restyle(context, .{ .grow = 1, .gap = 4 });
        if (is_editor and folders.project != null) {
            if (context.tabs(&scopes, &self.scope)) self.synced = null;
        }
        context.end();
        restyle(context, .{ .direction = .row, .gap = 16, .align_items = .start });

        const manifest = switch (section.content) {
            .preferences => |manifest| manifest,
            .plugins => |plugins| return self.pluginRows(context, plugins),
            .project => |settings| return settings.build(context),
            .graphics => |app| return self.graphicsRows(context, app),
        };
        if (manifest.fields.len == 0) return context.muted("Nothing to set here.");
        const layer: Store.Layer = if (scope == 1) .project else .global;

        // The number fields start from the values shown, for each section and scope.
        const showing = Showing{ .section = self.section, .scope = scope };
        if (self.synced == null or !std.meta.eql(self.synced.?, showing)) {
            for (manifest.fields[0..@min(manifest.fields.len, max_fields)], 0..) |field, i| {
                self.edits[i] = NumberEdit.init(current(store, layer, manifest.key, field)) catch NumberEdit.init("") catch unreachable;
            }
            self.synced = showing;
        }
        var rows = SettingRows{};
        setting_rows.beginGroup(context);
        for (manifest.fields[0..@min(manifest.fields.len, max_fields)], 0..) |field, i| self.fieldRow(context, &rows, store, folders, layer, manifest.key, field, &self.edits[i]);
        setting_rows.endGroup(context);
    }

    /// The Graphics section: the editor's own choices, kept for the user beside the editor's
    /// preferences, applied (and saved) with a button.
    fn graphicsRows(self: *PreferencesWindow, context: *ui.Context, app: *eggy.App) void {
        if (!self.graphics_loaded) {
            self.graphics.load(app.graphics_options.requested);
            self.graphics_loaded = true;
        }
        setting_rows.beginGroup(context);
        graphics_settings.buildOptions(&self.graphics, context, app);
        setting_rows.endGroup(context);
        if (graphics_settings.buildButtons(&self.graphics, context, app, "Revert")) self.graphics.load(app.graphics_options.requested);
    }

    /// The Plugins section: a row per plugin with its switch.
    fn pluginRows(self: *PreferencesWindow, context: *ui.Context, plugins: []const Plugin) void {
        if (plugins.len == 0) return context.muted("This project has no plugins: list them in addGame's .plugins in build.zig.");
        const arena = context.builder().allocator;
        var rows = SettingRows{};
        setting_rows.beginGroup(context);
        for (plugins) |plugin| {
            const hidden = std.fmt.allocPrint(arena, "##plugin {s}", .{plugin.key}) catch continue;
            rows.begin(context, plugin.title, plugin.key);
            var on = plugin.on;
            if (context.toggle(hidden, &on)) self.flipped = .{ .key = plugin.key, .on = on };
            rows.end(context);
        }
        setting_rows.endGroup(context);
    }

    /// One preference as a row: its name and description on the left, its control on the right,
    /// and under the control Reset when this scope sets it, or where an inherited value is from.
    fn fieldRow(self: *PreferencesWindow, context: *ui.Context, rows: *SettingRows, store: *Store, folders: files.Folders, layer: Store.Layer, key: []const u8, field: prefs.Field, edit: *NumberEdit) void {
        const arena = context.builder().allocator;
        const title = files.displayName(arena, field.name) catch field.name;
        const value = current(store, layer, key, field);
        // Controls take their ids from their (hidden) label: the field's name.
        const hidden = std.fmt.allocPrint(arena, "##{s}", .{field.name}) catch return;
        const global_sets_it = store.literal(.global, key, field.name) != null;

        rows.begin(context, title, field.description);
        const changed: ?[]const u8 = switch (field.kind) {
            .bool => blk: {
                var on = std.mem.eql(u8, value, "true");
                break :blk if (context.toggle(hidden, &on)) (if (on) "true" else "false") else null;
            },
            .@"enum" => blk: {
                if (std.mem.eql(u8, key, files.editor_key) and std.mem.eql(u8, field.name, "stop_play_key")) {
                    const code = (if (value.len > 1) std.meta.stringToEnum(eggy.Key, value[1..]) else null) orelse (files.Editor{}).stop_play_key;
                    const label = if (self.capturing_stop_key) "Press a key..." else sdl3.keyboard.getScancodeName(code) orelse @tagName(code);
                    if (context.buttonVariant(label, .outline)) self.capturing_stop_key = true;
                    if (self.capturing_stop_key and context.buttonVariant("Cancel binding", .link)) self.capturing_stop_key = false;
                    if (self.captured_stop_key) |captured| {
                        self.captured_stop_key = null;
                        break :blk std.fmt.allocPrint(arena, ".{t}", .{captured}) catch null;
                    }
                    break :blk null;
                }
                const options = arena.alloc([]const u8, field.options.len) catch break :blk null;
                var selected: usize = 0;
                for (options, field.options, 0..) |*option, name, index| {
                    option.* = files.displayName(arena, name) catch name;
                    if (value.len > 1 and std.mem.eql(u8, value[1..], name)) selected = index;
                }
                break :blk if (context.select(hidden, options, &selected)) (std.fmt.allocPrint(arena, ".{s}", .{field.options[selected]}) catch null) else null;
            },
            .int, .float => blk: {
                if (!context.textInput(hidden, edit, field.default)) break :blk null;
                const text = std.mem.trim(u8, edit.text(), " ");
                const valid = if (field.kind == .int) !std.meta.isError(std.fmt.parseInt(i128, text, 10)) else !std.meta.isError(std.fmt.parseFloat(f64, text));
                break :blk if (valid) text else null;
            },
        };
        if (changed) |literal| self.apply(store, folders, layer, key, field.name, literal);

        // Reset drops this scope's value; a value from elsewhere says where it is from. A default
        // says nothing.
        if (store.literal(layer, key, field.name) != null) {
            const reset_label = std.fmt.allocPrint(arena, "Reset to {s}##reset {s}", .{ if (layer == .project and global_sets_it) "All projects" else "default", field.name }) catch "Reset";
            if (context.buttonVariant(reset_label, .link)) {
                self.apply(store, folders, layer, key, field.name, null);
                self.synced = null;
            }
            restyle(context, .{ .height = 20, .padding = .{} });
        } else if (layer == .project and global_sets_it) {
            context.muted("From All projects");
            noteText(context);
        }
        // All projects' value doesn't apply where the project sets its own: say so.
        if (layer == .global) if (store.literal(.project, key, field.name)) |project_value| if (folders.project != null) {
            context.muted(std.fmt.allocPrint(arena, "This project uses {s}", .{project_value}) catch "This project overrides it");
            noteText(context);
        };
        rows.end(context);
    }

    /// Set `field` of `key` in `layer` to `literal` (null clears it), and save its file.
    fn apply(self: *PreferencesWindow, store: *Store, folders: files.Folders, layer: Store.Layer, key: []const u8, field: []const u8, literal: ?[]const u8) void {
        // Undoable: what it was goes with the change.
        if (self.history) |history| history.recordPreference(layer, key, field, store.literal(layer, key, field), literal, self.window.ui.time_ms);
        store.set(layer, key, field, literal) catch |err| return log.err("cannot set {s}.{s}: {t}", .{ key, field, err });
        files.save(self.gpa, store, folders, layer, key) catch |err| log.err("cannot save {s}'s preferences: {t}", .{ key, err });
    }
};

/// What `field` of `key` is in `layer`: its own value, else (for the project) the global one,
/// else the default.
fn current(store: *const Store, layer: Store.Layer, key: []const u8, field: prefs.Field) []const u8 {
    if (store.literal(layer, key, field.name)) |value| return value;
    if (layer == .project) if (store.literal(.global, key, field.name)) |value| return value;
    return field.default;
}

test "field names become labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Show gizmos", try files.displayName(arena.allocator(), "show_gizmos"));
}

test "a project falls back on the global value, then the default" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const field = prefs.Field{ .name = "volume", .kind = .float, .default = "0.8" };
    try std.testing.expectEqualStrings("0.8", current(&store, .project, "game", field));
    try store.set(.global, "game", "volume", "0.5");
    try std.testing.expectEqualStrings("0.5", current(&store, .project, "game", field));
    try store.set(.project, "game", "volume", "0.2");
    try std.testing.expectEqualStrings("0.2", current(&store, .project, "game", field));
    try std.testing.expectEqualStrings("0.5", current(&store, .global, "game", field));
}
