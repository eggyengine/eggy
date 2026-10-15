//! Edit > Preferences: a section for the editor's preferences and, with a project open, one for
//! each plugin's, each field with the control its kind calls for. The editor's apply to every
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
const log = std.log.scoped(.preferences);

/// A section of the window: whose preferences, as the window titles them, and a line on what
/// they are.
pub const Section = struct { title: []const u8, subtitle: []const u8, manifest: prefs.Manifest };

/// The most number fields a section shows.
const max_fields = 64;
const NumberEdit = ui.TextEdit(64);
const scopes = [_][]const u8{ "All projects", "This project" };
const sidebar_width: f32 = 170;
const control_width: f32 = 200;
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
    /// Whether the scope was picked yet: with a project, the window starts on This project,
    /// where changes usually belong.
    scope_picked: bool = false,

    /// Open the window. On the heap, as its page keeps a pointer to it.
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font) !*PreferencesWindow {
        const self = try gpa.create(PreferencesWindow);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "Preferences", .{ 620, 520 }, .{ .resizable = true }) };
        return self;
    }

    pub fn close(self: *PreferencesWindow, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.gpa.destroy(self);
    }

    /// Whether `curr_event` asks to close the window: its close button, or Escape.
    pub fn closeRequested(self: *const PreferencesWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (curr_event == .window_close_requested) return true;
        const input = weeoui_sdl3.translate(curr_event) orelse return false;
        return input == .key_down and input.key_down.key == .escape;
    }

    /// Handle `curr_event` if it is for this window; returns whether it was.
    pub fn handle(self: *PreferencesWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        self.window.handle(curr_event);
        return true;
    }

    /// Draw a frame of `sections` (the editor's first), whose values are in `store`; changes set
    /// them there and save them to `folders`.
    pub fn update(self: *PreferencesWindow, graphics: *eggy.Graphics, style: *const ui.Context, sections: []const Section, store: *Store, folders: files.Folders) !void {
        const Page = struct {
            window: *PreferencesWindow,
            sections: []const Section,
            store: *Store,
            folders: files.Folders,
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.window.build(context, page.sections, page.store, page.folders);
            }
        };
        var page = Page{ .window = self, .sections = sections, .store = store, .folders = folders };
        try self.window.present(graphics, style, &page);
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

        context.begin(.row);
        context.begin(.column);
        for (sections, 0..) |section, i| self.sidebarItem(context, section.title, i);
        context.end();
        restyle(context, .{ .width = sidebar_width, .gap = 2 });
        context.begin(.column);
        self.buildSection(context, sections[self.section], store, folders);
        context.end();
        restyle(context, .{ .grow = 1, .gap = 10 });
        context.end();
        restyle(context, .{ .direction = .row, .gap = 20, .align_items = .start });
    }

    /// A section's row in the sidebar, lit while it is shown; pressing it shows it.
    fn sidebarItem(self: *PreferencesWindow, context: *ui.Context, title: []const u8, index: usize) void {
        const id_text = std.fmt.allocPrint(context.builder().allocator, "section {d}", .{index}) catch return;
        const id = context.idFor(id_text);
        if (context.activated(id) and self.section != index) {
            self.section = index;
            self.synced = null;
        }
        const row = context.builder().node(id, .{ .height = 30 }, .{ .menu_item = .{ .label = title, .hot = self.section == index } }, &.{}) catch return;
        row.cursor = .pointer;
        row.accessibility = .{ .role = .tab, .label = title };
        context.element(row);
    }

    /// The section shown: its title and where its values apply, then a card per preference.
    fn buildSection(self: *PreferencesWindow, context: *ui.Context, section: Section, store: *Store, folders: files.Folders) void {
        // The header: the section, and (with a project) which layer the values go to.
        context.begin(.row);
        context.begin(.column);
        context.heading(3, section.title);
        context.muted(section.subtitle);
        smallText(context, 13);
        context.end();
        restyle(context, .{ .grow = 1, .gap = 2 });
        // Only the editor's preferences also apply to every project; a plugin's are the project's.
        const is_editor = std.mem.eql(u8, section.manifest.key, files.editor_key);
        if (is_editor and folders.project != null) {
            if (context.tabs(&scopes, &self.scope)) self.synced = null;
        }
        context.end();
        restyle(context, .{ .direction = .row, .gap = 16, .align_items = .center });
        const scope: usize = if (is_editor) self.scope else 1;
        context.muted(if (!is_editor)
            "Saved in this project's .eggy folder and built into the game."
        else if (scope == 0)
            "Your defaults for every project, kept in Eggy's data folder. A project can override them."
        else
            "Saved in this project's .eggy folder, overriding All projects.");
        smallText(context, 12);

        const layer: Store.Layer = if (scope == 1) .project else .global;
        const manifest = section.manifest;
        if (manifest.fields.len == 0) return context.muted("Nothing to set here.");

        // The number fields start from the values shown, for each section and scope.
        const showing = Showing{ .section = self.section, .scope = scope };
        if (self.synced == null or !std.meta.eql(self.synced.?, showing)) {
            for (manifest.fields[0..@min(manifest.fields.len, max_fields)], 0..) |field, i| {
                self.edits[i] = NumberEdit.init(current(store, layer, manifest.key, field)) catch NumberEdit.init("") catch unreachable;
            }
            self.synced = showing;
        }
        for (manifest.fields[0..@min(manifest.fields.len, max_fields)], 0..) |field, i| self.fieldCard(context, store, folders, layer, manifest.key, field, &self.edits[i]);
    }

    /// One preference: its name and description on the left, its control on the right, and
    /// under the control where the value comes from (or Reset, when this scope sets it).
    fn fieldCard(self: *PreferencesWindow, context: *ui.Context, store: *Store, folders: files.Folders, layer: Store.Layer, key: []const u8, field: prefs.Field, edit: *NumberEdit) void {
        const arena = context.builder().allocator;
        const title = files.displayName(arena, field.name) catch field.name;
        const value = current(store, layer, key, field);
        // Controls take their ids from their (hidden) label: the field's name.
        const hidden = std.fmt.allocPrint(arena, "##{s}", .{field.name}) catch return;

        context.begin(.card);
        context.begin(.row);
        context.begin(.column);
        context.text(title);
        if (field.description.len > 0) {
            context.muted(field.description);
            smallText(context, 13);
        }
        context.end();
        restyle(context, .{ .grow = 1, .gap = 4 });

        context.begin(.column);
        const changed: ?[]const u8 = switch (field.kind) {
            .bool => blk: {
                var on = std.mem.eql(u8, value, "true");
                break :blk if (context.toggle(hidden, &on)) (if (on) "true" else "false") else null;
            },
            .@"enum" => blk: {
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

        // Where the value comes from; Reset drops this scope's value.
        if (store.literal(layer, key, field.name) != null) {
            const reset_label = std.fmt.allocPrint(arena, "Reset to {s}##reset {s}", .{ if (layer == .project and store.literal(.global, key, field.name) != null) "All projects" else "default", field.name }) catch return;
            if (context.buttonVariant(reset_label, .link)) {
                self.apply(store, folders, layer, key, field.name, null);
                self.synced = null;
            }
            restyle(context, .{ .height = 20, .padding = .{} });
        } else {
            context.muted(if (layer == .project and store.literal(.global, key, field.name) != null) "From All projects" else "Default");
            noteText(context);
        }
        // All projects' value doesn't apply where the project sets its own: say so.
        if (layer == .global) if (store.literal(.project, key, field.name)) |project_value| if (folders.project != null) {
            context.muted(std.fmt.allocPrint(arena, "This project uses {s}", .{project_value}) catch "This project overrides it");
            noteText(context);
        };
        context.end();
        restyle(context, .{ .width = control_width, .gap = 4, .align_items = .end });
        context.end();
        restyle(context, .{ .direction = .row, .gap = 20, .align_items = .center });
        context.end();
        restyle(context, .{ .padding = .{ .left = 16, .right = 16, .top = 12, .bottom = 12 } });
    }

    /// Set `field` of `key` in `layer` to `literal` (null clears it), and save its file.
    fn apply(self: *PreferencesWindow, store: *Store, folders: files.Folders, layer: Store.Layer, key: []const u8, field: []const u8, literal: ?[]const u8) void {
        store.set(layer, key, field, literal) catch |err| return log.err("cannot set {s}.{s}: {t}", .{ key, field, err });
        files.save(self.gpa, store, folders, layer, key) catch |err| log.err("cannot save {s}'s preferences: {t}", .{ key, err });
    }
};

/// Restyle the element `context` added last: a widget, or a container just ended. `layout`
/// sets the fields that matter for this window; a container keeps its children.
fn restyle(context: *ui.Context, layout: struct {
    width: ?f32 = null,
    height: ?f32 = null,
    grow: ?f32 = null,
    gap: ?f32 = null,
    direction: ?@FieldType(ui.Layout.Style, "direction") = null,
    align_items: ?@FieldType(ui.Layout.Style, "align_items") = null,
    padding: ?@FieldType(ui.Layout.Style, "padding") = null,
}) void {
    const element = context.last_added orelse return;
    if (layout.width) |width| element.style.width = width;
    if (layout.height) |height| element.style.height = height;
    if (layout.grow) |grow| element.style.grow = grow;
    if (layout.gap) |gap| element.style.gap = gap;
    if (layout.direction) |direction| element.style.direction = direction;
    if (layout.align_items) |align_items| element.style.align_items = align_items;
    if (layout.padding) |padding| element.style.padding = padding;
    // Rows here keep to one line, and cards fill the width rather than stopping at 640.
    element.style.wrap = false;
    element.style.max_width = null;
}

/// Make the text `context` added last a small note under a control, right-aligned with it.
fn noteText(context: *ui.Context) void {
    smallText(context, 12);
    const element = context.last_added orelse return;
    if (element.paint_kind == .text) element.paint_kind.text.alignment = .end;
}

/// Make the text `context` added last `size` tall.
fn smallText(context: *ui.Context, size: f32) void {
    const element = context.last_added orelse return;
    if (element.paint_kind == .text) element.paint_kind.text.size = size;
}

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
