//! Headless use of the editor's project creation and export jobs.
const std = @import("std");
const eggy = @import("eggy");
const jobs = @import("../projects/job.zig");
const template = @import("../projects/template.zig");
const listing = @import("../assets/listing.zig");
const platforms = @import("../export/platforms.zig");
const Prompt = @import("prompt.zig").Prompt;

pub const New = struct {
    title: ?[]const u8 = null,
    name: ?[]const u8 = null,
    directory: ?[]const u8 = null,
    open: bool = false,
};

pub const Export = struct {
    project: ?[]const u8 = null,
    scene: ?[]const u8 = null,
    target: ?[]const u8 = null,
};

/// Create and build a project using the GUI's bundled template, without overwriting files.
/// Editor CLI only: `process` supplies spawning/I/O, while `prompt` supplies answers and
/// arena storage. Blocks until the background job finishes, streams progress, and optionally
/// launches the resulting editor. Failures propagate without deleting a partially made project.
///
/// ```zig
/// // Given process and Prompt pointers, with bundled editor resources installed:
/// try create(process, prompt, .{
///     .title = "Space Game", .name = "space_game", .directory = "space_game",
/// });
/// ```
pub fn create(process: *const std.process.Init, prompt: *Prompt, options: New) !void {
    const title = try prompt.text(options.title, "Project title", "title", null);
    var name_buffer: [template.max_name_len]u8 = undefined;
    const derived = template.packageName(&name_buffer, title);
    const name = try prompt.text(options.name, "Package name", "name", if (derived.len > 0) derived else null);
    template.validateName(name) catch |err| {
        try prompt.output.writeAll("Package names must be Zig identifiers of at most 32 characters, not keywords.\n");
        return err;
    };
    const directory = try prompt.text(options.directory, "Project directory", "directory", name);
    const dir = try std.fs.path.resolve(prompt.arena, &.{directory});
    const folders = try jobs.editorFolders(prompt.arena);
    const job = try jobs.Job.start(process.gpa, .{
        .dir = dir,
        .resources_dir = folders.resources_dir,
        .engines_dir = folders.engines_dir,
        .action = .{ .create = .{ .title = title, .name = name } },
    });
    defer job.deinit();
    try follow(process, prompt, job);
    try prompt.output.print("Created {s}\n", .{dir});
    if (options.open) try job.launchEditor(&.{});
}

/// Export without changing the project's saved default scene.
/// Editor CLI only: resolve missing options through `prompt`, validate an existing resources
/// scene and Zig target, then block while building the fast-optimized folder/ZIP output. Progress
/// goes to the prompt writer; validation, I/O and job errors propagate. Scratch strings live
/// in the prompt arena; the job is joined/freed before returning, even on failure.
///
/// ```zig
/// // Given process and Prompt pointers and an existing project:
/// try exportGame(process, prompt, .{
///     .project = "space_game", .scene = "resources/main.scene.zon", .target = "native",
/// });
/// ```
pub fn exportGame(process: *const std.process.Init, prompt: *Prompt, options: Export) !void {
    const directory = try prompt.text(options.project, "Project directory", "project", ".");
    const dir = try std.fs.path.resolve(prompt.arena, &.{directory});
    var project = try std.Io.Dir.cwd().openDir(process.io, dir, .{});
    defer project.close(process.io);
    const config = try eggy.project.load(prompt.arena, process.io, project);
    if (options.scene == null and !prompt.non_interactive) {
        for (try listing.scenes(prompt.arena, process.io, project, eggy.project.resources_dir)) |scene| {
            try prompt.output.print("  {s}\n", .{scene});
        }
    }
    const scene = try prompt.text(options.scene, "Startup scene (project-relative path)", "scene", config.default_scene);
    try validateScene(process.io, project, scene);
    if (options.target == null and !prompt.non_interactive) {
        const defaults = platforms.Settings.defaults();
        for (defaults, 0..) |settings, i| {
            const platform: platforms.Platform = @fromBackingInt(@intCast(i));
            try prompt.output.print("  {s}: {s}. {s}\n", .{ platforms.target(platform, settings), platforms.title(platform), platforms.note(platform) });
        }
    }
    const target = try prompt.text(options.target, "Zig target", "target", "native");
    _ = std.Target.Query.parse(.{ .arch_os_abi = target }) catch |err| {
        try prompt.output.print("Invalid Zig target: {s}\n", .{target});
        return err;
    };
    const folders = try jobs.editorFolders(prompt.arena);
    const job = try jobs.Job.start(process.gpa, .{
        .dir = dir,
        .resources_dir = folders.resources_dir,
        .engines_dir = folders.engines_dir,
        .action = .{ .export_game = &.{ try std.fmt.allocPrint(prompt.arena, "-Dtarget={s}", .{target}), try std.fmt.allocPrint(prompt.arena, "-Dscene={s}", .{scene}) } },
    });
    defer job.deinit();
    try follow(process, prompt, job);
    try prompt.output.print("Exported folder and ZIP: {s}{c}zig-out{c}export\n", .{ dir, std.fs.path.sep, std.fs.path.sep });
}

fn validateScene(io: std.Io, project: std.Io.Dir, scene: []const u8) !void {
    if (std.fs.path.isAbsolute(scene) or !std.mem.endsWith(u8, scene, ".scene.zon")) return error.InvalidScenePath;
    var parts = std.mem.tokenizeAny(u8, scene, "/\\");
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidScenePath, eggy.project.resources_dir)) return error.InvalidScenePath;
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.InvalidScenePath;
    const stat = try project.statFile(io, scene, .{});
    if (stat.kind != .file) return error.InvalidScenePath;
}

fn follow(process: *const std.process.Init, prompt: *Prompt, job: *jobs.Job) !void {
    var arena: std.heap.ArenaAllocator = .init(process.gpa);
    defer arena.deinit();
    var shown: usize = 0;
    var stage: ?jobs.Stage = null;
    while (true) {
        _ = arena.reset(.retain_capacity);
        const status = try job.status(arena.allocator());
        if (stage != status.stage) {
            try prompt.output.print("{s}\n", .{status.stage.label()});
            stage = status.stage;
        }
        try prompt.output.writeAll(status.log[shown..]);
        shown = status.log.len;
        try prompt.output.flush();
        switch (status.stage) {
            .done => return,
            .failed => {
                try prompt.output.print("{s}\n", .{status.detail});
                return error.ProjectJobFailed;
            },
            else => try std.Io.sleep(process.io, .fromMilliseconds(100), .awake),
        }
    }
}

test "export scene must be an existing scene in project resources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "resources/scene");
    try tmp.dir.writeFile(io, .{ .sub_path = "resources/scene/main.scene.zon", .data = ".{}" });
    try validateScene(io, tmp.dir, "resources/scene/main.scene.zon");
    try std.testing.expectError(error.FileNotFound, validateScene(io, tmp.dir, "resources/missing.scene.zon"));
    try std.testing.expectError(error.InvalidScenePath, validateScene(io, tmp.dir, "/outside.scene.zon"));
    try std.testing.expectError(error.InvalidScenePath, validateScene(io, tmp.dir, "resources/../outside.scene.zon"));
    try std.testing.expectError(error.InvalidScenePath, validateScene(io, tmp.dir, "src/main.zig"));
}
