//! The headless game project used to exercise the real hot-reload API.
const std = @import("std");

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
