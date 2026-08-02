const std = @import("std");
const slang_build = @import("build/slang.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const slangc_dep = b.dependency("slangc", .{});
    const slang = slang_build.add(b, .{
        .source = slangc_dep.path(""),
        .target = target,
        .optimize = optimize,
    });

    const slang_bin = slang.bin(b);
    const slang_lib = slang.lib(b);
    const slang_include = slang.include(b);

    const install_slang = b.addInstallDirectory(.{
        .source_dir = slang_bin,
        .install_dir = .bin,
        .install_subdir = "",
    });
    install_slang.step.dependOn(slang.step);
    b.getInstallStep().dependOn(&install_slang.step);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addIncludePath(slang_include);
    exe_mod.addLibraryPath(slang_lib);
    exe_mod.linkSystemLibrary("slang", .{});
    if (target.result.os.tag != .windows) {
        exe_mod.addRPath(slang_lib);
    }

    // vitellus
    {
        const vitellus = b.dependency("vitellus", .{
            .target = target,
            .optimize = optimize,
        });

        exe_mod.addImport("vitellus", vitellus.module("vitellus"));
    }

    // sdl3
    {
        const sdl3 = b.dependency("sdl3", .{
            .target = target,
            .optimize = optimize,
        });

        exe_mod.addImport("sdl3", sdl3.module("sdl3"));
    }

    // zigimg
    {
        const zigimg_dependency = b.lazyDependency("zigimg", .{
            .target = target,
            .optimize = optimize,
        });

        if (zigimg_dependency) |dep| exe_mod.addImport("zigimg", dep.module("zigimg"));
    }

    // eggenvector
    {
        const emath = b.dependency("eggenvector", .{
            .target = target,
            .optimize = optimize,
        });

        exe_mod.addImport("eggenvector", emath.module("eggenvector"));
    }

    // check step
    // required by zls
    {
        const exe_check = b.addExecutable(.{
            .name = "eggy",
            .root_module = exe_mod,
        });
        exe_check.step.dependOn(slang.step);
        const check = b.step("check", "Check if eggy compiles");
        check.dependOn(&exe_check.step);
    }

    // run step
    {
        const exe = b.addExecutable(.{
            .name = "eggy",
            .root_module = exe_mod,
        });
        exe.step.dependOn(slang.step);

        b.installArtifact(exe);
        const run_step = b.step("run", "Run the app");

        const run_cmd = b.addRunArtifact(exe);
        // Shared libs are installed beside the exe; also keep the build prefix
        // on the loader path for uninstalled `zig build run`.
        run_cmd.addPathDir(slang_bin.getPath(b));
        run_step.dependOn(&run_cmd.step);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    // tests
    {
        const test_runner: std.Build.Step.Compile.TestRunner = .{
            .path = .{ .cwd_relative = b.graph.zig_lib_directory.join(
                b.allocator,
                &.{ "compiler", "test_runner.zig" },
            ) catch @panic("OOM") },
            .mode = .simple,
        };
        const mod_tests = b.addTest(.{
            .root_module = exe_mod,
            .test_runner = test_runner,
        });
        mod_tests.step.dependOn(slang.step);

        const run_mod_tests = b.addRunArtifact(mod_tests);
        run_mod_tests.addPathDir(slang_bin.getPath(b));

        const exe_tests = b.addTest(.{
            .root_module = exe_mod,
            .test_runner = test_runner,
        });
        exe_tests.step.dependOn(slang.step);

        const run_exe_tests = b.addRunArtifact(exe_tests);
        run_exe_tests.addPathDir(slang_bin.getPath(b));

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
        test_step.dependOn(&run_exe_tests.step);
    }

    const slang_step = b.step("slang", "Build Slang from source");
    slang_step.dependOn(slang.step);
}
