const std = @import("std");
const eggy = @import("eggy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The plugin (`src/root.zig`): reusable code other eggy packages can depend on. Delete this,
    // and its uses below, if the package is only a game.
    const plugin = eggy.addPlugin(b, .{
        .name = "eggy_template_name",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The game (`src/main.zig`), running the plugin. Delete this if the package is only a plugin.
    // Adds `zig build run` (the editor), `run-runtime`, `all`, `runtime` and `editor`.
    eggy.addGame(b, .{
        .name = "eggy_template_name",
        .game = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "eggy_template_name", .module = plugin }},
        }),
        .plugins = &.{plugin},
        .target = target,
        .optimize = optimize,
    });

    // LLVM links the tests: Zig's own linker rejects the .sframe sections in newer glibc.
    const test_step = b.step("test", "Run the plugin's tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = plugin, .use_llvm = true })).step);
}
