//! The plugins a project installed, as its `eggy.zon` lists them: the entry a read plugin gets,
//! whether one may replace an installed one, and writing the list as a change to undo.
const std = @import("std");
const eggy = @import("eggy");
const build_options = @import("build_options");
const Fetched = @import("fetch.zig").Fetched;
const Installed = eggy.plugin_manifest.Installed;
const Manifest = eggy.plugin_manifest.Manifest;

/// A file's text before and after a change.
pub const Texts = eggy.Action([]u8);

/// An install, update or uninstall, owned by whoever takes it: `eggy.zon`'s texts, and
/// `build.zig.zon`'s when the plugin's package came, changed or went too. A step to undo.
pub const Change = struct { project: Texts, package: ?Texts = null };

/// Free `change`'s texts.
pub fn freeChange(gpa: std.mem.Allocator, change: Change) void {
    for ([_]?Texts{ change.project, change.package }) |maybe| if (maybe) |texts| {
        gpa.free(texts.before);
        gpa.free(texts.after);
    };
}

/// The entry `fetched` is listed with once installed, borrowing its strings. `embedded`: it is
/// one of the plugins this Eggy ships, read from no address.
pub fn entryFor(fetched: *const Fetched, embedded: bool) Installed {
    const manifest = fetched.manifest;
    return .{
        .module = manifest.module,
        .dependency = if (fetched.package == .fetch) fetched.package.fetch.dependency else null,
        .version = manifest.version,
        .dev = manifest.dev,
        .source = if (embedded) "" else fetched.origin.text(),
        .repository = manifest.repository,
        .fingerprint = manifest.fingerprint,
    };
}

/// Why `manifest` can't replace the installed `installed`, for people; null when it can: an
/// update must be the same package from the same place.
pub fn replacementProblem(installed: Installed, manifest: Manifest) ?[]const u8 {
    if (installed.fingerprint) |known| if (known != manifest.fingerprint) return "This plugin's fingerprint isn't the installed one's: it is a different package under the same name. Uninstall the installed one first if you mean to replace it.";
    if (installed.repository.len > 0 and !std.mem.eql(u8, installed.repository, manifest.repository)) return "This plugin names another repository than the installed one. Uninstall the installed one first if you mean to replace it.";
    return null;
}

/// Whether `manifest` needs a newer Eggy than this one.
pub fn needsNewerEggy(manifest: Manifest) bool {
    const minimum = manifest.minimum_eggy_version orelse return false;
    return eggy.plugin_manifest.compareVersions(minimum, build_options.version) == .gt;
}

/// Write the `eggy.zon` of the project in `project_dir` with `module`'s entry replaced by `entry`
/// (added if it has none, or removed when null); returns its texts, owned with `gpa`.
pub fn rewrite(gpa: std.mem.Allocator, project_dir: []const u8, module: []const u8, entry: ?Installed) !Texts {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, project_dir, .{});
    defer dir.close(io);
    const before = try dir.readFileAllocOptions(io, eggy.project.file_name, arena, .limited(1 << 20), .of(u8), 0);
    var config = try eggy.project.parse(arena, before);

    var plugins: std.ArrayList(Installed) = .empty;
    var replaced = false;
    for (config.plugins) |installed| {
        if (!std.mem.eql(u8, installed.module, module)) {
            try plugins.append(arena, installed);
        } else if (entry) |new| {
            try plugins.append(arena, new);
            replaced = true;
        }
    }
    if (entry != null and !replaced) try plugins.append(arena, entry.?);
    config.plugins = plugins.items;

    var after: std.Io.Writer.Allocating = .init(arena);
    try eggy.project.write(&after.writer, config);
    try dir.writeFile(io, .{ .sub_path = eggy.project.file_name, .data = after.written() });
    const before_copy = try gpa.dupe(u8, before);
    errdefer gpa.free(before_copy);
    return .{ .before = before_copy, .after = try gpa.dupe(u8, after.written()) };
}

/// The text of the project's `build.zig.zon`, owned with `gpa`; read before and after `zig fetch
/// --save` changes it, so the change can be undone.
pub fn readPackageFile(gpa: std.mem.Allocator, project_dir: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, project_dir, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, "build.zig.zon", gpa, .limited(1 << 20));
}

/// `before` (owned) and the project's `build.zig.zon` now as a change, or null (freeing `before`)
/// when it is the same.
pub fn packageChange(gpa: std.mem.Allocator, project_dir: []const u8, before: []u8) !?Texts {
    errdefer gpa.free(before);
    const after = try readPackageFile(gpa, project_dir);
    if (std.mem.eql(u8, before, after)) {
        gpa.free(before);
        gpa.free(after);
        return null;
    }
    return .{ .before = before, .after = after };
}

test "an update from another repository or package is refused" {
    const installed = Installed{ .module = "stats", .repository = "https://github.com/me/stats", .fingerprint = 1 };
    var manifest = Manifest{ .title = "Stats", .module = "stats", .version = "2.0.0", .repository = "https://github.com/me/stats", .fingerprint = 1 };
    try std.testing.expect(replacementProblem(installed, manifest) == null);
    manifest.fingerprint = 2;
    try std.testing.expect(replacementProblem(installed, manifest) != null);
    manifest.fingerprint = 1;
    manifest.repository = "https://github.com/mallory/stats";
    try std.testing.expect(replacementProblem(installed, manifest) != null);
}
