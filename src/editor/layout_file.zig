//! The dock's layout (which panels go where, split how, floating or popped out) kept per user in
//! Eggy's data folder as `layout.zon`: saved when the editor closes, and restored when the next
//! one opens, in any project.
const std = @import("std");
const eggy = @import("eggy");
const dock = eggy.ui.dock;
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
};

/// Write `layout` to the user's `layout.zon` in `folder` (Eggy's data folder). Failures are
/// logged: a layout not kept isn't worth stopping for.
pub fn save(gpa: std.mem.Allocator, folder: []const u8, layout: *const dock.DockSpace) void {
    var saved = Saved{ .version = version, .nodes = layout.nodes, .homes = layout.homes, .root = layout.root, .floating = layout.floating, .windows = undefined, .z_counter = layout.z_counter };
    for (&saved.windows, layout.windows) |*kept, window| kept.* = if (window) |open| .{ .root = open.root, .size = open.size } else null;
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    std.zon.stringify.serialize(saved, .{ .whitespace = false }, &text.writer) catch return;

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    std.Io.Dir.cwd().createDirPath(io, folder) catch {};
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{}) catch |err| return log.warn("cannot keep the layout: {t}", .{err});
    defer dir.close(io);
    dir.writeFile(io, .{ .sub_path = file_name, .data = text.written() }) catch |err| log.warn("cannot keep the layout: {t}", .{err});
}

/// Put the user's saved layout into `layout`, keeping its buttons and settings. Returns false,
/// leaving `layout` as it was, when there is none or it can't be read.
pub fn load(gpa: std.mem.Allocator, folder: []const u8, layout: *dock.DockSpace) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{}) catch return false;
    defer dir.close(io);
    const source = dir.readFileAllocOptions(io, file_name, gpa, .limited(4 << 20), .of(u8), 0) catch return false;
    defer gpa.free(source);
    const saved = std.zon.parse.fromSlice(Saved, gpa, source, null, .{ .ignore_unknown_fields = true }) catch {
        log.info("{s} is from another version of Eggy: the default layout is used", .{file_name});
        return false;
    };
    if (saved.version != version) return false;
    layout.nodes = saved.nodes;
    layout.homes = saved.homes;
    layout.root = saved.root;
    layout.floating = saved.floating;
    for (&layout.windows, saved.windows) |*window, kept| window.* = if (kept) |open| .{ .root = open.root, .size = open.size } else null;
    layout.z_counter = saved.z_counter;
    layout.drag = .none;
    layout.menu = 0xFF;
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
    save(gpa, folder, &original);

    var restored = dock.DockSpace.init();
    try std.testing.expect(load(gpa, folder, &restored));
    try std.testing.expect(restored.nodeOf(2) != null);
    try std.testing.expect(restored.windows[0] != null);
    try std.testing.expect(!load(gpa, "/nonexistent/eggy", &restored));
}
