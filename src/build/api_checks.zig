//! The headless game project used to exercise the real hot-reload API.
const std = @import("std");

/// Build-internal: create the graph-owned project module for the headless hot-reload fixture.
/// `eggy` must be the same engine module as the test host, so ABI pointers/types match.
/// Generates source in the build cache; does not load a game or run the tests itself.
///
/// ```zig
/// const fixture = api_checks.project(b, target, optimize, engine_module);
/// game_library.root_module.addImport("eggy_project", fixture);
/// ```
pub fn project(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, eggy: *std.Build.Module) *std.Build.Module {
    const game = b.createModule(.{
        .root_source_file = b.path("src/editor/hot_reload/fixture.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "eggy", .module = eggy }},
    });
    return b.createModule(.{
        .root_source_file = b.addWriteFiles().add("test_project.zig",
            \\pub const plugins = .{ @import("fixture").Game };
            \\pub const plugin_keys = [_][:0]const u8{"game"};
            \\
        ),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fixture", .module = game }},
    });
}
