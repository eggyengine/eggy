const std = @import("std");
const build_shaders = @import("build-shaders.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const eggy_dep = b.dependency("eggy", .{
        .target = target,
        .optimize = optimize,
    });

    const shader_step = build_shaders.addShaderBuildStep(b, eggy_dep);

    const exe = b.addExecutable(.{
        .name = "eggyengine-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe, // until zigimg is fixed
            .imports = &.{
                .{ .name = "eggy", .module = eggy_dep.module("eggy") },
            },
        }),
    });

    exe.step.dependOn(shader_step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);
}