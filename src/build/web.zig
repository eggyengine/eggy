//! Link the browser runtime with the same packaged data desktop and Android games use.
const std = @import("std");
const resources = @import("resources.zig");

/// Attach lazy packaged assets to Vitellus's Emscripten link step before installing its page.
pub fn addApp(b: *std.Build, engine: *std.Build, emscripten: anytype, root: *std.Build.Module, name: []const u8, data: ?std.Build.LazyPath) @TypeOf(emscripten).App {
    // Eggy's own page, the canvas filling the window, rather than Emscripten's.
    const app = emscripten.addApp(b, .{
        .name = name,
        .root_module = root,
        .shell_file = engine.path("src/build/web_shell.html"),
        // The engine's stack use, as on the desktop (8 MiB); Vitellus's 1 MiB overflows.
        .args = &.{"-sSTACK_SIZE=8388608"},
    });
    if (data) |directory| {
        const link: *std.Build.Step.Run = @fieldParentPtr("step", app.install.options.source_dir.generated.file.step);
        const bundled = resources.bundledDirectory(b, directory);
        link.addArg("--preload-file");
        link.addDecoratedDirectoryArg("", bundled.path(b, "data"), "@/data");
    }
    b.step("run-runtime", "Open the game in a browser").dependOn(&app.run.step);
    return app;
}
