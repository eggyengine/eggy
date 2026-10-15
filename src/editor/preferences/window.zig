//! Edit > Preferences: a tab for the editor's preferences and one for each plugin's, each field
//! with the control its kind calls for. They apply to every project (the global layer) or, with a
//! project open, to this one (its `.eggy/`), which overrides the global value; Reset drops a
//! scope's value. Every change is saved as it is made.
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

/// A tab: whose preferences, as the window titles them.
pub const Section = struct { title: []const u8, manifest: prefs.Manifest };

/// The most number fields a section shows.
const max_fields = 64;
const NumberEdit = ui.TextEdit(64);
const scopes = [_][]const u8{ "All projects", "This project" };
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

    fn build(self: *PreferencesWindow, context: *ui.Context, sections: []const Section, store: *Store, folders: files.Folders) void {
        const arena = context.builder().allocator;
        if (sections.len == 0) return;
        self.section = @min(self.section, sections.len - 1);

        // Whose preferences, and where they apply.
        const titles = arena.alloc([]const u8, sections.len) catch return;
        for (titles, sections) |*title, section| title.* = section.title;
        _ = context.tabs(titles, &self.section);
        if (folders.project == null) self.scope = 0;
        if (folders.project != null) _ = context.select("Applies to", &scopes, &self.scope);
        const layer: Store.Layer = if (self.scope == 1) .project else .global;
        const manifest = sections[self.section].manifest;
        if (manifest.fields.len == 0) return context.muted("No preferences.");

        // The number fields start from the values shown, for each tab and scope.
        const showing = Showing{ .section = self.section, .scope = self.scope };
        if (self.synced == null or !std.meta.eql(self.synced.?, showing)) {
            for (manifest.fields[0..@min(manifest.fields.len, max_fields)], 0..) |field, i| {
                self.edits[i] = NumberEdit.init(current(store, layer, manifest.key, field)) catch NumberEdit.init("") catch unreachable;
            }
            self.synced = showing;
        }

        for (manifest.fields[0..@min(manifest.fields.len, max_fields)], 0..) |field, i| {
            const label = humanize(arena, field.name) catch field.name;
            const value = current(store, layer, manifest.key, field);
            const changed: ?[]const u8 = switch (field.kind) {
                .bool => blk: {
                    var on = std.mem.eql(u8, value, "true");
                    break :blk if (context.checkbox(label, &on)) (if (on) "true" else "false") else null;
                },
                .@"enum" => blk: {
                    const options = arena.alloc([]const u8, field.options.len) catch break :blk null;
                    for (options, field.options) |*option, name| option.* = name;
                    var selected: usize = 0;
                    for (field.options, 0..) |name, index| {
                        if (value.len > 1 and std.mem.eql(u8, value[1..], name)) selected = index;
                    }
                    break :blk if (context.select(label, options, &selected)) (std.fmt.allocPrint(arena, ".{s}", .{field.options[selected]}) catch null) else null;
                },
                .int, .float => blk: {
                    const edit = &self.edits[i];
                    if (!context.textInput(label, edit, field.default)) break :blk null;
                    const text = std.mem.trim(u8, edit.text(), " ");
                    const valid = if (field.kind == .int) std.meta.isError(std.fmt.parseInt(i128, text, 10)) == false else std.meta.isError(std.fmt.parseFloat(f64, text)) == false;
                    break :blk if (valid) text else null;
                },
            };
            if (field.description.len > 0) context.muted(field.description);
            if (changed) |literal| self.apply(store, folders, layer, manifest.key, field.name, literal);

            // Reset: drop this scope's value, back to the global one or the default.
            if (store.literal(layer, manifest.key, field.name) != null) {
                const reset_label = std.fmt.allocPrint(arena, "Reset##{s}", .{field.name}) catch continue;
                if (context.buttonVariant(reset_label, .ghost)) {
                    self.apply(store, folders, layer, manifest.key, field.name, null);
                    self.synced = null;
                }
            }
            context.separator();
        }
    }

    /// Set `field` of `key` in `layer` to `literal` (null clears it), and save its file.
    fn apply(self: *PreferencesWindow, store: *Store, folders: files.Folders, layer: Store.Layer, key: []const u8, field: []const u8, literal: ?[]const u8) void {
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

/// `show_gizmos` as "Show gizmos".
fn humanize(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const label = try arena.dupe(u8, name);
    for (label) |*char| if (char.* == '_') {
        char.* = ' ';
    };
    if (label.len > 0) label[0] = std.ascii.toUpper(label[0]);
    return label;
}

test "field names become labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Show gizmos", try humanize(arena.allocator(), "show_gizmos"));
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
