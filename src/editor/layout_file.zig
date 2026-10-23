//! The dock's layout (which panels go where, split how, floating or popped out, in which
//! workspace tab) kept per user in
//! Eggy's data folder as `layout.zon`: saved soon after it changes (and when the editor closes),
//! so a crash or a reload keeps it, and restored when the next editor opens, in any project.
//! The same text, kept in memory, is how Edit > Undo puts a layout back (`snapshot`, `restore`).
const std = @import("std");
const eggy = @import("eggy");
const dock = eggy.ui.dock;
const workspace_tabs = @import("workspace_tabs.zig");
const Tabs = workspace_tabs.Tabs;
const log = std.log.scoped(.layout);

const file_name = "layout.zon";
/// Bumped when what is saved changes shape, so an older file is set aside, not misread.
const version: u32 = 1;

/// What is saved of a `dock.DockSpace`: everything but what it works out each frame, and the
/// OS windows of pop-outs, which the editor opens again.
const Saved = struct {
    version: u32,
    nodes: @FieldType(dock.DockSpace, "nodes"),
    homes: @FieldType(dock.DockSpace, "homes"),
    root: @FieldType(dock.DockSpace, "root"),
    floating: @FieldType(dock.DockSpace, "floating"),
    windows: [dock.max_windows]?struct { root: u8, size: [2]f32 },
    z_counter: u32,
    /// The workspace's tabs, each a tree of `nodes`; none in a file from before tabs.
    tabs: [workspace_tabs.max_tabs]?workspace_tabs.Tab = @splat(null),
    /// Null when no tab is shown: the main window is empty.
    active_tab: ?u8 = 0,
    /// The plugin panels (by title) this user has had: one closed stays closed, rather than
    /// docking again as new.
    seen_panels: []const []const u8 = &.{},
};

/// Write `layout`, and the plugin panels `seen_panels` (titles), to the user's `layout.zon` in
/// `folder` (Eggy's data folder). Failures are logged: a layout not kept isn't worth stopping for.
/// Editor-host persistence helper; borrows inputs and frees its temporary serialization.
/// Serialization failure is ignored; directory/write failures are nonfatal.
///
/// ```zig
/// layout_file.save(gpa, user_folder, &workspace.dock, &workspace.tabs, seen_panel_titles);
/// ```
pub fn save(gpa: std.mem.Allocator, folder: []const u8, layout: *const dock.DockSpace, tabs: *const Tabs, seen_panels: []const []const u8) void {
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    serialize(layout, tabs, seen_panels, &text.writer) catch return;

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    std.Io.Dir.cwd().createDirPath(io, folder) catch {};
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{}) catch |err| return log.warn("cannot keep the layout: {t}", .{err});
    defer dir.close(io);
    dir.writeFile(io, .{ .sub_path = file_name, .data = text.written() }) catch |err| log.warn("cannot keep the layout: {t}", .{err});
}

/// A hash of what `save` would write, to tell when it changed.
/// Includes seen titles, z-order, and pop-out sizes; no allocation or filesystem access.
/// Returns zero on serialization/flush failure, not a collision-free identity.
///
/// ```zig
/// const changed = layout_file.fingerprint(&layout, &tabs, seen_titles) != previous_hash;
/// _ = changed;
/// ```
pub fn fingerprint(layout: *const dock.DockSpace, tabs: *const Tabs, seen_panels: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.Hashing(std.hash.Wyhash).initHasher(hasher, &buffer);
    serialize(layout, tabs, seen_panels, &writer.writer) catch return 0;
    writer.writer.flush() catch return 0;
    hasher = writer.hasher;
    return hasher.final();
}

fn serialize(layout: *const dock.DockSpace, tabs: *const Tabs, seen_panels: []const []const u8, writer: *std.Io.Writer) !void {
    var saved = Saved{ .version = version, .nodes = layout.nodes, .homes = layout.homes, .root = layout.root, .floating = layout.floating, .windows = undefined, .z_counter = layout.z_counter, .tabs = tabs.list, .active_tab = tabs.active, .seen_panels = seen_panels };
    for (&saved.windows, layout.windows) |*kept, window| kept.* = if (window) |open| .{ .root = open.root, .size = open.size } else null;
    try std.zon.stringify.serialize(saved, .{ .whitespace = false }, writer);
}

/// `layout` as text for `restore`, caller-owned.
/// Allocates with `gpa`; free the returned bytes with it. Omits seen plugin titles;
/// serialization/allocation errors propagate without changing the layout.
///
/// ```zig
/// const text = try layout_file.snapshot(gpa, &layout, &tabs);
/// defer gpa.free(text);
/// std.debug.assert(layout_file.restore(gpa, text, &layout, &tabs));
/// ```
pub fn snapshot(gpa: std.mem.Allocator, layout: *const dock.DockSpace, tabs: *const Tabs) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    try serialize(layout, tabs, &.{}, &text.writer);
    return text.toOwnedSlice();
}

/// A hash of where `layout`'s panels are, leaving out what changes without anyone rearranging
/// them: which floating panel is in front, pop-out windows' sizes, and which tab is shown.
/// Useful for undo coalescing; does not mutate the borrowed layout or access files.
///
/// ```zig
/// const before = layout_file.arrangement(&layout, &tabs);
/// try layout.add(3, 2, .bottom);
/// const rearranged = before != layout_file.arrangement(&layout, &tabs);
/// _ = rearranged;
/// ```
pub fn arrangement(layout: *const dock.DockSpace, tabs: *const Tabs) u64 {
    var plain = layout.*;
    plain.z_counter = 0;
    for (&plain.floating) |*floating| if (floating.*) |*shown| {
        shown.z = 0;
    };
    for (&plain.windows) |*window| if (window.*) |*open| {
        open.size = .{ 0, 0 };
    };
    // Nor which tab is shown: switching tabs isn't a step to undo.
    var plain_tabs = tabs.*;
    plain_tabs.active = null;
    plain.root = 0xFF;
    return fingerprint(&plain, &plain_tabs, &.{});
}

/// Put a layout `snapshot` made back into `layout`. Returns false, leaving it be, when `text`
/// isn't one.
/// Borrows `text`, frees parsing storage, and resets transient drag/menu state on success.
/// Allocation, parse, and version failures return false. The host must synchronize OS
/// pop-out windows after restoring the dock's saved window descriptions.
///
/// ```zig
/// const restored = layout_file.restore(gpa, saved_text, &layout, &tabs);
/// if (!restored) std.log.warn("Cannot restore layout", .{});
/// ```
pub fn restore(gpa: std.mem.Allocator, text: []const u8, layout: *dock.DockSpace, tabs: *Tabs) bool {
    const source = gpa.dupeZ(u8, text) catch return false;
    defer gpa.free(source);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const saved = std.zon.parse.fromSliceAlloc(Saved, arena.allocator(), source, null, .{ .ignore_unknown_fields = true }) catch return false;
    if (saved.version != version) return false;
    apply(saved, layout, tabs);
    return true;
}

fn apply(saved: Saved, layout: *dock.DockSpace, tabs: *Tabs) void {
    layout.nodes = saved.nodes;
    layout.homes = saved.homes;
    layout.root = saved.root;
    layout.floating = saved.floating;
    for (&layout.windows, saved.windows) |*window, kept| window.* = if (kept) |open| .{ .root = open.root, .size = open.size } else null;
    layout.z_counter = saved.z_counter;
    layout.drag = .none;
    layout.menu = 0xFF;
    // A file from before tabs has one: the main window's layout. One saved with none has an
    // empty main window, which makes a tab only to drop it.
    tabs.* = if (saved.tabs[0] == null) .init(layout) else .{ .list = saved.tabs, .active = saved.active_tab };
    tabs.prune(layout);
}

/// Put the user's saved layout into `layout`, keeping its buttons and settings, and the plugin
/// panels it has seen into `seen_panels` (each title owned by `gpa`). Returns false, leaving both
/// as they were, when there is none or it can't be read or parsed.
/// On success, appends copied titles to `seen_panels`; allocation failure may leave a
/// partial title list while still returning true. The host recreates described pop-outs.
///
/// ```zig
/// var seen: std.ArrayList([]u8) = .empty;
/// defer {
///     for (seen.items) |title| gpa.free(title);
///     seen.deinit(gpa);
/// }
/// _ = layout_file.load(gpa, user_folder, &layout, &tabs, &seen);
/// ```
pub fn load(gpa: std.mem.Allocator, folder: []const u8, layout: *dock.DockSpace, tabs: *Tabs, seen_panels: *std.ArrayList([]u8)) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{}) catch return false;
    defer dir.close(io);
    const source = dir.readFileAllocOptions(io, file_name, gpa, .limited(4 << 20), .of(u8), 0) catch return false;
    defer gpa.free(source);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const saved = std.zon.parse.fromSliceAlloc(Saved, arena.allocator(), source, null, .{ .ignore_unknown_fields = true }) catch {
        log.info("{s} is from another version of Eggy: the default layout is used", .{file_name});
        return false;
    };
    if (saved.version != version) return false;
    apply(saved, layout, tabs);
    for (saved.seen_panels) |title| {
        const copy = gpa.dupe(u8, title) catch break;
        seen_panels.append(gpa, copy) catch {
            gpa.free(copy);
            break;
        };
    }
    return true;
}

test "a layout saved is a layout restored" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(folder);

    var original = dock.DockSpace.init();
    try original.add(1, null, .center);
    try original.add(2, 1, .right);
    try original.detach(1);
    var original_tabs = Tabs.init(&original);
    save(gpa, folder, &original, &original_tabs, &.{"Stats"});

    var restored = dock.DockSpace.init();
    var tabs = Tabs.init(&restored);
    var seen: std.ArrayList([]u8) = .empty;
    defer {
        for (seen.items) |title| gpa.free(title);
        seen.deinit(gpa);
    }
    try std.testing.expect(load(gpa, folder, &restored, &tabs, &seen));
    try std.testing.expectEqualStrings("Stats", seen.items[0]);
    try std.testing.expect(restored.nodeOf(2) != null);
    try std.testing.expect(restored.windows[0] != null);
    try std.testing.expect(!load(gpa, "/nonexistent/eggy", &restored, &tabs, &seen));

    // A change shows in the fingerprint; the same layout doesn't.
    const before = fingerprint(&restored, &tabs, &.{});
    try std.testing.expectEqual(before, fingerprint(&restored, &tabs, &.{}));
    try restored.add(3, 2, .bottom);
    try std.testing.expect(fingerprint(&restored, &tabs, &.{}) != before);
}

test "a snapshot puts the layout back, and only rearranging changes its arrangement" {
    const gpa = std.testing.allocator;
    var layout = dock.DockSpace.init();
    try layout.add(1, null, .center);
    try layout.add(2, 1, .right);
    var tabs = Tabs.init(&layout);
    const text = try snapshot(gpa, &layout, &tabs);
    defer gpa.free(text);
    const before = arrangement(&layout, &tabs);
    layout.z_counter += 5;
    try std.testing.expectEqual(before, arrangement(&layout, &tabs));

    try layout.add(3, 2, .bottom);
    try std.testing.expect(arrangement(&layout, &tabs) != before);
    try std.testing.expect(restore(gpa, text, &layout, &tabs));
    try std.testing.expect(layout.nodeOf(3) == null);
    try std.testing.expect(!restore(gpa, "not a layout", &layout, &tabs));
}

test "tabs are kept with the layout, and undoing brings a closed one back" {
    const gpa = std.testing.allocator;
    var layout = dock.DockSpace.init();
    try layout.add(1, null, .center);
    var tabs = Tabs.init(&layout);
    _ = try tabs.open(&layout, .ui);
    try layout.add(2, null, .center);
    const text = try snapshot(gpa, &layout, &tabs);
    defer gpa.free(text);
    const before = arrangement(&layout, &tabs);
    tabs.show(&layout, 0);
    try std.testing.expectEqual(before, arrangement(&layout, &tabs));

    var restored_layout = dock.DockSpace.init();
    var restored_tabs = Tabs.init(&restored_layout);
    try std.testing.expect(restore(gpa, text, &restored_layout, &restored_tabs));
    try std.testing.expectEqual(@as(usize, 2), restored_tabs.count());
    try std.testing.expectEqual(@as(?u8, 1), restored_tabs.active);
    try std.testing.expectEqual(@as(?usize, 1), restored_tabs.ofPanel(&restored_layout, 2));
}
