//! What the Assets panel does to the project's files: new folders, renaming, duplicating, moving
//! and copying into folders, importing files from outside, and deleting, which moves things into
//! `.eggy/trash/` (so a deletion can be undone) rather than erasing them. Paths are relative to
//! the project, with `/` between parts, and never leave it. These only move bytes: the asset
//! catalog (`eggy.assets.catalog`, through `ProjectAssets`) is told afterwards what moved or was
//! copied, so ids follow moves and copies get new ones.
const std = @import("std");
const descriptor = @import("eggy").assets.descriptor;
const model_references = @import("model_references.zig");

pub const trash_dir = ".eggy/trash";

/// Make an empty folder in `parent` ("" for the project), named "New folder" (or "New folder 2"
/// and so on). Returns its path; caller-owned.
/// Editor-only: paths are project-relative; allocation, naming and filesystem errors propagate.
///
/// ```zig
/// // Given allocator gpa, I/O io and an open project directory:
/// const path = try createFolder(gpa, io, project, "resources");
/// defer gpa.free(path);
/// ```
pub fn createFolder(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, parent: []const u8) ![]u8 {
    const path = try freeName(gpa, io, project, parent, "New folder", "");
    errdefer gpa.free(path);
    try project.createDirPath(io, path);
    return path;
}

/// Create a uniquely named file from a New-menu template, without overwriting existing files.
/// Returns a caller-owned project-relative path.
/// Editor-only: validates parent/name/extension and removes an incomplete file on write failure
/// where possible; filesystem and allocation failures propagate.
///
/// ```zig
/// // Given gpa, io, an open project, and a plugin's EditorFileType template:
/// const path = try createFile(gpa, io, project, "resources", template);
/// defer gpa.free(path);
/// ```
pub fn createFile(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, parent: []const u8, file_type: @import("eggy").plugins.EditorFileType) ![]u8 {
    try @import("eggy").refs.validatePath(parent);
    try checkName(file_type.title);
    if (file_type.extension.len < 2 or file_type.extension[0] != '.' or std.mem.indexOfAny(u8, file_type.extension, "/\\\x00") != null) return error.BadPathName;
    const path = try freeName(gpa, io, project, parent, file_type.title, file_type.extension);
    errdefer gpa.free(path);
    try @import("eggy").refs.validatePath(path);
    if (parent.len != 0) try project.createDirPath(io, parent);
    var file = try project.createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    errdefer project.deleteFile(io, path) catch |err| std.log.err("cannot remove incomplete file {s}: {t}", .{ path, err });
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(file_type.contents);
    try writer.interface.flush();
    return path;
}

test "file templates create unique complete files and reject path-like names" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const template = @import("eggy").plugins.EditorFileType{ .key = "game/map", .title = "Player", .extension = ".inmap.zon", .contents = ".{ .controls = .{} }\n" };
    const first = try createFile(gpa, io, tmp.dir, "resources/input", template);
    defer gpa.free(first);
    const second = try createFile(gpa, io, tmp.dir, "resources/input", template);
    defer gpa.free(second);
    try std.testing.expectEqualStrings("resources/input/Player.inmap.zon", first);
    try std.testing.expectEqualStrings("resources/input/Player 2.inmap.zon", second);
    const contents = try tmp.dir.readFileAlloc(io, first, gpa, .limited(1024));
    defer gpa.free(contents);
    try std.testing.expectEqualStrings(template.contents, contents);
    try std.testing.expectError(error.InvalidPath, createFile(gpa, io, tmp.dir, "../outside", template));
    var invalid = template;
    invalid.title = "../file";
    try std.testing.expectError(error.BadPathName, createFile(gpa, io, tmp.dir, "", invalid));
    invalid = template;
    invalid.extension = ".zon/other";
    try std.testing.expectError(error.BadPathName, createFile(gpa, io, tmp.dir, "", invalid));
}

/// Rename `path` to `new_name` in the same folder. Returns the new path; caller-owned.
/// Editor-only: rejects invalid names and occupied destinations. Tell the catalog afterwards.
///
/// ```zig
/// // Given gpa, io and an open project containing resources/old.png:
/// const path = try rename(gpa, io, project, "resources/old.png", "new.png");
/// defer gpa.free(path);
/// ```
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
/// Editor-only: copies directory trees without legacy descriptors; tell the catalog it is a copy.
/// I/O/allocation errors propagate; a partially copied tree may remain on failure.
///
/// ```zig
/// // Given gpa, io and an open project containing resources/main.scene.zon:
/// const path = try duplicate(gpa, io, project, "resources/main.scene.zon");
/// defer gpa.free(path);
/// ```
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
/// Editor-only: rejects moving into the source or its descendants; the destination folder
/// must exist. Tell the catalog afterwards.
///
/// ```zig
/// // Given gpa, io and an open project with these paths:
/// const path = try moveInto(gpa, io, project, "resources/ship.glb", "resources/models");
/// defer gpa.free(path);
/// ```
pub fn moveInto(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, path: []const u8, folder: []const u8) ![]u8 {
    try checkDestination(path, folder);
    const target = try join(gpa, folder, std.fs.path.basename(path));
    errdefer gpa.free(target);
    try move(io, project, path, target);
    return target;
}

/// Copy `path` (a file, or a folder and everything in it) into `folder`, under its own name or,
/// when that is taken, "<name> 2" and so on. Returns the copy's path; caller-owned.
/// Editor-only: rejects copying into the source or its descendants; tell the catalog it is a copy.
/// I/O/allocation failures propagate without removing already-copied entries.
///
/// ```zig
/// // Given gpa, io and an open project with these paths:
/// const path = try copyInto(gpa, io, project, "resources/ship.glb", "resources/models");
/// defer gpa.free(path);
/// ```
pub fn copyInto(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, path: []const u8, folder: []const u8) ![]u8 {
    try checkDestination(path, folder);
    const target = try freeTarget(gpa, io, project, folder, std.fs.path.basename(path));
    errdefer gpa.free(target);
    try copyTree(gpa, io, project, path, project, target);
    return target;
}

/// Copy `outside` (an absolute path: a file, or a folder and everything in it) into `folder` of
/// the project, as `copyInto` does. A glTF model brings the files it refers to beside it (its
/// textures and buffers) to the same place beside the copy, unless they are there already.
/// Returns what it made, caller-owned: the copy's path first, then for each file brought along
/// the file or the first folder made for it, so trashing them all in reverse undoes it.
/// Editor-only: creates the destination folder, omits legacy descriptors from copied trees, and
/// propagates I/O/allocation errors; failure can leave partial output.
///
/// ```zig
/// // Given gpa, io, an open project and an absolute external file path:
/// const made = try import(gpa, io, project, outside, "resources");
/// std.debug.print("added {s}\n", .{made[0]});
/// ```
pub fn import(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, outside: []const u8, folder: []const u8) ![][]u8 {
    var made: std.ArrayList([]u8) = .empty;
    errdefer {
        for (made.items) |path| gpa.free(path);
        made.deinit(gpa);
    }
    try made.ensureUnusedCapacity(gpa, 1);
    const target = try freeTarget(gpa, io, project, folder, std.fs.path.basename(outside));
    made.appendAssumeCapacity(target);
    try project.createDirPath(io, folder);
    try copyTree(gpa, io, std.Io.Dir.cwd(), outside, project, target);
    if (model_references.isGltf(outside)) try importReferences(gpa, io, project, outside, target, &made);
    return made.toOwnedSlice(gpa);
}

/// Save `bytes`, what a plugin's importer made of the file at `outside`, into `folder` of the
/// project as the file's name with `extension` in place of its own (numbered if taken). Returns
/// the path it made, caller-owned. Editor-only: creates the folder; I/O failures propagate.
pub fn saveImported(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, outside: []const u8, folder: []const u8, extension: []const u8, bytes: []const u8) ![]u8 {
    const name = std.fs.path.basename(outside);
    const target = try freeName(gpa, io, project, folder, name[0..extensionStart(name)], extension);
    errdefer gpa.free(target);
    try project.createDirPath(io, folder);
    try project.writeFile(io, .{ .sub_path = target, .data = bytes });
    return target;
}

/// Copy the files the glTF model at `outside` refers to beside its copy at `target`, appending
/// what was made to `made`. One that is missing is logged and left out: the model still imports.
fn importReferences(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, outside: []const u8, target: []const u8, made: *std.ArrayList([]u8)) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // ponytail: reads the whole model for its JSON, fine until models reach hundreds of MB.
    const model = try std.Io.Dir.cwd().readFileAlloc(io, outside, arena, .limited(512 << 20));
    const references = model_references.referencedFiles(arena, model) catch return;
    const source_folder = std.fs.path.dirname(outside) orelse ".";
    const target_folder = std.fs.path.dirnamePosix(target) orelse "";
    for (references) |relative| {
        const destination = try join(arena, target_folder, relative);
        if (exists(io, project, destination)) continue;
        const source = try std.fs.path.join(arena, &.{ source_folder, relative });
        std.Io.Dir.cwd().access(io, source, .{}) catch {
            std.log.warn("{s} refers to {s}, which isn't beside it: imported without it", .{ std.fs.path.basename(outside), relative });
            continue;
        };
        try made.ensureUnusedCapacity(gpa, 1);
        const created = try gpa.dupe(u8, firstMissing(io, project, destination));
        errdefer gpa.free(created);
        if (std.fs.path.dirnamePosix(destination)) |parent| try project.createDirPath(io, parent);
        try copyTree(gpa, io, std.Io.Dir.cwd(), source, project, destination);
        made.appendAssumeCapacity(created);
    }
}

/// The first part of `path` that doesn't exist yet: what making it creates.
fn firstMissing(io: std.Io, project: std.Io.Dir, path: []const u8) []const u8 {
    var end: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, end, '/')) |slash| : (end = slash + 1) {
        if (!exists(io, project, path[0..slash])) return path[0..slash];
    }
    return path;
}

/// `name` in `folder`, or "<stem> 2<extension>" and so on, whichever is free. Caller-owned.
fn freeTarget(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, folder: []const u8, name: []const u8) ![]u8 {
    const stem_end = extensionStart(name);
    return freeName(gpa, io, project, folder, name[0..stem_end], name[stem_end..]);
}

/// Move `path` into the trash, in a folder of its own, keeping its name. Returns where it went
/// (for `restore`); caller-owned.
/// Editor-only: creates a random trash subfolder; tell the catalog it moved. Retain the original path separately for undo; filesystem/allocation failures propagate.
///
/// ```zig
/// // Given gpa, io and an open project containing resources/old.png:
/// const trashed = try trash(gpa, io, project, "resources/old.png");
/// defer gpa.free(trashed);
/// try restore(io, project, trashed, "resources/old.png");
/// ```
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
/// Editor-only: refuses an existing destination; its parent must already exist.
/// File-move failures propagate.
///
/// ```zig
/// // Given io and an open project with resources/new.png:
/// try move(io, project, "resources/new.png", "resources/old.png");
/// ```
pub fn move(io: std.Io, project: std.Io.Dir, from: []const u8, to: []const u8) !void {
    if (exists(io, project, to)) return error.PathAlreadyExists;
    try project.rename(from, project, to, io);
}

/// Move `from` (in the trash) back to `to`.
/// Editor-only: creates missing parent folders but never overwrites an existing target.
/// File errors propagate.
///
/// ```zig
/// // Given io, an open project and the path returned by trash:
/// try restore(io, project, trashed, "resources/old.png");
/// ```
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
        // Descriptors stay with the originals: each copy gets its own.
        if (descriptor.isDescriptor(entry.name)) continue;
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
    if (std.mem.indexOfAny(u8, name, "/\\\x00") != null) return error.BadPathName;
}

fn checkDestination(path: []const u8, folder: []const u8) !void {
    if (path.len == 0 or std.mem.eql(u8, path, folder)) return error.InvalidDestination;
    if (std.mem.startsWith(u8, folder, path) and folder.len > path.len and folder[path.len] == '/') return error.InvalidDestination;
}

test "move and copy reject destinations inside their source" {
    try std.testing.expectError(error.InvalidDestination, checkDestination("art", "art"));
    try std.testing.expectError(error.InvalidDestination, checkDestination("art", "art/copy"));
    try std.testing.expectError(error.InvalidDestination, checkDestination("", "art"));
    try checkDestination("art", "art2");
    try checkDestination("art", "");
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
    defer freePaths(gpa, imported);
    try std.testing.expectEqual(@as(usize, 1), imported.len);
    try std.testing.expectEqualStrings("sounds/boom.ogg", imported[0]);
    try std.testing.expect(exists(io, project, "sounds/boom.ogg"));
}

test "an imported glTF model brings the textures beside it, once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(io, .{ .sub_path = "bee.gltf", .data = "{\"images\":[{\"uri\":\"Textures/colormap.png\"},{\"uri\":\"gone.png\"}]}" });
    try outside.dir.writeFile(io, .{ .sub_path = "cat.gltf", .data = "{\"images\":[{\"uri\":\"Textures/colormap.png\"}]}" });
    try outside.dir.createDirPath(io, "Textures");
    try outside.dir.writeFile(io, .{ .sub_path = "Textures/colormap.png", .data = "png" });

    // The first brings the texture's folder; the second finds it there already.
    const bee_source = try outside.dir.realPathFileAlloc(io, "bee.gltf", gpa);
    defer gpa.free(bee_source);
    const bee = try import(gpa, io, tmp.dir, bee_source, "models");
    defer freePaths(gpa, bee);
    try std.testing.expectEqual(@as(usize, 2), bee.len);
    try std.testing.expectEqualStrings("models/bee.gltf", bee[0]);
    try std.testing.expectEqualStrings("models/Textures", bee[1]);
    try std.testing.expect(exists(io, tmp.dir, "models/Textures/colormap.png"));
    const cat_source = try outside.dir.realPathFileAlloc(io, "cat.gltf", gpa);
    defer gpa.free(cat_source);
    const cat = try import(gpa, io, tmp.dir, cat_source, "models");
    defer freePaths(gpa, cat);
    try std.testing.expectEqual(@as(usize, 1), cat.len);
}

fn freePaths(gpa: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |path| gpa.free(path);
    gpa.free(paths);
}

test "moves and copies leave legacy descriptors alone, for the catalog to migrate" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = tmp.dir;
    try project.createDirPath(io, "art");
    try project.writeFile(io, .{ .sub_path = "ship.glb", .data = "x" });
    try project.writeFile(io, .{ .sub_path = "ship.glb.eggy", .data = ".{ .id = 1, .kind = .model }" });

    const renamed = try rename(gpa, io, project, "ship.glb", "fighter.glb");
    defer gpa.free(renamed);
    try std.testing.expect(exists(io, project, "fighter.glb"));
    try std.testing.expect(exists(io, project, "ship.glb.eggy"));

    const folder_copy = try duplicate(gpa, io, project, "art");
    defer gpa.free(folder_copy);
    try std.testing.expect(exists(io, project, "art copy"));
}
