//! Where the Hierarchy's folds and hidden entities are kept between runs: the project's
//! `.eggy/hierarchy.zon`, by scene, each entity by its name path (see `view_state.zig`).
const std = @import("std");
const eggy = @import("eggy");
const zon_file = eggy.assets.zon;
const ViewState = @import("view_state.zig").ViewState;
const Fold = @import("view_state.zig").Fold;

pub const file_name = ".eggy/hierarchy.zon";

const Scene = struct { scene: []const u8, collapsed: []const []const u8 = &.{}, hidden: []const []const u8 = &.{} };
const File = struct { scenes: []const Scene = &.{} };

/// Load what the project in `project_dir` keeps for `scene` (a project path; "" for one not
/// saved yet) into `state`; nothing kept, or a file that can't be read, keeps nothing.
pub fn load(gpa: std.mem.Allocator, project_dir: []const u8, scene: []const u8, state: *ViewState) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const file = read(arena.allocator(), project_dir);
    for (file.scenes) |kept| if (std.mem.eql(u8, kept.scene, scene)) {
        state.keep(kept.collapsed, kept.hidden) catch |err| std.log.warn("cannot keep the Hierarchy's folds: {t}", .{err});
        return;
    };
    state.keep(&.{}, &.{}) catch {};
}

/// Write `state`'s kept folds and hides for `scene` into the project's file, keeping the other
/// scenes'; a scene with none is left out. Failures are logged: it is only the view.
pub fn save(gpa: std.mem.Allocator, project_dir: []const u8, scene: []const u8, state: *const ViewState) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old = read(arena, project_dir);
    var scenes: std.ArrayList(Scene) = .empty;
    for (old.scenes) |kept| if (!std.mem.eql(u8, kept.scene, scene)) scenes.append(arena, kept) catch return;
    const collapsed = state.kept[@backingInt(Fold.collapsed)].keys();
    const hidden = state.kept[@backingInt(Fold.hidden)].keys();
    if (collapsed.len + hidden.len > 0) scenes.append(arena, .{ .scene = scene, .collapsed = collapsed, .hidden = hidden }) catch return;

    var text: std.Io.Writer.Allocating = .init(arena);
    std.zon.stringify.serialize(File{ .scenes = scenes.items }, .{}, &text.writer) catch return;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, project_dir, .{}) catch return;
    defer dir.close(io);
    dir.createDirPath(io, std.fs.path.dirname(file_name).?) catch {};
    dir.writeFile(io, .{ .sub_path = file_name, .data = text.written() }) catch |err| std.log.warn("cannot keep the Hierarchy's folds in {s}: {t}", .{ file_name, err });
}

fn read(arena: std.mem.Allocator, project_dir: []const u8) File {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, project_dir, .{}) catch return .{};
    defer dir.close(io);
    const text = dir.readFileAllocOptions(io, file_name, arena, .limited(4 << 20), .of(u8), 0) catch return .{};
    return zon_file.parse(File, arena, text, .{ .ignore_unknown_fields = true }) catch .{};
}

test "each scene's folds are kept apart, and a scene with none is left out" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    var state = ViewState{ .gpa = gpa };
    defer state.deinit();

    try state.keep(&.{"fence"}, &.{"fence/panel#2"});
    save(gpa, dir, "resources/scene/garden.scene.zon", &state);
    try state.keep(&.{"house"}, &.{});
    save(gpa, dir, "resources/scene/town.scene.zon", &state);

    load(gpa, dir, "resources/scene/garden.scene.zon", &state);
    try std.testing.expect(state.kept[@backingInt(Fold.collapsed)].contains("fence"));
    try std.testing.expect(state.kept[@backingInt(Fold.hidden)].contains("fence/panel#2"));
    try std.testing.expect(!state.dirty);
    load(gpa, dir, "resources/scene/town.scene.zon", &state);
    try std.testing.expect(state.kept[@backingInt(Fold.collapsed)].contains("house"));

    // Unfolded again: the scene goes from the file.
    try state.keep(&.{}, &.{});
    save(gpa, dir, "resources/scene/town.scene.zon", &state);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 1), read(arena.allocator(), dir).scenes.len);
}
