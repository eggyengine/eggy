//! The Assets panel: the project's files, to find and open them. As a list it is a tree of the
//! whole project, folders opening in place; as a grid it is one folder's tiles, with a path to
//! climb back up. A filter searches every folder by name. A scene (`.scene.zon`) opens with a
//! double-click, New scene starts an empty one, and any other file shows in the system's file
//! manager.
//!
//! Like the Hierarchy, the panel doesn't act itself: `build` and `pointer` return the `Action`.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const L = ui.Layout;
const listing = @import("listing.zig");
const icons_zig = @import("icons.zig");
const Icons = icons_zig.Icons;
const Icon = icons_zig.Icon;
const page_style = @import("../page_style.zig");

pub const Action = union(enum) {
    /// Open this scene (relative to the project), replacing the world.
    open_scene: []const u8,
    /// Start a new, empty scene and open it.
    create_scene,
    /// Show this file or folder (relative to the project) in the system's file manager.
    reveal: []const u8,
};

pub const View = enum { list, grid };

/// Item `i` of the last build has element id `item_id_base + i`.
const item_id_base: u32 = 0x6F00_0000;
const row_height: f32 = 24;
const indent: f32 = 14;
const tile_width: f32 = 84;
const tile_height: f32 = 84;
/// How often the listing is read again from disk, to catch files changed elsewhere.
const refresh_ms = 1000;
/// The most a filter lists, and the most folders it searches.
const max_found = 500;
const max_searched = 2000;

const FilterEdit = ui.TextEdit(64);

/// An entry as shown: in the list's tree, at a depth.
const Shown = struct { entry: listing.Entry, depth: usize, open: bool = false };

pub const AssetsPanel = struct {
    gpa: std.mem.Allocator,
    view: View = .list,
    filter: FilterEdit = FilterEdit.init("") catch unreachable,
    /// The grid's folder, relative to the project; empty for the project itself.
    folder: std.ArrayList(u8) = .empty,
    /// The list's open folders.
    expanded: std.StringHashMapUnmanaged(void) = .empty,
    /// The entry picked last.
    selected: std.ArrayList(u8) = .empty,
    /// What is shown, read from disk at most every `refresh_ms` or when what is shown changes.
    shown: []const Shown = &.{},
    shown_arena: std.heap.ArenaAllocator,
    read_at_ms: ?u64 = null,
    /// What the listing was read for, to tell when to read it again.
    read_for: struct { view: View = .list, filter: std.ArrayList(u8) = .empty, folder: std.ArrayList(u8) = .empty, expanded: usize = 0 } = .{},

    pub fn init(gpa: std.mem.Allocator) AssetsPanel {
        return .{ .gpa = gpa, .shown_arena = .init(gpa) };
    }

    pub fn deinit(self: *AssetsPanel) void {
        self.folder.deinit(self.gpa);
        self.selected.deinit(self.gpa);
        var keys = self.expanded.keyIterator();
        while (keys.next()) |key| self.gpa.free(key.*);
        self.expanded.deinit(self.gpa);
        self.read_for.filter.deinit(self.gpa);
        self.read_for.folder.deinit(self.gpa);
        self.shown_arena.deinit();
    }

    /// Draw the panel for the project in `project_dir` (none: nothing to show) into `context`,
    /// marking `open_scene` (relative to it). Returns what the user did this frame, if anything.
    pub fn build(self: *AssetsPanel, context: *ui.Context, project_dir: ?[]const u8, icons: *const Icons, open_scene: ?[]const u8) ?Action {
        const dir = project_dir orelse {
            context.muted("Open a project to see its files.");
            page_style.smallText(context, 13);
            return null;
        };
        var action: ?Action = null;

        // The filter on a line of its own, then list or grid, and New scene, wrapping when narrow.
        _ = context.textInput("##asset filter", &self.filter, "Find files");
        context.begin(.row);
        var view_index: usize = @intFromEnum(self.view);
        if (context.tabs(&.{ "List", "Grid" }, &view_index)) self.view = @enumFromInt(view_index);
        if (context.buttonVariant("New scene", .outline)) action = .create_scene;
        context.end();
        page_style.restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center });
        if (context.last_added) |tools| tools.style.wrap = true;

        self.refresh(dir, context.time_ms);
        const searching = self.filter.text().len > 0;
        if (self.view == .grid and !searching) self.breadcrumbs(context);

        if (self.shown.len == 0) {
            context.muted(if (searching) "No file matches." else "This folder is empty.");
            page_style.smallText(context, 13);
            return action;
        }
        if (self.view == .grid and !searching) {
            context.begin(.row);
            for (self.shown, 0..) |item, i| self.tile(context, icons, item, i, open_scene);
            context.end();
            page_style.restyle(context, .{ .direction = .row, .gap = 6 });
            // Tiles wrap onto more lines.
            if (context.last_added) |grid| grid.style.wrap = true;
        } else {
            context.begin(.column);
            for (self.shown, 0..) |item, i| self.row(context, icons, item, i, open_scene, searching);
            context.end();
            page_style.restyle(context, .{ .gap = 0 });
        }

        // A press picks an entry; in the list, a folder opens or closes too.
        for (self.shown, 0..) |item, i| if (context.activated(item_id_base + @as(u32, @intCast(i)))) {
            self.select(item.entry.path);
            if (self.view == .list and !searching and item.entry.kind == .folder) self.toggle(item.entry.path);
        };
        return action;
    }

    /// Route a pointer event over the panel before its UI sees it: a double-click opens the
    /// entry under it (a scene opens, a folder opens in the grid, anything else shows in the
    /// file manager). `context` has last frame's layout.
    pub fn pointer(self: *AssetsPanel, context: *const ui.Context, event: ui.input.Event) struct { used: bool, action: ?Action = null } {
        const down = switch (event) {
            .pointer_down => |down| down,
            else => return .{ .used = false },
        };
        if (down.button != .left or down.clicks < 2) return .{ .used = false };
        const item = self.itemAt(context, down.position) orelse return .{ .used = false };
        const entry = item.entry;
        return switch (entry.kind) {
            .scene => .{ .used = true, .action = .{ .open_scene = entry.path } },
            .folder => blk: {
                if (self.view == .grid and self.filter.text().len == 0) {
                    self.enter(entry.path);
                    break :blk .{ .used = true };
                }
                break :blk .{ .used = false }; // the list opens folders with one press
            },
            else => .{ .used = true, .action = .{ .reveal = entry.path } },
        };
    }

    /// One row of the list: indented by depth, a folder's chevron, its icon and name.
    fn row(self: *const AssetsPanel, context: *ui.Context, icons: *const Icons, item: Shown, index: usize, open_scene: ?[]const u8, searching: bool) void {
        const b = context.builder();
        const arena = b.allocator;
        const id = item_id_base + @as(u32, @intCast(index));
        const left = indent * @as(f32, @floatFromInt(item.depth));
        const width = context.contentWidth();
        const is_open = if (open_scene) |path| std.mem.eql(u8, path, item.entry.path) else false;
        const note: []const u8 = if (is_open) "open" else if (searching) listing.parentOf(item.entry.path) else "";
        // What the row leaves the name: its padding, the chevron, the icon, three gaps, the note.
        const note_text = page_style.fitText(arena, context.font, note, 11, @max(0, width * 0.4));
        const name_room = width - (left + 4) - 6 - 12 - 16 - 3 * 6 - context.font.measure(note_text, 11);
        const name = page_style.fitText(arena, context.font, item.entry.name, 12, @max(0, name_room));

        const chevron = if (item.entry.kind == .folder and !searching)
            b.node(0, .{ .width = 12, .height = 12 }, .{ .icon = if (item.open) .chevron_down else .chevron_right }, &.{}) catch return
        else
            b.node(0, .{ .width = 12, .height = 12 }, .none, &.{}) catch return;
        const icon = if (item.entry.kind == .folder and item.open) Icon.folder_open else Icon.of(item.entry.kind);
        const children = [_]*L.Element{
            chevron,
            b.node(0, .{ .width = 16, .height = 16 }, icons.paint(icon, context.theme), &.{}) catch return,
            b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = name, .size = 12 } }, &.{}) catch return,
            b.node(0, .{}, .{ .text = .{ .value = note_text, .size = 11, .tone = .muted } }, &.{}) catch return,
        };
        const element = b.node(id, .{ .height = row_height, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = left + 4, .right = 6 } }, highlight(arena, id, self.isSelected(item.entry.path)), &children) catch return;
        element.cursor = .pointer;
        element.accessibility = .{ .role = .menu_item, .label = item.entry.name };
        context.element(element);
    }

    /// One tile of the grid: the icon above the name.
    fn tile(self: *const AssetsPanel, context: *ui.Context, icons: *const Icons, item: Shown, index: usize, open_scene: ?[]const u8) void {
        const b = context.builder();
        const arena = b.allocator;
        const id = item_id_base + @as(u32, @intCast(index));
        const is_open = if (open_scene) |path| std.mem.eql(u8, path, item.entry.path) else false;
        const name = page_style.fitText(arena, context.font, item.entry.name, 11, tile_width - 12);
        const element = b.node(id, .{ .width = tile_width, .height = tile_height, .align_items = .center, .gap = 6, .padding = .{ .top = 10, .left = 6, .right = 6 } }, highlight(arena, id, self.isSelected(item.entry.path) or is_open), &.{
            b.node(0, .{ .width = 40, .height = 40 }, icons.paint(Icon.of(item.entry.kind), context.theme), &.{}) catch return,
            b.node(0, .{}, .{ .text = .{ .value = name, .size = 11, .alignment = .center } }, &.{}) catch return,
        }) catch return;
        element.cursor = .pointer;
        element.accessibility = .{ .role = .button, .label = item.entry.name };
        context.element(element);
    }

    /// The grid's folder as a path of links back up to the project.
    fn breadcrumbs(self: *AssetsPanel, context: *ui.Context) void {
        const arena = context.builder().allocator;
        context.begin(.row);
        if (context.buttonVariant("Project##crumb", .link)) self.enter("");
        var end: usize = 0;
        var parts = std.mem.tokenizeScalar(u8, self.folder.items, '/');
        while (parts.next()) |part| {
            end = parts.index;
            context.muted("/");
            const label = std.fmt.allocPrint(arena, "{s}##crumb {d}", .{ page_style.fitText(arena, context.font, part, 14, 120), end }) catch return;
            if (context.buttonVariant(label, .link)) {
                const target = arena.dupe(u8, self.folder.items[0..end]) catch return;
                self.enter(target);
            }
        }
        context.end();
        page_style.restyle(context, .{ .direction = .row, .gap = 4, .align_items = .center });
        if (context.last_added) |crumbs| crumbs.style.wrap = true;
    }

    /// Read what is shown again when it may have changed: a second has passed, or the view,
    /// filter, grid folder or open folders changed.
    fn refresh(self: *AssetsPanel, project_dir: []const u8, now_ms: u64) void {
        const same = self.read_for.view == self.view and
            std.mem.eql(u8, self.read_for.filter.items, self.filter.text()) and
            std.mem.eql(u8, self.read_for.folder.items, self.folder.items) and
            self.read_for.expanded == self.expanded.count();
        if (same) if (self.read_at_ms) |at| if (now_ms -| at < refresh_ms) return;

        _ = self.shown_arena.reset(.retain_capacity);
        const arena = self.shown_arena.allocator();
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = std.Io.Dir.cwd().openDir(io, project_dir, .{}) catch {
            self.shown = &.{};
            return;
        };
        defer project.close(io);
        var shown: std.ArrayList(Shown) = .empty;
        if (self.filter.text().len > 0) {
            self.search(arena, io, project, &shown) catch {};
        } else if (self.view == .grid) {
            for (listing.list(arena, io, project, self.folder.items) catch &.{}) |entry| shown.append(arena, .{ .entry = entry, .depth = 0 }) catch break;
        } else self.tree(arena, io, project, "", 0, &shown) catch {};
        self.shown = shown.items;

        self.read_at_ms = now_ms;
        self.read_for.view = self.view;
        self.read_for.expanded = self.expanded.count();
        self.read_for.filter.clearRetainingCapacity();
        self.read_for.filter.appendSlice(self.gpa, self.filter.text()) catch {};
        self.read_for.folder.clearRetainingCapacity();
        self.read_for.folder.appendSlice(self.gpa, self.folder.items) catch {};
    }

    /// The list: `folder`'s entries, each open folder followed by its own.
    fn tree(self: *const AssetsPanel, arena: std.mem.Allocator, io: std.Io, project: std.Io.Dir, folder: []const u8, depth: usize, out: *std.ArrayList(Shown)) !void {
        for (try listing.list(arena, io, project, folder)) |entry| {
            const open = entry.kind == .folder and self.expanded.contains(entry.path);
            try out.append(arena, .{ .entry = entry, .depth = depth, .open = open });
            if (open) try self.tree(arena, io, project, entry.path, depth + 1, out);
        }
    }

    /// Every entry in the project whose name contains the filter, ignoring case.
    fn search(self: *const AssetsPanel, arena: std.mem.Allocator, io: std.Io, project: std.Io.Dir, out: *std.ArrayList(Shown)) !void {
        var folders: std.ArrayList([]const u8) = .empty;
        try folders.append(arena, "");
        var searched: usize = 0;
        while (searched < folders.items.len and searched < max_searched and out.items.len < max_found) : (searched += 1) {
            for (try listing.list(arena, io, project, folders.items[searched])) |entry| {
                if (entry.kind == .folder) try folders.append(arena, entry.path);
                if (std.ascii.indexOfIgnoreCase(entry.name, self.filter.text()) != null) try out.append(arena, .{ .entry = entry, .depth = 0 });
            }
        }
    }

    fn select(self: *AssetsPanel, path: []const u8) void {
        self.selected.clearRetainingCapacity();
        self.selected.appendSlice(self.gpa, path) catch {};
    }

    fn isSelected(self: *const AssetsPanel, path: []const u8) bool {
        return std.mem.eql(u8, self.selected.items, path);
    }

    /// Open or close folder `path` in the list.
    fn toggle(self: *AssetsPanel, path: []const u8) void {
        if (self.expanded.fetchRemove(path)) |removed| return self.gpa.free(removed.key);
        const key = self.gpa.dupe(u8, path) catch return;
        self.expanded.put(self.gpa, key, {}) catch self.gpa.free(key);
    }

    /// Show folder `path` in the grid.
    fn enter(self: *AssetsPanel, path: []const u8) void {
        const copy = self.gpa.dupe(u8, path) catch return;
        defer self.gpa.free(copy);
        self.folder.clearRetainingCapacity();
        self.folder.appendSlice(self.gpa, copy) catch {};
    }

    /// The entry under `at` in last frame's layout.
    fn itemAt(self: *const AssetsPanel, context: *const ui.Context, at: ui.Vec2) ?Shown {
        for (self.shown, 0..) |item, i| {
            const target = context.last_bounds.get(item_id_base + @as(u32, @intCast(i))) orelse continue;
            if (target.rect.contains(at.x, at.y)) return item;
        }
        return null;
    }
};

/// A row's or tile's background: lit when selected, lighter under the pointer.
fn highlight(arena: std.mem.Allocator, id: u32, selected: bool) L.Paint {
    const look = arena.create(Highlight) catch return .none;
    look.* = .{ .id = id, .selected = selected };
    return .{ .custom = .{ .context = look, .draw = Highlight.draw } };
}

const Highlight = struct {
    id: u32,
    selected: bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Highlight = @ptrCast(@alignCast(context));
        if (self.selected) {
            try c.roundRect(r, c.theme.accent, c.theme.radiusSm());
        } else if (c.hot_id == self.id) try c.roundRectAlpha(r, c.theme.accent, c.theme.radiusSm(), 0.5);
    }
};

const ui_checks = @import("../ui_checks.zig");

test "the panel fits a narrow dock, as a list and as a grid" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "scenes/a folder with a long name that goes on and on");
    try tmp.dir.writeFile(io, .{ .sub_path = "scenes/main.scene.zon", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a_file_with_a_very_long_name_indeed_and_more_of_it.zig", .data = "" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);

    var context = try ui.Context.init(gpa);
    defer context.deinit();
    var icons = Icons.load(gpa, context.font);
    defer icons.deinit(gpa);
    var panel = AssetsPanel.init(gpa);
    defer panel.deinit();
    panel.toggle("scenes");
    for ([_]View{ .list, .grid }) |view| for ([_]f32{ 200, 340, 800 }) |width| {
        panel.view = view;
        panel.read_at_ms = null;
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = width, .h = 600 };
        context.newFrame(viewport);
        _ = panel.build(&context, dir, &icons, "scenes/main.scene.zon");
        _ = try context.render();
        try ui_checks.expectFits(context.last_root.?, context.font, viewport);
    };
    // The list showed the open folder's contents under it.
    panel.view = .list;
    panel.read_at_ms = null;
    panel.refresh(dir, 0);
    try std.testing.expectEqualStrings("scenes/main.scene.zon", panel.shown[2].entry.path);
    try std.testing.expectEqual(@as(usize, 1), panel.shown[2].depth);
}
