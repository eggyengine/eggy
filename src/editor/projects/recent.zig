//! The projects this user opened lately, newest first, kept in Eggy's data folder as
//! `recent_projects.zon` so every editor (each project's, and Eggy's own) shares one list.
const std = @import("std");
const zon = @import("eggy").assets.zon;
const log = std.log.scoped(.projects);

const file_name = "recent_projects.zon";
/// How many projects the list keeps; the oldest drop off.
pub const max_projects = 20;

pub const Entry = struct {
    /// The project's folder, absolute.
    dir: []const u8,
    /// When it was last opened, in seconds since the Unix epoch.
    opened_s: i64,
};

const Saved = struct { projects: []const Entry };

/// The list in `folder` (Eggy's data folder), newest first, allocated in `arena`. Empty when
/// there is none yet; one that can't be read or parsed is logged and treated as empty.
///
/// ```zig
/// const projects = recent.load(arena, io, data_folder);
/// ```
pub fn load(arena: std.mem.Allocator, io: std.Io, folder: []const u8) []const Entry {
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{}) catch return &.{};
    defer dir.close(io);
    const source = dir.readFileAllocOptions(io, file_name, arena, .limited(1 << 20), .of(u8), 0) catch |err| {
        if (err != error.FileNotFound) log.warn("cannot read the recent projects: {t}", .{err});
        return &.{};
    };
    const saved = zon.parse(Saved, arena, source, .{ .ignore_unknown_fields = true }) catch |err| {
        log.warn("cannot read the recent projects: {t}", .{err});
        return &.{};
    };
    return saved.projects;
}

/// Put `project_dir` (absolute) at the top of the list in `folder`, opened at `now_s`.
/// Failures are logged: a list not kept isn't worth stopping an editor for.
///
/// ```zig
/// recent.remember(gpa, io, data_folder, "/home/you/EggyProjects/space_game", now_s);
/// ```
pub fn remember(gpa: std.mem.Allocator, io: std.Io, folder: []const u8, project_dir: []const u8, now_s: i64) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const updated = withFirst(arena.allocator(), load(arena.allocator(), io, folder), .{ .dir = project_dir, .opened_s = now_s }) catch return;
    save(arena.allocator(), io, folder, updated);
}

/// Take `project_dir` off the list in `folder`. Failures are logged.
///
/// ```zig
/// recent.forget(gpa, io, data_folder, "/home/you/EggyProjects/old_game");
/// ```
pub fn forget(gpa: std.mem.Allocator, io: std.Io, folder: []const u8, project_dir: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const updated = without(arena.allocator(), load(arena.allocator(), io, folder), project_dir) catch return;
    save(arena.allocator(), io, folder, updated);
}

fn save(arena: std.mem.Allocator, io: std.Io, folder: []const u8, projects: []const Entry) void {
    var text: std.Io.Writer.Allocating = .init(arena);
    std.zon.stringify.serialize(Saved{ .projects = projects }, .{}, &text.writer) catch return;
    std.Io.Dir.cwd().createDirPath(io, folder) catch {};
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{}) catch |err| return log.warn("cannot keep the recent projects: {t}", .{err});
    defer dir.close(io);
    dir.writeFile(io, .{ .sub_path = file_name, .data = text.written() }) catch |err| log.warn("cannot keep the recent projects: {t}", .{err});
}

/// `projects` with `first` on top, any older entry for its folder dropped, at most `max_projects`.
fn withFirst(arena: std.mem.Allocator, projects: []const Entry, first: Entry) ![]const Entry {
    var list: std.ArrayList(Entry) = .empty;
    try list.append(arena, first);
    for (projects) |entry| {
        if (list.items.len == max_projects) break;
        if (!std.mem.eql(u8, entry.dir, first.dir)) try list.append(arena, entry);
    }
    return list.items;
}

fn without(arena: std.mem.Allocator, projects: []const Entry, project_dir: []const u8) ![]const Entry {
    var list: std.ArrayList(Entry) = .empty;
    for (projects) |entry| if (!std.mem.eql(u8, entry.dir, project_dir)) try list.append(arena, entry);
    return list.items;
}
