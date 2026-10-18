//! One SDL instance shared by desktop executables and their hot-loaded game libraries.
const std = @import("std");

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
pub fn dependency(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, web_include: ?std.Build.LazyPath) ?*std.Build.Dependency {
    // ponytail: SDL 3.4.0's Wayland pointer-leave shifts by -1; restore C UB traps after an SDL bump.
    if (web_include) |include| return b.dependency("sdl3", .{ .target = target, .optimize = optimize, .c_sdl_sanitize_c = .off, .sdl_system_include_path = include });
    const dep = b.dependency("sdl3", .{ .target = target, .optimize = optimize, .c_sdl_sanitize_c = .off, .c_sdl_preferred_linkage = .dynamic });
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
        const name = library.major_only_filename orelse library.out_filename;
        if (target.result.os.tag == .macos) library.install_name = b.fmt("@rpath/{s}", .{name});
        const folder = if (target.result.os.tag == .windows) "bin" else "lib";
        b.addNamedLazyPath(b.fmt("runtime:{s}/{s}", .{ folder, name }), library.getEmittedBin());
        return dep;
    }
    return null;
}
