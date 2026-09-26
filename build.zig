const std = @import("std");

pub fn build(b: *std.Build) void {
    const update_submodules = b.addSystemCommand(&.{ "git", "submodule", "update", "--init", "--remote", "--recursive" });
    b.step("update-submodules", "Update submodules to their latest remote commits").dependOn(&update_submodules.step);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const host_slang = slangDependency(b, b.graph.host.result.os.tag, b.graph.host.result.cpu.arch) orelse return;
    const target_slang = slangDependency(b, target.result.os.tag, target.result.cpu.arch) orelse return;
    const host_compiler = host_slang.path(if (b.graph.host.result.os.tag == .windows) "bin/slangc.exe" else "bin/slangc");
    const vertex_compile = b.addSystemCommand(&.{host_compiler.getPath(b)});
    vertex_compile.addFileArg(b.path("src/shaders/ui.slang"));
    vertex_compile.addArgs(&.{ "-target", "spirv", "-entry", "vertexMain", "-stage", "vertex", "-o" });
    const vertex_spv = vertex_compile.addOutputFileArg("ui.vert.spv");
    const fragment_compile = b.addSystemCommand(&.{host_compiler.getPath(b)});
    fragment_compile.addFileArg(b.path("src/shaders/ui.slang"));
    fragment_compile.addArgs(&.{ "-target", "spirv", "-entry", "fragmentMain", "-stage", "fragment", "-o" });
    const fragment_spv = fragment_compile.addOutputFileArg("ui.frag.spv");
    const shader_files = b.addWriteFiles();
    _ = shader_files.addCopyFile(vertex_spv, "ui.vert.spv");
    _ = shader_files.addCopyFile(fragment_spv, "ui.frag.spv");
    const shader_module = b.createModule(.{
        .root_source_file = shader_files.add("root.zig",
            \\pub const vertex = @embedFile("ui.vert.spv");
            \\pub const fragment = @embedFile("ui.frag.spv");
        ),
        .target = target,
        .optimize = optimize,
    });
    const library_file, const library_name = switch (target.result.os.tag) {
        .linux => .{ "lib/libslang-compiler.so.0.2026.18.2", "libslang-compiler.so" },
        .macos => .{ "lib/libslang-compiler.0.2026.18.2.dylib", "libslang-compiler.dylib" },
        .windows => .{ "bin/slang-compiler.dll", "slang-compiler.dll" },
        else => unreachable,
    };
    const library_path = target_slang.path(library_file);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(library_path, .bin, library_name).step);

    const vitellus = b.dependency("vitellus", .{
        .target = target,
        .optimize = optimize,
        .dx12 = true,
        .vk = true,
    });
    const emath = b.dependency("eggenvector", .{ .target = target, .optimize = optimize });
    const weeoui = b.dependency("weeoui", .{ .target = target, .optimize = optimize });
    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .c_sdl_preferred_linkage = .static,
    });
    const sdl_adapter = b.createModule(.{
        .root_source_file = vitellus.path("src/windowing/sdl3.zig"),
        .target = target,
        .optimize = optimize,
    });
    sdl_adapter.addImport("vitellus", vitellus.module("vitellus"));
    sdl_adapter.addImport("sdl3", sdl3.module("sdl3"));
    const slangc = b.createModule(.{
        .root_source_file = b.path("src/slangc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const slang_options = b.addOptions();
    slang_options.addOptionPath("library", library_path);
    slangc.addImport("slang_library", slang_options.createModule());

    const engine = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine.addImport("vitellus", vitellus.module("vitellus"));
    engine.addImport("eggenvector", emath.module("eggenvector"));
    engine.addImport("weeoui", weeoui.module("weeoui"));
    engine.addImport("slangc", slangc);
    engine.addImport("ui_shaders", shader_module);
    engine.addImport("sdl3", sdl3.module("sdl3"));
    engine.addImport("vitellus_sdl3", sdl_adapter);

    const exe = b.addExecutable(.{
        .name = "eggy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "eggy", .module = engine }},
        }),
        .use_llvm = true,
    });
    b.installArtifact(exe);

    const run = b.addSystemCommand(&.{b.getInstallPath(.bin, if (target.result.os.tag == .windows) "eggy.exe" else "eggy")});
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the game").dependOn(&run.step);

    const tests = b.addRunArtifact(b.addTest(.{ .root_module = engine, .use_llvm = true }));
    const slang_test_module = b.createModule(.{
        .root_source_file = b.path("src/slangc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    slang_test_module.addImport("slang_library", slang_options.createModule());
    const slang_tests = b.addRunArtifact(b.addTest(.{ .root_module = slang_test_module, .use_llvm = true }));
    const test_step = b.step("test", "Run workspace tests");
    test_step.dependOn(&tests.step);
    test_step.dependOn(&slang_tests.step);
}

fn slangDependency(b: *std.Build, os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?*std.Build.Dependency {
    const name = switch (os) {
        .linux => switch (arch) {
            .x86_64 => "slang_linux_x86_64",
            .aarch64 => "slang_linux_aarch64",
            else => @panic("Slang has no bundled release for this Linux architecture"),
        },
        .macos => switch (arch) {
            .x86_64 => "slang_macos_x86_64",
            .aarch64 => "slang_macos_aarch64",
            else => @panic("Slang has no bundled release for this macOS architecture"),
        },
        .windows => switch (arch) {
            .x86_64 => "slang_windows_x86_64",
            .aarch64 => "slang_windows_aarch64",
            else => @panic("Slang has no bundled release for this Windows architecture"),
        },
        else => @panic("Slang has no bundled release for this operating system"),
    };
    return b.lazyDependency(name, .{});
}
