//! One SDL instance shared by desktop executables and their hot-loaded game libraries.
const std = @import("std");
const c_libraries = @import("c_libraries.zig");

/// Where a game's `-Dmacos-sdk` is kept for Eggy's own build, in the build graph's environment:
/// options reach only the root build, and SDL is configured inside Eggy's.
pub const macos_sdk_variable = "EGGY_MACOS_SDK";

/// Desktop SDL is dynamic, packaged under its loader name; the web stays statically linked.
/// Null until SDL's lazy C dependency has been fetched.
/// Build-internal: `b` owns the dependency and named runtime-library paths.
/// `web_include` must be Emscripten's headers on web, null on supported desktop targets.
/// All editor/game modules must reuse this dependency to avoid separate SDL subsystem state.
///
/// ```zig
/// const dep = sdl_build.dependency(b, target, optimize, null) orelse return;
/// app_module.addImport("sdl3", dep.module("sdl3"));
/// ```
pub fn dependency(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, web_include: ?std.Build.LazyPath) ?*std.Build.Dependency {
    // ponytail: SDL 3.4.0's Wayland pointer-leave shifts by -1; restore C UB traps after an SDL bump.
    if (web_include) |include| return b.dependency("sdl3", .{ .target = target, .optimize = c_libraries.optimize(optimize), .c_sdl_sanitize_c = .off, .sdl_system_include_path = include });
    // SDL needs the SDK's headers, frameworks and libraries named to build for macOS elsewhere.
    const macos_sdk = if (target.result.os.tag == .macos and !target.query.isNativeOs()) b.graph.environ_map.get(macos_sdk_variable) else null;
    const dep = if (macos_sdk) |sdk| b.dependency("sdl3", .{
        .target = target,
        .optimize = c_libraries.optimize(optimize),
        .c_sdl_sanitize_c = .off,
        .c_sdl_preferred_linkage = .dynamic,
        .sdl_system_include_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) },
        .sdl_system_framework_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) },
        .sdl_library_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) },
    }) else b.dependency("sdl3", .{ .target = target, .optimize = c_libraries.optimize(optimize), .c_sdl_sanitize_c = .off, .c_sdl_preferred_linkage = .dynamic });
    const module = dep.module("sdl3");
    switch (target.result.os.tag) {
        .linux => module.addRPathSpecial("$ORIGIN/../lib"),
        .macos => module.addRPathSpecial("@loader_path/../lib"),
        .windows => {},
        else => unreachable,
    }
    for (module.link_objects.items) |object| {
        if (object != .other_step) continue;
        const library = object.other_step;
        if (!std.mem.eql(u8, library.name, "SDL3") or library.linkage != .dynamic) continue;
        // The loader asks for the soname, which keeps only the major version.
        const major = if (library.version) |version| version.major else null;
        const name = if (major == null) library.out_filename else switch (target.result.os.tag) {
            .linux => b.fmt("lib{s}.so.{d}", .{ library.name, major.? }),
            .macos => b.fmt("lib{s}.{d}.dylib", .{ library.name, major.? }),
            else => library.out_filename,
        };
        if (target.result.os.tag == .macos) library.install_name = b.fmt("@rpath/{s}", .{name});
        const folder = if (target.result.os.tag == .windows) "bin" else "lib";
        b.addNamedLazyPath(b.fmt("runtime:{s}/{s}", .{ folder, name }), library.getEmittedBin());
        return dep;
    }
    return null;
}
