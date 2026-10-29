//! The plugins a game is built with: those its `build.zig` lists (`GameOptions.plugins`, then
//! `dev_plugins`), then those installed from the editor's Plugins window (its `eggy.zon`'s
//! `.plugins`): each a module of Eggy's own (`plugins/`) or of a dependency in `build.zig.zon`.
const std = @import("std");
const package_root = @import("package_root.zig");
const project = @import("../core/project.zig");
const plugin_manifest = @import("../core/plugin_manifest.zig");

pub const Plugin = struct {
    module: *std.Build.Module,
    /// Left out of exported games (`-Ddev-plugins=false`).
    dev: bool,
    /// The modules its package publishes for the game to import, as its manifest's `libraries`
    /// names them; only for an installed plugin.
    libraries: []const Library = &.{},
};

pub const Library = struct { name: []const u8, module: *std.Build.Module };

/// Every plugin the game `b` lists or installed, in that order, in `b`'s arena; null while an
/// installed plugin's package is not fetched yet (Zig fetches it and runs the build again).
/// Without `with_dev`, installed dev plugins aren't even fetched, so a build that leaves them
/// out never configures their packages (or the Eggy they pin).
/// `engine` is Eggy's builder, which publishes the plugins inside Eggy. An installed plugin whose
/// module can't be found fails the build, naming it.
///
/// ```zig
/// const plugins = game_plugins.collect(b, engine, target, optimize, options.plugins, options.dev_plugins, true) orelse return null;
/// ```
pub fn collect(b: *std.Build, engine: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, listed: []const *std.Build.Module, dev_listed: []const *std.Build.Module, with_dev: bool) ?[]const Plugin {
    var plugins: std.ArrayList(Plugin) = .empty;
    for (listed) |module| plugins.append(b.allocator, .{ .module = module, .dev = false }) catch @panic("OOM");
    for (dev_listed) |module| plugins.append(b.allocator, .{ .module = module, .dev = true }) catch @panic("OOM");
    for (installed(b)) |entry| {
        if (entry.dev and !with_dev) continue;
        const package = if (entry.dependency) |name|
            (b.lazyDependency(name, .{ .target = target, .optimize = optimize }) orelse return null).builder
        else
            engine;
        plugins.append(b.allocator, .{
            .module = package.modules.get(entry.module) orelse std.debug.panic("eggy.zon installs plugin {s}, which {s} doesn't publish", .{ entry.module, entry.dependency orelse "Eggy" }),
            .dev = entry.dev,
            .libraries = if (entry.dependency != null) libraries(b, package, entry.module) else &.{},
        }) catch @panic("OOM");
    }
    return plugins.items;
}

/// The libraries the manifest of plugin `module` in `package` names, each a module `package`
/// publishes; none when its manifest can't be read (the editor checked it when installing).
fn libraries(b: *std.Build, package: *std.Build, module: []const u8) []const Library {
    const source = package_root.open(package).readFileAllocOptions(b.graph.io, project.file_name, b.allocator, .limited(1 << 20), .of(u8), 0) catch return &.{};
    const manifest = plugin_manifest.parse(b.allocator, source) catch return &.{};
    const found = b.allocator.alloc(Library, manifest.libraries.len) catch @panic("OOM");
    for (found, manifest.libraries) |*library, name| library.* = .{
        .name = name,
        .module = package.modules.get(name) orelse std.debug.panic("plugin {s} names library {s}, which its package doesn't publish", .{ module, name }),
    };
    return found;
}

/// The plugins `eggy.zon` lists as installed; none without one that reads (the build reports a
/// broken `eggy.zon` elsewhere).
fn installed(b: *std.Build) []const @import("../core/plugin_manifest.zig").Installed {
    const source = package_root.open(b).readFileAllocOptions(b.graph.io, project.file_name, b.allocator, .limited(1 << 20), .of(u8), 0) catch return &.{};
    const config = project.parse(b.allocator, source) catch return &.{};
    return config.plugins;
}
