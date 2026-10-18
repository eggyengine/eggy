//! Link the browser runtime with the same packaged data desktop and Android games use.
const std = @import("std");
const resources = @import("resources.zig");
const manifest = @import("../core/assets/manifest.zig");

/// Attach lazy packaged assets to Vitellus's Emscripten link step before installing its page.
pub fn addApp(b: *std.Build, engine: *std.Build, emscripten: anytype, root: *std.Build.Module, name: []const u8, files: []const manifest.Entry) @TypeOf(emscripten).App {
    const app = emscripten.addApp(b, .{ .name = name, .root_module = root });
    const link: *std.Build.Step.Run = @fieldParentPtr("step", app.install.options.source_dir.generated.file.step);
    const bundled = resources.bundledDirectory(b, engine, root.optimize orelse .Debug, files);
    link.addArg("--preload-file");
    link.addDecoratedDirectoryArg("", bundled.path(b, "data"), "@/data");
    b.step("run-runtime", "Open the game in a browser").dependOn(&app.run.step);
    return app;
}
