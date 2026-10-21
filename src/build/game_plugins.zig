//! The plugins a game is built with: those its `build.zig` lists (`GameOptions.plugins`, then
//! `dev_plugins`), then those installed from the editor's Plugins window (its `eggy.zon`'s
//! `.plugins`): each a module of Eggy's own (`plugins/`) or of a dependency in `build.zig.zon`.
const std = @import("std");
const project = @import("../core/project.zig");

pub const Plugin = struct {
    module: *std.Build.Module,
    /// Left out of exported games (`-Ddev-plugins=false`).
    dev: bool,
};

/// Every plugin the game `b` lists or installed, in that order, in `b`'s arena; null while an
/// installed plugin's package is not fetched yet (Zig fetches it and runs the build again).
/// `engine` is Eggy's builder, which publishes the plugins inside Eggy. An installed plugin whose
/// module can't be found fails the build, naming it.
///
/// ```zig
/// const plugins = game_plugins.collect(b, engine, target, optimize, options.plugins, options.dev_plugins) orelse return null;
/// ```
pub fn collect(b: *std.Build, engine: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, listed: []const *std.Build.Module, dev_listed: []const *std.Build.Module) ?[]const Plugin {
    var plugins: std.ArrayList(Plugin) = .empty;
    for (listed) |module| plugins.append(b.allocator, .{ .module = module, .dev = false }) catch @panic("OOM");
    for (dev_listed) |module| plugins.append(b.allocator, .{ .module = module, .dev = true }) catch @panic("OOM");
    for (installed(b)) |entry| {
        const module = if (entry.dependency) |name| blk: {
            const dependency = b.lazyDependency(name, .{ .target = target, .optimize = optimize }) orelse return null;
            break :blk dependency.builder.modules.get(entry.module);
        } else engine.modules.get(entry.module);
        plugins.append(b.allocator, .{
            .module = module orelse std.debug.panic("eggy.zon installs plugin {s}, which {s} doesn't publish", .{ entry.module, entry.dependency orelse "Eggy" }),
            .dev = entry.dev,
        }) catch @panic("OOM");
    }
    return plugins.items;
}

/// The plugins `eggy.zon` lists as installed; none without one that reads (the build reports a
/// broken `eggy.zon` elsewhere).
fn installed(b: *std.Build) []const @import("../core/plugin_manifest.zig").Installed {
    const source = b.build_root.handle.readFileAllocOptions(b.graph.io, project.file_name, b.allocator, .limited(1 << 20), .of(u8), 0) catch return &.{};
    const config = project.parse(b.allocator, source) catch return &.{};
    return config.plugins;
}
