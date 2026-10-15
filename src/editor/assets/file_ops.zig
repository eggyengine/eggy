//! What the Assets panel does to the project's files: new folders, renaming, duplicating, moving
//! and copying into folders, importing files from outside, and deleting, which moves things into
//! `.eggy/trash/` (so a deletion can be undone) rather than erasing them. Paths are relative to
//! the project, with `/` between parts, and never leave it.
const std = @import("std");

pub const trash_dir = ".eggy/trash";

/// Make an empty folder in `parent` ("" for the project), named "New folder" (or "New folder 2"
/// and so on). Returns its path; caller-owned.
pub fn createFolder(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, parent: []const u8) ![]u8 {
    const path = try freeName(gpa, io, project, parent, "New folder", "");
    errdefer gpa.free(path);
    try project.createDirPath(io, path);
    return path;
}

/// Rename `path` to `new_name` in the same folder. Returns the new path; caller-owned.
pub fn rename(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, path: []const u8, new_name: []const u8) ![]u8 {
    try checkName(new_name);
    const target = try join(gpa, parentOf(path), new_name);
    errdefer gpa.free(target);
    if (exists(io, project, target)) return error.PathAlreadyExists;
    try project.rename(path, project, target, io);
    return target;
}

/// Copy `path` (a file, or a folder and everything in it) beside itself as "<name> copy".
/// Returns the copy's path; caller-owned.
pub fn duplicate(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, path: []const u8) ![]u8 {
    const name = std.fs.path.basename(path);
    const stem_end = extensionStart(name);
    const stem = try std.fmt.allocPrint(gpa, "{s} copy", .{name[0..stem_end]});
    defer gpa.free(stem);
    const target = try freeName(gpa, io, project, parentOf(path), stem, name[stem_end..]);
    errdefer gpa.free(target);
    try copyTree(gpa, io, project, path, project, target);
    return target;
}

/// Move `path` into `folder` ("" for the project), keeping its name. Returns the new path;
/// caller-owned. Fails with `error.PathAlreadyExists` when the folder has one so named.
pub fn moveInto(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, path: []const u8, folder: []const u8) ![]u8 {
    const target = try join(gpa, folder, std.fs.path.basename(path));
    errdefer gpa.free(target);
    try move(io, project, path, target);
    return target;
}

/// Copy `path` (a file, or a folder and everything in it) into `folder`, under its own name or,
/// when that is taken, "<name> 2" and so on. Returns the copy's path; caller-owned.
pub fn copyInto(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, path: []const u8, folder: []const u8) ![]u8 {
    const target = try freeTarget(gpa, io, project, folder, std.fs.path.basename(path));
    errdefer gpa.free(target);
    try copyTree(gpa, io, project, path, project, target);
    return target;
}

/// Copy `outside` (an absolute path: a file, or a folder and everything in it) into `folder` of
/// the project, as `copyInto` does. Returns the copy's path; caller-owned.
pub fn import(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, outside: []const u8, folder: []const u8) ![]u8 {
    const target = try freeTarget(gpa, io, project, folder, std.fs.path.basename(outside));
    errdefer gpa.free(target);
    try project.createDirPath(io, folder);
    try copyTree(gpa, io, std.Io.Dir.cwd(), outside, project, target);
    return target;
}

/// `name` in `folder`, or "<stem> 2<extension>" and so on, whichever is free. Caller-owned.
fn freeTarget(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, folder: []const u8, name: []const u8) ![]u8 {
    const stem_end = extensionStart(name);
    return freeName(gpa, io, project, folder, name[0..stem_end], name[stem_end..]);
}

/// Move `path` into the trash, in a folder of its own, keeping its name. Returns where it went
/// (for `restore`); caller-owned.
pub fn trash(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, path: []const u8) ![]u8 {
    var tag: [8]u8 = undefined;
    io.random(&tag);
    const folder = try std.fmt.allocPrint(gpa, "{s}/{x}", .{ trash_dir, tag });
    defer gpa.free(folder);
    try project.createDirPath(io, folder);
    const target = try join(gpa, folder, std.fs.path.basename(path));
    errdefer gpa.free(target);
    try project.rename(path, project, target, io);
    return target;
}

/// Move `from` to `to` (both relative to the project), as undoing a rename does.
pub fn move(io: std.Io, project: std.Io.Dir, from: []const u8, to: []const u8) !void {
    if (exists(io, project, to)) return error.PathAlreadyExists;
    try project.rename(from, project, to, io);
}

/// Move `from` (in the trash) back to `to`.
pub fn restore(io: std.Io, project: std.Io.Dir, from: []const u8, to: []const u8) !void {
    if (exists(io, project, to)) return error.PathAlreadyExists;
    if (std.fs.path.dirname(to)) |parent| try project.createDirPath(io, parent);
    try project.rename(from, project, to, io);
}

/// `name` in `folder`, or `name 2`, `name 3` and so on, whichever is free, with `extension`.
fn freeName(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, folder: []const u8, name: []const u8, extension: []const u8) ![]u8 {
    var n: usize = 1;
    while (n < 1000) : (n += 1) {
        const file = if (n == 1) try std.fmt.allocPrint(gpa, "{s}{s}", .{ name, extension }) else try std.fmt.allocPrint(gpa, "{s} {d}{s}", .{ name, n, extension });
        defer gpa.free(file);
        const path = try join(gpa, folder, file);
        if (!exists(io, project, path)) return path;
        gpa.free(path);
    }
    return error.NoFreeName;
}

/// Copy `from` in `from_dir` (a file, or a folder and everything in it) to `to` in `to_dir`.
fn copyTree(gpa: std.mem.Allocator, io: std.Io, from_dir: std.Io.Dir, from: []const u8, to_dir: std.Io.Dir, to: []const u8) !void {
    const stat = try from_dir.statFile(io, from, .{});
    if (stat.kind != .directory) return from_dir.copyFile(from, to_dir, to, io, .{});
    try to_dir.createDirPath(io, to);
    var dir = try from_dir.openDir(io, from, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const inner_from = try join(gpa, from, entry.name);
        defer gpa.free(inner_from);
        const inner_to = try join(gpa, to, entry.name);
        defer gpa.free(inner_to);
        try copyTree(gpa, io, from_dir, inner_from, to_dir, inner_to);
    }
}

/// Where a name's extension starts: its first dot after the first character (`main.scene.zon`
/// is "main" and ".scene.zon"); its end without one.
fn extensionStart(name: []const u8) usize {
    if (name.len < 2) return name.len;
    return if (std.mem.indexOfScalarPos(u8, name, 1, '.')) |dot| dot else name.len;
}

/// A name for a file or folder: not empty, no slashes, not `.` or `..`.
fn checkName(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.BadPathName;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return error.BadPathName;
}

fn join(gpa: std.mem.Allocator, folder: []const u8, name: []const u8) ![]u8 {
    return if (folder.len == 0) gpa.dupe(u8, name) else std.fmt.allocPrint(gpa, "{s}/{s}", .{ folder, name });
}

fn parentOf(path: []const u8) []const u8 {
    return path[0 .. std.mem.lastIndexOfScalar(u8, path, '/') orelse 0];
}

fn exists(io: std.Io, project: std.Io.Dir, path: []const u8) bool {
    project.access(io, path, .{}) catch return false;
    return true;
}

test "folders, renames, copies and the trash" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = tmp.dir;

    const folder = try createFolder(gpa, io, project, "");
    defer gpa.free(folder);
    try std.testing.expectEqualStrings("New folder", folder);
    const second = try createFolder(gpa, io, project, "");
    defer gpa.free(second);
    try std.testing.expectEqualStrings("New folder 2", second);

    try project.writeFile(io, .{ .sub_path = "New folder/main.scene.zon", .data = "x" });
    const copy = try duplicate(gpa, io, project, "New folder/main.scene.zon");
    defer gpa.free(copy);
    try std.testing.expectEqualStrings("New folder/main copy.scene.zon", copy);
    const folder_copy = try duplicate(gpa, io, project, "New folder");
    defer gpa.free(folder_copy);
    try std.testing.expect(exists(io, project, "New folder copy/main.scene.zon"));

    const renamed = try rename(gpa, io, project, "New folder 2", "Levels");
    defer gpa.free(renamed);
    try std.testing.expectEqualStrings("Levels", renamed);
    try std.testing.expectError(error.BadPathName, rename(gpa, io, project, "Levels", "../out"));

    const trashed = try trash(gpa, io, project, "Levels");
    defer gpa.free(trashed);
    try std.testing.expect(!exists(io, project, "Levels"));
    try restore(io, project, trashed, "Levels");
    try std.testing.expect(exists(io, project, "Levels"));
}

test "moving and copying into folders, and importing from outside" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = tmp.dir;
    try project.createDirPath(io, "art");
    try project.writeFile(io, .{ .sub_path = "ship.png", .data = "x" });

    const moved = try moveInto(gpa, io, project, "ship.png", "art");
    defer gpa.free(moved);
    try std.testing.expectEqualStrings("art/ship.png", moved);
    const copied = try copyInto(gpa, io, project, "art/ship.png", "art");
    defer gpa.free(copied);
    try std.testing.expectEqualStrings("art/ship 2.png", copied);

    // From outside the project: a file elsewhere, copied in.
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(io, .{ .sub_path = "boom.ogg", .data = "y" });
    const source = try outside.dir.realPathFileAlloc(io, "boom.ogg", gpa);
    defer gpa.free(source);
    const imported = try import(gpa, io, project, source, "sounds");
    defer gpa.free(imported);
    try std.testing.expectEqualStrings("sounds/boom.ogg", imported);
    try std.testing.expect(exists(io, project, "sounds/boom.ogg"));
}
