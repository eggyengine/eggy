//! Keeps every file and folder in a project's `resources/` with a descriptor beside it
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

/// Give every file and folder in `project`'s `resources/` a descriptor, and remove descriptors
/// left without one. A project without `resources/` has nothing to do.
pub fn sync(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir) !Changes {
    var resources = project.openDir(io, eggy.project.resources_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer resources.close(io);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Every file and folder (whether it is a folder), and every descriptor, by path inside
    // `resources/`.
    var files: std.StringHashMapUnmanaged(bool) = .empty;
    var descriptors: std.ArrayList([]const u8) = .empty;
    var walker = try resources.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .directory) continue;
        const path = try arena.allocator().dupe(u8, entry.path);
        if (entry.kind == .file and descriptor.isDescriptor(path)) {
            try descriptors.append(arena.allocator(), path);
        } else try files.put(arena.allocator(), path, entry.kind == .directory);
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
    var it = files.iterator();
    while (it.next()) |entry| {
        var made = descriptor.new(io, entry.key_ptr.*);
        if (entry.value_ptr.*) made.kind = .folder;
        try descriptor.write(io, resources, entry.key_ptr.*, made);
        changes.made += 1;
    }
    return changes;
}

test "files and folders get descriptors, and descriptors without them go" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = tmp.dir;
    try project.createDirPath(io, "resources/models");
    try project.writeFile(io, .{ .sub_path = "resources/models/ship.glb", .data = "x" });
    try project.writeFile(io, .{ .sub_path = "resources/gone.png.eggy", .data = ".{ .id = 1, .kind = .image }" });

    const changes = try sync(std.testing.allocator, io, project);
    try std.testing.expectEqual(Changes{ .made = 2, .removed = 1 }, changes);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const made = (try descriptor.read(arena.allocator(), io, project, "resources/models/ship.glb")).?;
    try std.testing.expectEqual(eggy.assets.Kind.model, made.kind);
    try std.testing.expectEqual(eggy.assets.Kind.folder, (try descriptor.read(arena.allocator(), io, project, "resources/models")).?.kind);

    // Nothing to do the second time, and the id stays.
    try std.testing.expect(!(try sync(std.testing.allocator, io, project)).any());
    try std.testing.expectEqual(made.id, (try descriptor.read(arena.allocator(), io, project, "resources/models/ship.glb")).?.id);
}
