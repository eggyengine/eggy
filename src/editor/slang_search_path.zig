//! Lets a code editor's Slang language server resolve a project shader's `#include "eggy.slang"`:
//! Eggy's shader library written to `.eggy/shaders/eggy.slang`, and that folder
//! in VS Code's `slang.additionalSearchPaths`, which takes absolute paths only.
const std = @import("std");
const eggy = @import("eggy");

/// The folder holding the library, relative to the project.
const folder = ".eggy/shaders";
const settings_path = ".vscode/settings.json";
const setting = "slang.additionalSearchPaths";
/// The library as code editors see it: it, then what Eggy's wrappers give shaders of a role,
/// so a post pass's `sceneColor` is known too. Never compiled: builds compose the real thing.
const editor_library = eggy.shader_compose.library ++
    \\
    \\// For code editors only: what Eggy puts around a shader of each role when it builds it.
    \\
    \\// Post passes: the scene's linear HDR light at `uv` (0 to 1 from the top left), before this pass.
    \\float3 sceneColor(float2 uv) { return float3(0.0); }
    \\
;

/// Write the library into the project at `project_dir` (absolute) and, with `vscode` (VS Code,
/// VSCodium or Cursor is the chosen code editor), add its folder to the workspace's Slang search
/// paths. Failures are logged: a missing include in the code editor isn't worth stopping for.
pub fn provide(gpa: std.mem.Allocator, io: std.Io, project_dir: []const u8, vscode: bool) void {
    var project = std.Io.Dir.cwd().openDir(io, project_dir, .{}) catch return;
    defer project.close(io);
    writeLibrary(io, project) catch |err| return std.log.warn("cannot write Eggy's shader library for code editors: {t}", .{err});
    if (!vscode) return;
    const library_dir = std.fs.path.join(gpa, &.{ project_dir, folder }) catch return;
    defer gpa.free(library_dir);
    addToSettings(gpa, io, project, library_dir) catch |err| std.log.warn("cannot add {s} to {s}'s {s}: {t}; add it by hand for Slang to find #include \"eggy.slang\"", .{ library_dir, settings_path, setting, err });
}

/// Write the library unless it is already there as this Eggy has it.
fn writeLibrary(io: std.Io, project: std.Io.Dir) !void {
    const path = folder ++ "/eggy.slang";
    // The bare `eggy` an earlier editor wrote here.
    project.deleteFile(io, folder ++ "/eggy") catch {};
    var buffer: [64 << 10]u8 = undefined;
    if (project.readFile(io, path, &buffer)) |current| {
        if (std.mem.eql(u8, current, editor_library)) return;
    } else |_| {}
    try project.createDirPath(io, folder);
    try project.writeFile(io, .{ .sub_path = path, .data = editor_library });
}

/// Add `library_dir` to `.vscode/settings.json`'s search paths, writing it only if that changes it.
fn addToSettings(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir, library_dir: []const u8) !void {
    const current = project.readFileAlloc(io, settings_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (current) |text| gpa.free(text);
    const updated = try withSearchPath(gpa, current, library_dir) orelse return;
    defer gpa.free(updated);
    try project.createDirPath(io, ".vscode");
    try project.writeFile(io, .{ .sub_path = settings_path, .data = updated });
}

/// `settings` (null: no file yet) with `path` among its Slang search paths, other settings kept;
/// null when it is already there. Fails with `InvalidSettings` when it isn't a JSON object (VS
/// Code allows comments, which this doesn't read). The caller owns the result.
fn withSearchPath(gpa: std.mem.Allocator, settings: ?[]const u8, path: []const u8) !?[]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var root: std.json.Value = if (settings) |text|
        std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return error.InvalidSettings
    else
        .{ .object = .empty };
    if (root != .object) return error.InvalidSettings;
    const entry = try root.object.getOrPut(a, setting);
    if (!entry.found_existing) entry.value_ptr.* = .{ .array = .init(a) };
    if (entry.value_ptr.* != .array) return error.InvalidSettings;
    for (entry.value_ptr.array.items) |item| if (item == .string and std.mem.eql(u8, item.string, path)) return null;
    try entry.value_ptr.array.append(.{ .string = path });
    const text = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_4 });
    return try gpa.dupe(u8, text);
}

test "the library's folder joins the Slang search paths once, other settings kept" {
    const gpa = std.testing.allocator;
    const added = (try withSearchPath(gpa, "{\"editor.tabSize\": 4, \"slang.additionalSearchPaths\": [\"/other\"]}", "/game/.eggy/shaders")).?;
    defer gpa.free(added);
    try std.testing.expect(std.mem.indexOf(u8, added, "\"editor.tabSize\": 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, added, "\"/other\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, added, "\"/game/.eggy/shaders\"") != null);
    try std.testing.expect(try withSearchPath(gpa, added, "/game/.eggy/shaders") == null);

    // No settings yet: made; settings with comments are left alone.
    const fresh = (try withSearchPath(gpa, null, "/game/.eggy/shaders")).?;
    defer gpa.free(fresh);
    try std.testing.expect(std.mem.indexOf(u8, fresh, setting) != null);
    try std.testing.expectError(error.InvalidSettings, withSearchPath(gpa, "// mine\n{}", "/game/.eggy/shaders"));
}
