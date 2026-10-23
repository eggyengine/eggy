//! The plugins inside Eggy (`plugins/<folder>/`, each a `root.zig`, an `eggy.zon` manifest and a
//! `README.md`), which projects install from the editor's Plugins window: published as modules,
//! and their manifests and read-mes embedded in the editor, which lists them.
const std = @import("std");
const package_root = @import("package_root.zig");
const plugin_manifest = @import("../core/plugin_manifest.zig");

const folder = "plugins";

/// Publish each plugin in `plugins/` as the module its manifest names, importing `eggy`. Returns
/// them, for tests. A plugin folder without a valid manifest fails configuration, naming it.
///
/// ```zig
/// for (builtin_plugins.publish(b, target, optimize, engine)) |plugin| test_step.dependOn(...);
/// ```
pub fn publish(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, eggy: *std.Build.Module) []const *std.Build.Module {
    var modules: std.ArrayList(*std.Build.Module) = .empty;
    for (list(b)) |plugin| {
        const module = b.addModule(plugin.manifest.module, .{
            .root_source_file = b.path(b.pathJoin(&.{ folder, plugin.folder, "root.zig" })),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "eggy", .module = eggy }},
        });
        modules.append(b.allocator, module) catch @panic("OOM");
    }
    return modules.items;
}

/// A module for the editor listing every plugin's folder name, manifest and read-me (null without
/// one), embedded: `pub const all: []const Builtin`.
pub fn embedded(b: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    var source: std.ArrayList(u8) = .empty;
    source.appendSlice(b.allocator,
        \\pub const Builtin = struct { folder: []const u8, manifest: [:0]const u8, readme: ?[]const u8 };
        \\pub const all = [_]Builtin{
        \\
    ) catch @panic("OOM");
    for (list(b)) |plugin| {
        const zon = b.pathJoin(&.{ plugin.folder, "eggy.zon" });
        _ = files.addCopyFile(b.path(b.pathJoin(&.{ folder, zon })), zon);
        source.print(b.allocator, "    .{{ .folder = \"{f}\", .manifest = @embedFile(\"{f}\"), .readme = ", .{ std.zig.fmtString(plugin.folder), std.zig.fmtString(zon) }) catch @panic("OOM");
        const readme = b.pathJoin(&.{ plugin.folder, plugin.manifest.readme });
        if (package_root.open(b).access(b.graph.io, b.pathJoin(&.{ folder, readme }), .{})) {
            _ = files.addCopyFile(b.path(b.pathJoin(&.{ folder, readme })), readme);
            source.print(b.allocator, "@embedFile(\"{f}\") }},\n", .{std.zig.fmtString(readme)}) catch @panic("OOM");
        } else |_| source.appendSlice(b.allocator, "null },\n") catch @panic("OOM");
    }
    source.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    return b.createModule(.{ .root_source_file = files.add("builtin_plugins.zig", source.items) });
}

const Listed = struct { folder: []const u8, manifest: plugin_manifest.Manifest };

/// Every plugin folder in `plugins/`, by name, with its manifest.
fn list(b: *std.Build) []const Listed {
    const io = b.graph.io;
    var dir = package_root.open(b).openDir(io, folder, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var plugins: std.ArrayList(Listed) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const path = b.pathJoin(&.{ folder, entry.name, "eggy.zon" });
        const source = package_root.open(b).readFileAllocOptions(io, path, b.allocator, .limited(1 << 20), .of(u8), 0) catch |err| std.debug.panic("cannot read {s}: {t}", .{ path, err });
        const manifest = plugin_manifest.parse(b.allocator, source) catch |err| std.debug.panic("{s} is not a plugin manifest: {t}", .{ path, err });
        plugins.append(b.allocator, .{ .folder = b.dupe(entry.name), .manifest = manifest }) catch @panic("OOM");
    }
    std.mem.sort(Listed, plugins.items, {}, struct {
        fn lessThan(_: void, a: Listed, c: Listed) bool {
            return std.mem.lessThan(u8, a.folder, c.folder);
        }
    }.lessThan);
    return plugins.items;
}
