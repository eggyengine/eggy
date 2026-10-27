//! miniaudio (with stb_vorbis for Ogg), built as the static C library behind `eggy`'s mixer
//! (`src/core/audio/mixer.c`).
const std = @import("std");
const c_libraries = @import("c_libraries.zig");
const mingw_fortify = @import("mingw_fortify.zig");

/// The mixer library for `target`, to link into `eggy`. `web_include` is Emscripten's headers on
/// the web, null elsewhere. Both the editor and the game library it loads link a copy.
///
/// ```zig
/// engine.linkLibrary(audio.addMixer(b, target, optimize, null));
/// ```
pub fn addMixer(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, web_include: ?std.Build.LazyPath) *std.Build.Step.Compile {
    const miniaudio = b.dependency("miniaudio", .{});
    const library = b.addLibrary(.{
        .name = "eggy_mixer",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = c_libraries.optimize(optimize),
            .link_libc = true,
            // Linked into the editor's game library, a shared one.
            .pic = if (web_include == null) true else null,
        }),
    });
    library.root_module.addIncludePath(miniaudio.path(""));
    if (web_include) |include| library.root_module.addSystemIncludePath(include);
    library.root_module.addCSourceFile(.{ .file = b.path("src/core/audio/mixer.c"), .flags = &.{"-fno-sanitize=undefined"} });
    mingw_fortify.disable(library.root_module, target, optimize);
    return library;
}
