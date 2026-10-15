//! The project's scene on disk, `scenes/main.scene.zon` (see `eggy.scene`): put into the world
//! when the editor starts, before the game's plugins, and written by File > Save.
const std = @import("std");
const eggy = @import("eggy");
const log = std.log.scoped(.scene);

/// Where the scene is, relative to the project.
pub const relative_path = "scenes" ++ std.fs.path.sep_str ++ "main.scene.zon";

/// Put the scene saved in `project_dir` into `world`, if there is one. Problems are logged.
pub fn load(gpa: std.mem.Allocator, project_dir: []const u8, world: *eggy.ecs.World, access: eggy.scene.Access) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const path = std.fs.path.join(gpa, &.{ project_dir, relative_path }) catch return;
    defer gpa.free(path);
    const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(64 << 20), .of(u8), 0) catch |err| {
        if (err != error.FileNotFound) log.err("cannot read {s}: {t}", .{ path, err });
        return;
    };
    defer gpa.free(source);
    var scene = eggy.scene.Scene.parse(gpa, source) catch |err| return log.err("{s} isn't a scene ({t}): it isn't loaded", .{ relative_path, err });
    defer scene.deinit();
    const made = scene.instantiate(gpa, world, access, null) catch |err| return log.err("cannot load {s}: {t}", .{ relative_path, err });
    defer gpa.free(made.entities);
    if (made.skipped > 0) log.warn("loaded {s}: {d} entities, {d} components or fields left out (see above)", .{ relative_path, made.entities.len, made.skipped }) else log.info("loaded {s}: {d} entities", .{ relative_path, made.entities.len });
}

/// Write every entity of `world` to the scene in `project_dir`.
pub fn save(gpa: std.mem.Allocator, project_dir: []const u8, world: *eggy.ecs.World, access: eggy.scene.Access) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var scene = try eggy.scene.Scene.capture(gpa, world, access, null);
    defer scene.deinit();
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try scene.write(&text.writer);

    var project = try std.Io.Dir.cwd().openDir(io, project_dir, .{});
    defer project.close(io);
    try project.createDirPath(io, std.fs.path.dirname(relative_path).?);
    try project.writeFile(io, .{ .sub_path = relative_path, .data = text.written() });
    log.info("saved {d} entities to {s}", .{ scene.entities.len, relative_path });
}
