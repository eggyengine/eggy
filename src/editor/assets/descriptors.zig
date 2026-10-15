//! Keeps every file in a project's `resources/` with a descriptor beside it
//! (`eggy.assets.descriptor`): `sync` makes the missing ones and removes those whose file has
//! gone. Moves the editor makes carry descriptors along themselves (`file_ops.zig`); this catches
//! what happens to the files outside the editor.
const std = @import("std");
const eggy = @import("eggy");
const descriptor = eggy.assets.descriptor;

pub const Changes = struct {
    made: usize = 0,
    removed: usize = 0,

    pub fn any(self: Changes) bool {
        return self.made + self.removed > 0;
    }
};

/// Give every file in `project`'s `resources/` a descriptor, and remove descriptors left without
/// a file. A project without `resources/` has nothing to do.
pub fn sync(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir) !Changes {
    var resources = project.openDir(io, eggy.project.resources_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer resources.close(io);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Every file and every descriptor, by path inside `resources/`.
    var files: std.StringHashMapUnmanaged(void) = .empty;
    var descriptors: std.ArrayList([]const u8) = .empty;
    var walker = try resources.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try arena.allocator().dupe(u8, entry.path);
        if (descriptor.isDescriptor(path)) try descriptors.append(arena.allocator(), path) else try files.put(arena.allocator(), path, {});
    }

    var changes: Changes = .{};
    // Descriptors whose file has gone go too.
    for (descriptors.items) |path| {
        const file = path[0 .. path.len - descriptor.extension.len];
        if (files.remove(file)) continue;
        try resources.deleteFile(io, path);
        changes.removed += 1;
    }
    // What is left in `files` has no descriptor yet.
    var it = files.keyIterator();
    while (it.next()) |file| {
        try descriptor.write(io, resources, file.*, descriptor.new(io, file.*));
        changes.made += 1;
    }
    return changes;
}

test "files get descriptors, and descriptors without files go" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = tmp.dir;
    try project.createDirPath(io, "resources/models");
    try project.writeFile(io, .{ .sub_path = "resources/models/ship.glb", .data = "x" });
    try project.writeFile(io, .{ .sub_path = "resources/gone.png.eggy", .data = ".{ .id = 1, .kind = .image }" });

    const changes = try sync(std.testing.allocator, io, project);
    try std.testing.expectEqual(Changes{ .made = 1, .removed = 1 }, changes);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const made = (try descriptor.read(arena.allocator(), io, project, "resources/models/ship.glb")).?;
    try std.testing.expectEqual(eggy.assets.Kind.model, made.kind);

    // Nothing to do the second time, and the id stays.
    try std.testing.expect(!(try sync(std.testing.allocator, io, project)).any());
    try std.testing.expectEqual(made.id, (try descriptor.read(arena.allocator(), io, project, "resources/models/ship.glb")).?.id);
}
