const std = @import("std");

/// Builds Slang from the `slangc` package via CMake (upstream docs/building.md).
///
/// When cross-compiling, host generators are built first and supplied through
/// `SLANG_GENERATORS_PATH`; the target libraries are compiled with `zig cc/c++`.
pub const Artifacts = struct {
    step: *std.Build.Step,
    prefix: std.Build.LazyPath,

    pub fn bin(self: Artifacts, b: *std.Build) std.Build.LazyPath {
        return self.prefix.path(b, "bin");
    }

    pub fn lib(self: Artifacts, b: *std.Build) std.Build.LazyPath {
        return self.prefix.path(b, "lib");
    }

    pub fn include(self: Artifacts, b: *std.Build) std.Build.LazyPath {
        return self.prefix.path(b, "include");
    }
};

pub const Options = struct {
    /// Upstream Slang package from `b.dependency("slangc", .{})` (fetched/hashed).
    source: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn add(b: *std.Build, options: Options) Artifacts {
    // Keep the zon package in the graph so fetches/hashes stay authoritative.
    _ = options.source;

    const cross: u1 = if (options.target.query.isNative()) 0 else 1;
    const triple = b.fmt("{s}-{s}-{s}", .{
        @tagName(options.target.result.cpu.arch),
        @tagName(options.target.result.os.tag),
        @tagName(options.target.result.abi),
    });
    const config = cmakeConfig(options.optimize);

    const src_dir = b.cache_root.join(b.allocator, &.{ "slang-src", "v2026.14.1" }) catch @panic("OOM");
    const build_dir = b.cache_root.join(b.allocator, &.{ "slang-cmake", triple }) catch @panic("OOM");
    const prefix_dir = b.cache_root.join(b.allocator, &.{ "slang-prefix", triple }) catch @panic("OOM");
    const generators_dir = b.cache_root.join(b.allocator, &.{"slang-generators"}) catch @panic("OOM");

    const build_slang = b.addSystemCommand(&.{ "cmake", "-P" });
    build_slang.addFileArg(b.path("build/slang_build.cmake"));
    build_slang.addArgs(&.{
        src_dir,
        "v2026.14.1",
        build_dir,
        prefix_dir,
        config,
        triple,
        if (cross == 1) "1" else "0",
        generators_dir,
        b.graph.zig_exe,
    });
    build_slang.has_side_effects = true;

    return .{
        .step = &build_slang.step,
        .prefix = .{ .cwd_relative = prefix_dir },
    };
}

fn cmakeConfig(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        // Slang as a linked compiler dependency: prefer Release for native Debug
        // app builds too — a Debug Slang rebuild is disproportionately expensive.
        .Debug, .ReleaseSafe, .ReleaseFast => "Release",
        .ReleaseSmall => "MinSizeRel",
    };
}
