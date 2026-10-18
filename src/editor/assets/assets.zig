//! The Assets panel: the project's files, to find, open and manage them. As a list it is a tree
//! of the whole project, folders opening in place; as a grid it is one folder's tiles, with a
//! path to climb back up. A filter searches every folder by name. A scene (`.scene.zon`) opens
//! with a double-click, a code or text file opens in the code editor chosen in Preferences, and
//! any other file shows in the system's file manager. A right-click opens a menu (open, rename,
//! duplicate, delete, copy path, show in the file manager, and new folders and scenes); F2
//! renames and Delete deletes the selected entry.
//!
//! Dragging an entry works as in the Hierarchy: onto a folder it moves there (the editor copies
//! it instead with Ctrl held), and onto the zone below the files it moves up, to the project (or
//! in the grid, to the shown folder's parent). The target is outlined, the entry dims, and a chip
//! with its name, or why letting go won't move it, follows the pointer; Escape cancels. Onto a
//! reference field in the Inspector it sets the field.
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
const creation = @import("creation.zig");

/// What the user asked for. Paths are relative to the project, with `/` between parts.
pub const Action = union(enum) {
    /// Open this scene, replacing the world.
    open_scene: []const u8,
    /// Start a new, empty scene in this folder ("" for the project) and open it.
    create_scene: []const u8,
    /// Make a new folder in this folder.
    create_folder: []const u8,
    create_file: struct { folder: []const u8, file_type: eggy.plugins.EditorFileType },
    open_input_map: []const u8,
    rename: struct { path: []const u8, name: []const u8 },
    duplicate: []const u8,
    /// Move this into the project's trash.
    delete: []const u8,
    /// Put this path on the clipboard.
    copy_path: []const u8,
    /// Show this file or folder in the system's file manager.
    reveal: []const u8,
    /// Open this code or text file in the code editor people chose.
    open_code: []const u8,
    /// Move (or copy) `path` into `folder` ("" for the project).
    move_into: struct { path: []const u8, folder: []const u8 },
};

/// What an event routed to the panel did: whether the panel used it, and the action it led to.
pub const Handled = struct { used: bool, action: ?Action = null };

const MenuItem = enum(u32) { open, rename, duplicate, delete, copy_path, reveal, new_files };
const menu_id_base: u32 = item_id_base - 32;
const creation_id_base: u32 = 0x6E00_0000;
const menu_root_id: u32 = menu_id_base - 8;
const new_root_id: u32 = menu_id_base - 9;
/// The List and Grid buttons' ids: `view_id_base` plus the view.
const view_id_base: u32 = menu_id_base - 4;
/// The zone below the files a drag moves up into.
const up_zone_id: u32 = view_id_base - 1;
const NameEdit = ui.TextEdit(128);

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
/// How far a press moves before it is a drag.
const drag_threshold: f32 = 5;

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
    /// Borrowed only while building the page; metadata is owned by the loaded game.
    file_types: []const eggy.plugins.EditorFileType = &.{},
    menu_scroll: L.ScrollState = .{},
    new_menu_scroll: L.ScrollState = .{},
    /// The right-click menu: where, and for which entry (none: the folder shown).
    menu: ?struct { at: ui.Vec2, entry: ?listing.Entry, new_only: bool = false, new_open: bool = false } = null,
    /// Owns the menu's entry's text.
    menu_arena: std.heap.ArenaAllocator,
    /// The entry being renamed, and its new name as typed.
    renaming: ?struct { path: []u8, edit: NameEdit, started: bool = false, field_id: u32 = 0 } = null,
    /// A press on an entry, which becomes a drag once it moves: the entry's path (owned), and
    /// where it would go if let go now.
    drag: ?struct { path: []u8, from: ui.Vec2, moving: bool = false, target: Target = .none } = null,
    /// What the listing was read for, to tell when to read it again.
    read_for: struct { view: View = .list, filter: std.ArrayList(u8) = .empty, folder: std.ArrayList(u8) = .empty, expanded: usize = 0 } = .{},

    /// Create editor-only panel state; `gpa` backs later listings, menus and interactions.
    /// No project is opened yet. Pair with `deinit`.
    ///
    /// ```zig
    /// var panel = AssetsPanel.init(gpa); // Existing allocator.
    /// defer panel.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator) AssetsPanel {
        return .{ .gpa = gpa, .shown_arena = .init(gpa), .menu_arena = .init(gpa) };
    }

    /// Release panel-owned paths, interaction state and arenas; invalidate borrowed results.
    /// Call once after the editor stops building or routing events to this panel.
    ///
    /// ```zig
    /// var panel = AssetsPanel.init(gpa); // Existing allocator.
    /// defer panel.deinit();
    /// ```
    pub fn deinit(self: *AssetsPanel) void {
        self.folder.deinit(self.gpa);
        self.selected.deinit(self.gpa);
        var keys = self.expanded.keyIterator();
        while (keys.next()) |path| self.gpa.free(path.*);
        self.expanded.deinit(self.gpa);
        self.read_for.filter.deinit(self.gpa);
        self.read_for.folder.deinit(self.gpa);
        self.shown_arena.deinit();
        self.menu_arena.deinit();
        if (self.renaming) |renaming| self.gpa.free(renaming.path);
        if (self.drag) |drag| self.gpa.free(drag.path);
    }

    /// The entry being dragged, while it is; its path, relative to the project.
    /// The slice borrows active drag state and expires when that drag ends.
    ///
    /// ```zig
    /// // Given an editor AssetsPanel:
    /// if (panel.dragged()) |path| std.log.info("Dragging {s}", .{path});
    /// ```
    pub fn dragged(self: *const AssetsPanel) ?[]const u8 {
        const drag = self.drag orelse return null;
        return if (drag.moving) drag.path else null;
    }

    /// The folder files dropped from outside at `at` go into: a folder hit, a hit file's parent,
    /// otherwise the grid's folder or the project ("").
    /// Use coordinates in the UI context's space and its latest layout; copy the returned
    /// borrowed path before rebuilding the listing or changing folders.
    ///
    /// ```zig
    /// // Given panel, UI context and a file-drop position in UI coordinates:
    /// const folder = panel.importFolder(context, at);
    /// ```
    pub fn importFolder(self: *const AssetsPanel, context: *const ui.Context, at: ui.Vec2) []const u8 {
        if (self.itemAt(context, at)) |item| return if (item.entry.kind == .folder) item.entry.path else listing.parentOf(item.entry.path);
        return if (self.view == .grid) self.folder.items else "";
    }

    /// The chip that follows the pointer while dragging: the entry's name, or why letting go
    /// here won't move it. Null while nothing is dragged.
    /// Borrowed text remains valid only while the drag state is unchanged.
    ///
    /// ```zig
    /// // Given panel and a UI context during the editor overlay build:
    /// if (panel.dragLabel()) |label| context.text(label);
    /// ```
    pub fn dragLabel(self: *const AssetsPanel) ?[]const u8 {
        const drag = self.drag orelse return null;
        if (!drag.moving) return null;
        return switch (drag.target) {
            .inside_itself => "Can't go inside itself",
            .already_there => "Already in this folder",
            .none, .folder => std.fs.path.basename(drag.path),
        };
    }

    /// Where a drag of `path` would go with the pointer at `at`: the folder there, or the zone's
    /// folder, unless that is `path` itself, inside it, or where it already is.
    fn targetAt(self: *const AssetsPanel, context: *const ui.Context, at: ui.Vec2, path: []const u8) Target {
        const over_zone = if (context.last_bounds.get(up_zone_id)) |zone| zone.rect.contains(at.x, at.y) else false;
        const folder = if (over_zone) self.upFolder() else blk: {
            const item = self.itemAt(context, at) orelse return .none;
            if (item.entry.kind != .folder) return .none;
            break :blk item.entry.path;
        };
        if (std.mem.eql(u8, folder, path)) return .none;
        if (std.mem.startsWith(u8, folder, path) and folder.len > path.len and folder[path.len] == '/') return .inside_itself;
        if (std.mem.eql(u8, folder, listing.parentOf(path))) return .already_there;
        return .{ .folder = folder };
    }

    /// The folder the zone below the files moves a drag up into: the grid's parent folder, else
    /// the project.
    fn upFolder(self: *const AssetsPanel) []const u8 {
        return if (self.view == .grid and self.filter.text().len == 0) listing.parentOf(self.folder.items) else "";
    }

    fn endDrag(self: *AssetsPanel) void {
        if (self.drag) |drag| self.gpa.free(drag.path);
        self.drag = null;
    }

    /// Read the listing again on the next build, as the files just changed.
    /// Editor-only: invalidates the refresh timestamp without doing I/O immediately.
    ///
    /// ```zig
    /// panel.refreshSoon(); // Existing AssetsPanel after a file operation.
    /// ```
    pub fn refreshSoon(self: *AssetsPanel) void {
        self.read_at_ms = null;
    }

    /// Rename the selected entry (F2): its row becomes a text field.
    /// Editor-only: no selection is a no-op; allocation failure leaves no rename active.
    ///
    /// ```zig
    /// panel.renameSelected(); // Existing AssetsPanel with keyboard focus.
    /// ```
    pub fn renameSelected(self: *AssetsPanel) void {
        if (self.selected.items.len == 0) return;
        self.startRename(self.selected.items);
    }

    /// A key while the panel has the keyboard: Enter keeps a rename, Escape drops it (or closes
    /// the menu), Delete deletes the selected entry. Returns whether it was used, and the action.
    /// Editor-only: this does not perform file operations. Consume or copy action paths before
    /// another build/interaction mutates panel storage.
    ///
    /// ```zig
    /// // Given a focused panel:
    /// const result = panel.key(.{ .key = .escape, .modifiers = .{}, .repeat = false });
    /// if (result.used) return;
    /// ```
    pub fn key(self: *AssetsPanel, key_down: @FieldType(ui.input.Event, "key_down")) Handled {
        switch (key_down.key) {
            .enter => if (self.renaming != null) return .{ .used = true, .action = self.finishRename() },
            .escape => {
                const any = self.menu != null or self.renaming != null or self.drag != null;
                self.menu = null;
                self.cancelRename();
                self.endDrag();
                return .{ .used = any };
            },
            .delete => if (self.renaming == null and self.selected.items.len > 0) return .{ .used = true, .action = .{ .delete = self.selected.items } },
            else => {},
        }
        return .{ .used = false };
    }

    fn startRename(self: *AssetsPanel, path: []const u8) void {
        self.cancelRename();
        const owned = self.gpa.dupe(u8, path) catch return;
        self.renaming = .{ .path = owned, .edit = NameEdit.init(std.fs.path.basename(path)) catch NameEdit.init("") catch unreachable };
        self.menu = null;
    }

    fn cancelRename(self: *AssetsPanel) void {
        if (self.renaming) |renaming| self.gpa.free(renaming.path);
        self.renaming = null;
    }

    /// End the rename, asking for it if the name changed. The action's text lives until the
    /// next build.
    fn finishRename(self: *AssetsPanel) ?Action {
        const renaming = self.renaming orelse return null;
        self.renaming = null;
        defer self.gpa.free(renaming.path);
        const name = std.mem.trim(u8, renaming.edit.text(), " ");
        if (name.len == 0 or std.mem.eql(u8, name, std.fs.path.basename(renaming.path))) return null;
        _ = self.menu_arena.reset(.retain_capacity);
        const arena = self.menu_arena.allocator();
        return .{ .rename = .{ .path = arena.dupe(u8, renaming.path) catch return null, .name = arena.dupe(u8, name) catch return null } };
    }

    /// Draw the panel for the project in `project_dir` (none: nothing to show) into `context`,
    /// marking `open_scene` (relative to it). Returns what the user did this frame, if anything.
    /// Editor-only: call during the UI build with live icons and game file-type metadata.
    /// Returned paths borrow panel/frame storage; handle the action before the next build.
    ///
    /// ```zig
    /// // Given panel, context, optional project/scene paths and loaded icons:
    /// const action = panel.build(context, project_dir, &icons, open_scene);
    /// _ = action; // Dispatch any requested file operation in the editor host.
    /// ```
    pub fn build(self: *AssetsPanel, context: *ui.Context, project_dir: ?[]const u8, icons: *const Icons, open_scene: ?[]const u8) ?Action {
        const dir = project_dir orelse {
            context.muted("Open a project to see its files.");
            page_style.smallText(context, 13);
            return null;
        };
        var action: ?Action = null;

        // One line: the filter, list/grid controls and the shared New dropdown.
        context.begin(.row);
        _ = context.textInput("##asset filter", &self.filter, "Find files");
        page_style.restyle(context, .{ .grow = 1 });
        for ([_]View{ .list, .grid }) |view| self.viewButton(context, icons, view);
        if (context.buttonVariant("New", .outline)) self.menu = .{ .at = context.pointer, .entry = null, .new_only = true };
        context.end();
        page_style.restyle(context, .{ .direction = .row, .gap = 4, .align_items = .center });

        self.refresh(dir, context.time_ms);
        // Where a drag would go, again: its folder points into the listing just read.
        if (self.drag) |*drag| if (drag.moving) {
            drag.target = self.targetAt(context, context.pointer, drag.path);
        };
        const searching = self.filter.text().len > 0;
        if (self.view == .grid and !searching) self.breadcrumbs(context);

        if (self.shown.len == 0) {
            context.muted(if (searching) "No file matches." else "This folder is empty.");
            page_style.smallText(context, 13);
            return self.menuElement(context) orelse action;
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
            page_style.passThrough(context);
        }
        self.upZone(context);

        // A press picks an entry; in the list, a folder opens or closes too.
        for (self.shown, 0..) |item, i| if (context.activated(item_id_base + @as(u32, @intCast(i)))) {
            self.select(item.entry.path);
            if (self.view == .list and !searching and item.entry.kind == .folder) self.toggle(item.entry.path);
        };
        if (self.menuElement(context)) |menu_action| action = menu_action;
        return action;
    }

    /// Route a pointer event over the panel before its UI sees it: a double-click opens the
    /// entry under it (a scene opens, a folder opens in the grid, anything else shows in the
    /// file manager). `context` has last frame's layout.
    /// Editor-only: updates selection/drag/menu state but delegates filesystem work through
    /// `action`. Consume borrowed action paths before rebuilding or changing interaction state.
    ///
    /// ```zig
    /// // Given panel, its last-layout context and a UI input event:
    /// const result = panel.pointer(context, event);
    /// _ = result; // Dispatch action, then forward to ordinary UI only if not used.
    /// ```
    pub fn pointer(self: *AssetsPanel, context: *const ui.Context, event: ui.input.Event) Handled {
        const down = switch (event) {
            .pointer_down => |down| down,
            // A press that moves far enough becomes a drag; letting go over a folder moves it in.
            .pointer_move => |at| {
                const drag = if (self.drag) |*drag| drag else return .{ .used = false };
                if (!drag.moving and @abs(at.x - drag.from.x) + @abs(at.y - drag.from.y) > drag_threshold) drag.moving = true;
                if (!drag.moving) return .{ .used = false };
                drag.target = self.targetAt(context, at, drag.path);
                return .{ .used = true };
            },
            .pointer_up => |up| {
                const drag = self.drag orelse return .{ .used = false };
                defer self.endDrag();
                if (!drag.moving or up.button != .left) return .{ .used = false };
                const folder = switch (self.targetAt(context, up.position, drag.path)) {
                    .folder => |folder| folder,
                    .none, .inside_itself, .already_there => return .{ .used = true },
                };
                // The action's text must outlive the drag: keep it with the menu's.
                const arena = self.menu_arena.allocator();
                return .{ .used = true, .action = .{ .move_into = .{ .path = arena.dupe(u8, drag.path) catch return .{ .used = true }, .folder = arena.dupe(u8, folder) catch return .{ .used = true } } } };
            },
            else => return .{ .used = false },
        };
        // A press outside the menu closes it, and one outside the rename keeps the name.
        if (self.menu != null) {
            if (self.onMenu(context, down.position)) return .{ .used = false };
            self.menu = null;
        }
        if (self.renaming) |renaming| {
            const on_field = if (context.last_bounds.get(renaming.field_id)) |field| field.rect.contains(down.position.x, down.position.y) else false;
            if (!on_field) return .{ .used = false, .action = self.finishRename() };
        }
        if (down.button == .right) {
            _ = self.menu_arena.reset(.retain_capacity);
            const item = self.itemAt(context, down.position);
            var entry: ?listing.Entry = null;
            if (item) |found| {
                self.select(found.entry.path);
                const arena = self.menu_arena.allocator();
                entry = .{ .path = arena.dupe(u8, found.entry.path) catch return .{ .used = true }, .name = "", .kind = found.entry.kind };
            }
            self.menu = .{ .at = down.position, .entry = entry };
            return .{ .used = true };
        }
        if (down.button == .left and down.clicks < 2) if (self.itemAt(context, down.position)) |pressed| {
            self.endDrag();
            if (self.gpa.dupe(u8, pressed.entry.path)) |path| {
                self.drag = .{ .path = path, .from = down.position };
            } else |_| {}
        };
        if (down.button != .left or down.clicks < 2) return .{ .used = false };
        self.endDrag();
        const item = self.itemAt(context, down.position) orelse return .{ .used = false };
        const entry = item.entry;
        return switch (entry.kind) {
            .scene => .{ .used = true, .action = .{ .open_scene = entry.path } },
            .input_map => .{ .used = true, .action = .{ .open_input_map = entry.path } },
            .folder => blk: {
                if (self.view == .grid and self.filter.text().len == 0) {
                    self.enter(entry.path);
                    break :blk .{ .used = true };
                }
                break :blk .{ .used = false }; // the list opens folders with one press
            },
            .code, .text => .{ .used = true, .action = .{ .open_code = entry.path } },
            else => .{ .used = true, .action = .{ .reveal = entry.path } },
        };
    }

    /// One row of the list: indented by depth, a folder's chevron, its icon and name.
    fn row(self: *AssetsPanel, context: *ui.Context, icons: *const Icons, item: Shown, index: usize, open_scene: ?[]const u8, searching: bool) void {
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
        if (self.renamingThis(item.entry.path)) return self.renameField(context, icons.paint(icon, context.theme), left + 4 + 12 + 6);
        const children = [_]*L.Element{
            chevron,
            b.node(0, .{ .width = 16, .height = 16 }, icons.paint(icon, context.theme), &.{}) catch return,
            b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = name, .size = 12, .tone = if (self.isDragged(item.entry.path)) .muted else .foreground } }, &.{}) catch return,
            b.node(0, .{}, .{ .text = .{ .value = note_text, .size = 11, .tone = .muted } }, &.{}) catch return,
        };
        const element = b.node(id, .{ .height = row_height, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = left + 4, .right = 6 } }, highlight(arena, id, self.isSelected(item.entry.path), self.isDropInto(item.entry.path)), &children) catch return;
        element.cursor = .pointer;
        element.accessibility = .{ .role = .menu_item, .label = item.entry.name };
        context.element(element);
    }

    /// The button that shows the files as `view` (a list or a grid), lit while they are.
    fn viewButton(self: *AssetsPanel, context: *ui.Context, icons: *const Icons, view: View) void {
        const b = context.builder();
        const id = view_id_base + @intFromEnum(view);
        if (context.activated(id)) self.view = view;
        const icon: Icon = if (view == .list) .list else .grid;
        const element = b.node(id, .{ .width = 24, .height = 24, .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 } }, highlight(b.allocator, id, self.view == view, false), &.{
            b.node(0, .{ .width = 16, .height = 16 }, icons.paint(icon, context.theme), &.{}) catch return,
        }) catch return;
        element.cursor = .pointer;
        element.accessibility = .{ .role = .button, .label = if (view == .list) "List" else "Grid" };
        context.element(element);
    }

    /// One tile of the grid: the icon above the name.
    fn tile(self: *AssetsPanel, context: *ui.Context, icons: *const Icons, item: Shown, index: usize, open_scene: ?[]const u8) void {
        const b = context.builder();
        const arena = b.allocator;
        const id = item_id_base + @as(u32, @intCast(index));
        const is_open = if (open_scene) |path| std.mem.eql(u8, path, item.entry.path) else false;
        // Renamed in a field of its own: a tile is too narrow to type in.
        if (self.renamingThis(item.entry.path)) return self.renameField(context, icons.paint(Icon.of(item.entry.kind), context.theme), 0);
        const name = page_style.fitText(arena, context.font, item.entry.name, 11, tile_width - 12);
        const element = b.node(id, .{ .width = tile_width, .height = tile_height, .align_items = .center, .gap = 6, .padding = .{ .top = 10, .left = 6, .right = 6 } }, highlight(arena, id, self.isSelected(item.entry.path) or is_open, self.isDropInto(item.entry.path)), &.{
            b.node(0, .{ .width = 40, .height = 40 }, icons.paint(Icon.of(item.entry.kind), context.theme), &.{}) catch return,
            b.node(0, .{}, .{ .text = .{ .value = name, .size = 11, .alignment = .center, .tone = if (self.isDragged(item.entry.path)) .muted else .foreground } }, &.{}) catch return,
        }) catch return;
        element.cursor = .pointer;
        element.accessibility = .{ .role = .button, .label = item.entry.name };
        context.element(element);
    }

    fn renamingThis(self: *const AssetsPanel, path: []const u8) bool {
        const renaming = self.renaming orelse return false;
        return std.mem.eql(u8, renaming.path, path);
    }

    /// The field an entry is renamed in: its icon, then the name being typed, `left` in.
    fn renameField(self: *AssetsPanel, context: *ui.Context, icon: L.Paint, left: f32) void {
        const renaming = &(self.renaming orelse return);
        context.begin(.row);
        context.element(context.builder().node(0, .{ .width = 16, .height = 16 }, icon, &.{}) catch return);
        _ = context.textInput("##rename asset", &renaming.edit, "Name");
        const field = context.last_added;
        // Only as wide as the name, so a press beside it lands on the panel, not the field.
        page_style.fitFieldToText(context, renaming.edit.text(), context.contentWidth() - left - 16 - 6);
        context.end();
        page_style.restyle(context, .{ .direction = .row, .gap = 6, .align_items = .center, .padding = .{ .left = left } });
        // Focus the field the first frame, so typing goes straight in.
        if (field) |input| {
            renaming.field_id = input.id;
            if (!renaming.started) {
                context.focus = input.id;
                renaming.started = true;
            }
        }
    }

    /// The right-click menu, if open, and what was picked from it.
    fn menuElement(self: *AssetsPanel, context: *ui.Context) ?Action {
        const menu = self.menu orelse return null;
        const arena = context.builder().allocator;
        var choices: std.ArrayList(ui.widgets.MenuItem) = .empty;
        const add = struct {
            fn f(list: *std.ArrayList(ui.widgets.MenuItem), ui_context: *ui.Context, item: MenuItem, label: []const u8) void {
                list.append(ui_context.builder().allocator, .{ .id = menu_id_base + @intFromEnum(item), .label = label }) catch |err| {
                    ui_context.err = err;
                };
            }
        }.f;
        const new_items = newMenuItems(context, self.file_types) catch |err| {
            context.err = err;
            return null;
        };
        if (menu.new_only) return self.newMenu(context, new_items, menu.at, self.newFilesFolder());
        if (menu.entry) |entry| {
            if (entry.kind == .scene or entry.kind == .input_map or entry.kind == .code or entry.kind == .text) add(&choices, context, .open, "Open");
            add(&choices, context, .rename, "Rename");
            add(&choices, context, .duplicate, "Duplicate");
            add(&choices, context, .delete, "Delete");
            add(&choices, context, .copy_path, "Copy path");
            add(&choices, context, .reveal, "Show in file manager");
        } else add(&choices, context, .reveal, "Show in file manager");
        choices.append(arena, .{ .id = menu_id_base + @intFromEnum(MenuItem.new_files), .label = "New", .kind = .submenu }) catch |err| {
            context.err = err;
            return null;
        };

        // Kept inside the page: it opens left of or above the pointer near an edge.
        const width: f32 = @min(200, context.viewport.w);
        const height = 8 + 33 * @as(f32, @floatFromInt(choices.items.len));
        const at = ui.Vec2{
            .x = @max(context.viewport.x, @min(menu.at.x, context.viewport.x + context.viewport.w - width)),
            .y = @max(context.viewport.y, @min(menu.at.y, context.viewport.y + context.viewport.h - height)),
        };
        const popup = ui.widgets.menuItems(context.builder(), choices.items, 0, 0) catch |err| {
            context.err = err;
            return null;
        };
        popup.id = menu_root_id;
        popup.style.width = width;
        popup.style.height = @min(height, context.viewport.h);
        popup.style.overflow = .scroll;
        popup.scroll = &self.menu_scroll;
        self.menu_scroll.overlay_bar = true;
        popup.style.z_index = 200;
        popup.overlay = .{ .point = at };
        context.element(popup);

        for (choices.items) |choice| if (context.activated(choice.id)) {
            if (choice.id == menu_id_base + @intFromEnum(MenuItem.new_files)) {
                self.menu.?.new_open = true;
                break;
            }
            self.menu = null;
            return switch (@as(MenuItem, @enumFromInt(choice.id - menu_id_base))) {
                .open => switch (menu.entry.?.kind) {
                    .scene => .{ .open_scene = menu.entry.?.path },
                    .input_map => .{ .open_input_map = menu.entry.?.path },
                    else => .{ .open_code = menu.entry.?.path },
                },
                .rename => blk: {
                    self.startRename(menu.entry.?.path);
                    break :blk null;
                },
                .duplicate => .{ .duplicate = menu.entry.?.path },
                .delete => .{ .delete = menu.entry.?.path },
                .copy_path => .{ .copy_path = menu.entry.?.path },
                .reveal => .{ .reveal = if (menu.entry) |entry| entry.path else self.folder.items },
                .new_files => unreachable,
            };
        };
        const new_id = menu_id_base + @intFromEnum(MenuItem.new_files);
        const new_row = if (context.last_bounds.get(new_id)) |bound| bound.rect else ui.Rect{ .x = at.x, .y = at.y + height - 37, .w = width, .h = 32 };
        if (new_row.contains(context.pointer.x, context.pointer.y)) self.menu.?.new_open = true;
        if (self.menu.?.new_open) {
            for (popup.children) |child| if (child.id == new_id) {
                child.accessibility.expanded = true;
            };
            const right = context.viewport.x + context.viewport.w;
            const x = if (at.x + width * 2 <= right) at.x + width else if (at.x - width >= context.viewport.x) at.x - width else at.x;
            const folder = if (menu.entry) |entry| (if (entry.kind == .folder) entry.path else listing.parentOf(entry.path)) else self.newFilesFolder();
            return self.newMenu(context, new_items, .{ .x = x, .y = new_row.y }, folder);
        }
        return null;
    }

    fn newMenu(self: *AssetsPanel, context: *ui.Context, items: []const ui.widgets.MenuItem, at: ui.Vec2, folder: []const u8) ?Action {
        const popup = ui.widgets.menuItems(context.builder(), items, 0, 0) catch |err| {
            context.err = err;
            return null;
        };
        // A long list (many plugins' templates) scrolls rather than running off the page.
        const width = @min(200, context.viewport.w);
        var content_height: f32 = 8;
        for (items) |item| content_height += switch (item.kind) {
            .separator => 9,
            .label => 28,
            else => 32,
        };
        const height = @min(content_height, new_menu_max_height, context.viewport.h);
        popup.id = new_root_id;
        popup.style.width = width;
        popup.style.height = height;
        popup.style.overflow = .scroll;
        popup.scroll = &self.new_menu_scroll;
        self.new_menu_scroll.overlay_bar = true;
        popup.style.z_index = 210;
        popup.overlay = .{ .point = .{
            .x = @max(context.viewport.x, @min(at.x, context.viewport.x + context.viewport.w - width)),
            .y = @max(context.viewport.y, @min(at.y, context.viewport.y + context.viewport.h - height)),
        } };
        context.element(popup);
        for (items) |item| if (item.kind == .item and context.activated(item.id)) {
            self.menu = null;
            return switch (creation.at(item.id - creation_id_base, self.file_types).?) {
                .scene => .{ .create_scene = folder },
                .folder => .{ .create_folder = folder },
                .file => |file_type| .{ .create_file = .{ .folder = folder, .file_type = file_type } },
            };
        };
        return null;
    }

    /// The folder new files go into: the grid's, or in the list the selected folder (or the
    /// selected file's), else `scenes`.
    fn newFilesFolder(self: *const AssetsPanel) []const u8 {
        if (self.view == .grid) return self.folder.items;
        for (self.shown) |item| if (self.isSelected(item.entry.path)) {
            return if (item.entry.kind == .folder) item.entry.path else listing.parentOf(item.entry.path);
        };
        return eggy.project.scenes_dir;
    }

    fn onMenu(self: *const AssetsPanel, context: *const ui.Context, at: ui.Vec2) bool {
        _ = self;
        for ([_]u32{ menu_root_id, new_root_id }) |id| {
            if (context.last_bounds.get(id)) |target| if (target.rect.contains(at.x, at.y)) return true;
        }
        return false;
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
        const owned = self.gpa.dupe(u8, path) catch return;
        self.expanded.put(self.gpa, owned, {}) catch self.gpa.free(owned);
    }

    /// Show folder `path` in the grid.
    fn enter(self: *AssetsPanel, path: []const u8) void {
        const copy = self.gpa.dupe(u8, path) catch return;
        defer self.gpa.free(copy);
        self.folder.clearRetainingCapacity();
        self.folder.appendSlice(self.gpa, copy) catch {};
    }

    /// Whether a drag would drop into folder `path` if let go now.
    fn isDropInto(self: *const AssetsPanel, path: []const u8) bool {
        const drag = self.drag orelse return false;
        if (!drag.moving or drag.target != .folder) return false;
        return std.mem.eql(u8, drag.target.folder, path);
    }

    fn isDragged(self: *const AssetsPanel, path: []const u8) bool {
        const dragged_path = self.dragged() orelse return false;
        return std.mem.eql(u8, dragged_path, path);
    }

    /// While dragging, the zone below the files that moves the entry up (see `upFolder`), lit
    /// while it would.
    fn upZone(self: *const AssetsPanel, context: *ui.Context) void {
        const drag = self.drag orelse return;
        if (!drag.moving) return;
        const up = self.upFolder();
        if (std.mem.eql(u8, listing.parentOf(drag.path), up)) return;
        const b = context.builder();
        const over = drag.target == .folder and std.mem.eql(u8, drag.target.folder, up);
        const label = if (up.len == 0) "Drop here to move to the project" else std.fmt.allocPrint(b.allocator, "Drop here to move up to {s}", .{std.fs.path.basename(up)}) catch return;
        const zone = b.node(up_zone_id, .{ .height = 32, .padding = .{ .left = 10, .right = 10 }, .align_items = .center, .direction = .row }, .{ .surface = if (over) .card else .track }, &.{
            b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = label, .size = 11, .tone = if (over) .foreground else .muted, .wrap = true } }, &.{}) catch return,
        }) catch return;
        context.element(zone);
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

/// Where a drag would go if let go now: into a folder, or nowhere and why.
const Target = union(enum) {
    none,
    folder: []const u8,
    inside_itself,
    already_there,
};

/// A row's or tile's background: lit when selected, lighter under the pointer, outlined as a
/// drag's target (as the Hierarchy's rows are).
fn highlight(arena: std.mem.Allocator, id: u32, selected: bool, drop_into: bool) L.Paint {
    const look = arena.create(Highlight) catch return .none;
    look.* = .{ .id = id, .selected = selected, .drop_into = drop_into };
    return .{ .custom = .{ .context = look, .draw = Highlight.draw } };
}

const Highlight = struct {
    id: u32,
    selected: bool,
    drop_into: bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Highlight = @ptrCast(@alignCast(context));
        if (self.selected) {
            try c.roundRect(r, c.theme.accent, c.theme.radiusSm());
        } else if (c.hot_id == self.id) try c.roundRectAlpha(r, c.theme.accent, c.theme.radiusSm(), 0.5);
        if (self.drop_into) try c.roundRectStroke(r, c.theme.primary, c.theme.radiusSm(), 1.5);
    }
};

const ui_checks = @import("../ui_checks.zig");

/// The tallest the New menu grows before it scrolls: about ten rows.
const new_menu_max_height: f32 = 330;

/// The New menu's rows: Eggy's own, then each plugin's templates under its name. Items' ids are
/// `creation_id_base` plus their place in `creation`'s catalog. In the frame's arena, as last
/// frame's hit-test tree must survive a game-library swap.
fn newMenuItems(context: *ui.Context, file_types: []const eggy.plugins.EditorFileType) ![]ui.widgets.MenuItem {
    const arena = context.builder().allocator;
    var items: std.ArrayList(ui.widgets.MenuItem) = .empty;
    var owner: ?[]const u8 = null;
    for (0..creation.count(file_types)) |i| {
        const entry = creation.at(i, file_types).?;
        if (i >= creation.builtin_count) {
            const from = creation.ownerOf(entry.file);
            if (owner == null or !std.mem.eql(u8, owner.?, from)) {
                if (owner == null) try items.append(arena, .{ .kind = .separator });
                try items.append(arena, .{ .kind = .label, .label = try displayName(arena, from) });
                owner = from;
            }
        }
        const label = page_style.fitText(arena, context.font, entry.label(), 14, @max(0, @min(200, context.viewport.w) - 40));
        try items.append(arena, .{ .id = creation_id_base + @as(u32, @intCast(i)), .label = try arena.dupe(u8, label) });
    }
    return items.items;
}

/// A plugin key as a heading: `my_physics` as "My physics", the game's as "Game".
fn displayName(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    const name = try arena.dupe(u8, key);
    for (name) |*c| if (c.* == '_' or c.* == '-') {
        c.* = ' ';
    };
    if (name.len > 0) name[0] = std.ascii.toUpper(name[0]);
    return name;
}

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
    // The menu and a rename stay inside a narrow panel too.
    panel.view = .list;
    panel.menu = .{ .at = .{ .x = 190, .y = 590 }, .entry = .{ .path = "scenes/main.scene.zon", .name = "", .kind = .scene } };
    panel.startRename("scenes/main.scene.zon");
    panel.menu = .{ .at = .{ .x = 190, .y = 590 }, .entry = null };
    for ([_]f32{ 200, 340 }) |width| {
        panel.read_at_ms = null;
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = width, .h = 600 };
        context.newFrame(viewport);
        _ = panel.build(&context, dir, &icons, null);
        _ = try context.render();
        try ui_checks.expectFits(context.last_root.?, context.font, viewport);
    }
    panel.cancelRename();

    // The list showed the open folder's contents under it.
    panel.view = .list;
    panel.read_at_ms = null;
    panel.refresh(dir, 0);
    try std.testing.expectEqualStrings("scenes/main.scene.zon", panel.shown[2].entry.path);
    try std.testing.expectEqual(@as(usize, 1), panel.shown[2].depth);
}

test "dragging a file onto a folder asks to move it there, but not a folder into itself" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "art");
    try tmp.dir.writeFile(io, .{ .sub_path = "ship.png", .data = "" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);

    var context = try ui.Context.init(gpa);
    defer context.deinit();
    var icons = Icons.load(gpa, context.font);
    defer icons.deinit(gpa);
    var panel = AssetsPanel.init(gpa);
    defer panel.deinit();
    context.newFrame(.{ .x = 0, .y = 0, .w = 300, .h = 400 });
    _ = panel.build(&context, dir, &icons, null);
    _ = try context.render();
    const folder = context.last_bounds.get(item_id_base + 0).?.rect.center(); // "art", folders first
    const file = context.last_bounds.get(item_id_base + 1).?.rect.center(); // "ship.png"

    _ = panel.pointer(&context, .{ .pointer_down = .{ .position = file, .button = .left, .clicks = 1 } });
    _ = panel.pointer(&context, .{ .pointer_move = folder });
    try std.testing.expectEqualStrings("ship.png", panel.dragged().?);
    try std.testing.expectEqualStrings("ship.png", panel.dragLabel().?);
    try std.testing.expect(panel.isDropInto("art"));
    const dropped = panel.pointer(&context, .{ .pointer_up = .{ .position = folder, .button = .left } });
    try std.testing.expectEqualStrings("ship.png", dropped.action.?.move_into.path);
    try std.testing.expectEqualStrings("art", dropped.action.?.move_into.folder);
    try std.testing.expect(panel.dragged() == null);

    // A folder onto itself: nothing.
    _ = panel.pointer(&context, .{ .pointer_down = .{ .position = folder, .button = .left, .clicks = 1 } });
    _ = panel.pointer(&context, .{ .pointer_move = .{ .x = folder.x, .y = folder.y + 8 } });
    try std.testing.expect(panel.pointer(&context, .{ .pointer_up = .{ .position = folder, .button = .left } }).action == null);
}

test "double-clicking a code file asks to open it in the code editor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);

    var context = try ui.Context.init(gpa);
    defer context.deinit();
    var icons = Icons.load(gpa, context.font);
    defer icons.deinit(gpa);
    var panel = AssetsPanel.init(gpa);
    defer panel.deinit();
    context.newFrame(.{ .x = 0, .y = 0, .w = 300, .h = 400 });
    _ = panel.build(&context, dir, &icons, null);
    _ = try context.render();
    const file = context.last_bounds.get(item_id_base + 0).?.rect.center();
    const opened = panel.pointer(&context, .{ .pointer_down = .{ .position = file, .button = .left, .clicks = 2 } });
    try std.testing.expectEqualStrings("main.zig", opened.action.?.open_code);
}

test "input maps open their own editor and New menus work inside empty narrow folders" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "player.inmap.zon", .data = ".{}" });
    try tmp.dir.createDirPath(io, "resources/input");
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    var icons = Icons.load(gpa, context.font);
    defer icons.deinit(gpa);
    var panel = AssetsPanel.init(gpa);
    defer panel.deinit();
    context.newFrame(.{ .x = 0, .y = 0, .w = 300, .h = 600 });
    _ = panel.build(&context, dir, &icons, null);
    _ = try context.render();
    const file = context.last_bounds.get(item_id_base + 1).?.rect.center();
    const opened = panel.pointer(&context, .{ .pointer_down = .{ .position = file, .button = .left, .clicks = 2 } });
    try std.testing.expectEqualStrings("player.inmap.zon", opened.action.?.open_input_map);
    try std.testing.expect(panel.drag == null);

    panel.view = .grid;
    panel.enter("resources/input");
    panel.file_types = &.{.{ .key = "game/material", .title = "An extraordinarily long material template title", .extension = ".material.zon", .contents = ".{}" }};
    for ([_]bool{ true, false }) |new_only| for ([_]usize{ 1, creation.count(panel.file_types) - 1 }) |creation_index| {
        panel.menu = .{ .at = .{ .x = 190, .y = 590 }, .entry = null, .new_only = new_only, .new_open = true };
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = 200, .h = 600 };
        context.newFrame(viewport);
        _ = panel.build(&context, dir, &icons, null);
        _ = try context.render();
        try ui_checks.expectFits(context.last_root.?, context.font, viewport);
        const create_at = context.last_bounds.get(creation_id_base + @as(u32, @intCast(creation_index))).?.rect.center();
        const press = ui.input.Event{ .pointer_down = .{ .position = create_at, .button = .left, .clicks = 1 } };
        try std.testing.expect(!panel.pointer(&context, press).used);
        try std.testing.expect(panel.drag == null);
        context.handle(press);
        context.handle(.{ .pointer_up = .{ .position = create_at, .button = .left } });
        context.newFrame(viewport);
        const action = panel.build(&context, dir, &icons, null).?;
        try std.testing.expectEqualStrings("resources/input", action.create_file.folder);
        try std.testing.expectEqualStrings(creation.at(creation_index, panel.file_types).?.file.extension, action.create_file.file_type.extension);
        try std.testing.expectEqualStrings(creation.at(creation_index, panel.file_types).?.file.contents, action.create_file.file_type.contents);
        _ = try context.render();
    };
}
