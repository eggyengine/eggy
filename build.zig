const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .c_sdl_preferred_linkage = .static,
    });

    const vulkan = b.dependency("vulkan", .{
        .registry = b.path("../../deps/vk.xml"),
    }).module("vulkan-zig");

    const zigimg = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const teenygltf = b.dependency("teenygltf", .{
        .target = target,
        .optimize = optimize,
    });

    const eggy_module = b.addModule("eggy", .{
        .root_source_file = b.path("src/eggy.zig"),
        .target = target,
        .optimize = optimize,
    });

    eggy_module.addImport("vulkan", vulkan);
    eggy_module.addImport("sdl3", sdl3.module("sdl3"));
    eggy_module.addImport("zigimg", zigimg.module("zigimg"));
    eggy_module.addImport("teenygltf", teenygltf.module("teenygltf"));

    const tests = b.addTest(.{
        .root_module = eggy_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run eggy unit tests");
    test_step.dependOn(&run_tests.step);
}