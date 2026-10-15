//! A project folder's contents as the Assets panel lists them: folders first, then files, by
//! name, each with the kind of thing it is; hidden files, descriptors and build output left out.
const std = @import("std");
const eggy = @import("eggy");

pub const Kind = enum {
    folder,
    scene,
    code,
    text,
    image,
    audio,
    file,

    /// What a file is, by its name.
    pub fn ofFile(name: []const u8) Kind {
        if (std.mem.endsWith(u8, name, ".scene.zon")) return .scene;
        const extension = std.fs.path.extension(name);
        const kinds = [_]struct { []const []const u8, Kind }{
            .{ &.{".zig"}, .code },
            .{ &.{ ".zon", ".md", ".txt", ".json", ".toml" }, .text },
            .{ &.{ ".png", ".jpg", ".jpeg", ".gif", ".svg", ".bmp", ".webp" }, .image },
            .{ &.{ ".wav", ".ogg", ".mp3", ".flac" }, .audio },
        };
        for (kinds) |entry| for (entry[0]) |known| {
            if (std.ascii.eqlIgnoreCase(extension, known)) return entry[1];
        };
        return .file;
    }
};

pub const Entry = struct {
    /// Relative to the project, with `/` between parts.
    path: []const u8,
    name: []const u8,
    kind: Kind,
};

/// Folders the panel leaves out wherever they are: build output and caches.
const skipped = [_][]const u8{ "zig-out", "zig-pkg", "node_modules" };

/// The contents of `folder` (relative to `project`, empty for the project itself), into `arena`.
/// A folder that can't be read lists as empty.
pub fn list(arena: std.mem.Allocator, io: std.Io, project: std.Io.Dir, folder: []const u8) ![]const Entry {
    var dir = (if (folder.len == 0) project.openDir(io, ".", .{ .iterate = true }) else project.openDir(io, folder, .{ .iterate = true })) catch return &.{};
    defer dir.close(io);
    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |item| {
        // Hidden files, and descriptors, which belong to the file beside them.
        if (item.name.len == 0 or item.name[0] == '.' or eggy.assets.descriptor.isDescriptor(item.name)) continue;
        const found: ?Kind = switch (item.kind) {
            .directory => blk: {
                for (skipped) |name| if (std.mem.eql(u8, item.name, name)) break :blk null;
                break :blk Kind.folder;
            },
            .file, .sym_link => Kind.ofFile(item.name),
            else => null,
        };
        const kind = found orelse continue;
        const path = if (folder.len == 0) try arena.dupe(u8, item.name) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ folder, item.name });
        try entries.append(arena, .{ .path = path, .name = std.fs.path.basename(path), .kind = kind });
    }
    std.mem.sort(Entry, entries.items, {}, before);
    return entries.items;
}

/// Folders first, then by name, ignoring case.
fn before(_: void, a: Entry, b: Entry) bool {
    if ((a.kind == .folder) != (b.kind == .folder)) return a.kind == .folder;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

/// The folder holding `path`, empty for the project itself.
pub fn parentOf(path: []const u8) []const u8 {
    return path[0 .. std.mem.lastIndexOfScalar(u8, path, '/') orelse 0];
}

test "files are told apart by their names" {
    try std.testing.expectEqual(Kind.scene, Kind.ofFile("main.scene.zon"));
    try std.testing.expectEqual(Kind.text, Kind.ofFile("build.zig.zon"));
    try std.testing.expectEqual(Kind.code, Kind.ofFile("root.zig"));
    try std.testing.expectEqual(Kind.image, Kind.ofFile("Icon.PNG"));
    try std.testing.expectEqual(Kind.file, Kind.ofFile("LICENSE"));
}

test "a folder lists folders first, without hidden files or build output" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "zig-out/bin");
    try tmp.dir.createDirPath(io, ".eggy");
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const top = try list(arena.allocator(), io, tmp.dir, "");
    try std.testing.expectEqual(@as(usize, 2), top.len);
    try std.testing.expectEqualStrings("src", top[0].name);
    try std.testing.expectEqual(Kind.folder, top[0].kind);
    const inside = try list(arena.allocator(), io, tmp.dir, "src");
    try std.testing.expectEqualStrings("src/main.zig", inside[0].path);
    try std.testing.expectEqualStrings("src", parentOf(inside[0].path));
    try std.testing.expectEqualStrings("", parentOf("src"));
}
