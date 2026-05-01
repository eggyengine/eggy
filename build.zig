const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .c_sdl_preferred_linkage = .static,
        .ext_image = true,
        // .image_enable_bmp = true,
        // .image_enable_gif = true,
        // .image_enable_jpg = true,
        // .image_enable_lbm = true,
        // .image_enable_pcx = true,
        // .image_enable_png = true,
        // .image_enable_pnm = true,
        // .image_enable_qoi = true,
        // .image_enable_svg = true,
        // .image_enable_tga = true,
        // .image_enable_xcf = true,
        // .image_enable_xpm = true,
        // .image_enable_xv = true,
    });

    const vulkan = b.dependency("vulkan", .{
        .registry = b.path("deps/vk.xml"),
    }).module("vulkan-zig");

    const teenygltf = b.dependency("teenygltf", .{
        .target = target,
        .optimize = optimize,
    });

    const emath = b.dependency("eggenvector", .{
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
    eggy_module.addImport("teenygltf", teenygltf.module("teenygltf"));
    eggy_module.addImport("eggenvector", emath.module("eggenvector"));

    const tests = b.addTest(.{
        .root_module = eggy_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run eggy unit tests");
    test_step.dependOn(&run_tests.step);

    const run_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "run" });
    run_cmd.setCwd(b.path("demo"));
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Build and run the demo");
    run_step.dependOn(&run_cmd.step);
}
