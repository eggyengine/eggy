//! A game's shaders compiled at build time for its packaged data: each project `.slang` made
//! whole by Eggy's composer (`src/core/shaders/compose.zig`), then compiled by slangc for the
//! target (WGSL on the web, SPIR-V elsewhere) and packaged as `<id>.frag` beside the copied source.
const std = @import("std");
const vitellus_build = @import("vitellus");
const asset_id = @import("../core/assets/id.zig");
const package = @import("../core/assets/package.zig");

/// `data` with every `.shader` among `files` compiled beside it; `data` itself when there are
/// none. `engine` is Eggy's builder and `vitellus` its Vitellus. Null until Slang is fetched.
pub fn addCompiled(b: *std.Build, engine: *std.Build, vitellus: *std.Build.Dependency, target: std.Build.ResolvedTarget, files: []const package.Entry, data: std.Build.LazyPath) ?std.Build.LazyPath {
    const any = for (files) |entry| {
        if (entry.kind == .shader) break true;
    } else false;
    if (!any) return data;

    const composer = engine.addExecutable(.{
        .name = "eggy_compose_shader",
        .root_module = engine.createModule(.{
            .root_source_file = engine.path("src/core/shaders/compose_tool.zig"),
            .target = engine.graph.host,
        }),
    });
    const output = b.addWriteFiles();
    _ = output.addCopyDirectory(data, "", .{});
    for (files) |entry| {
        if (entry.kind != .shader) continue;
        // Made whole, then compiled for its one entry point.
        const compose = b.addRunArtifact(composer);
        compose.addFileArg(b.path(entry.path));
        compose.addArg(std.fs.path.basename(entry.path));
        const whole = compose.addOutputFileArg("shader.slang");
        const compiled = vitellus_build.compileSlang(b, vitellus, target, whole, "fragmentMain", .fragment) orelse return null;
        var key: [asset_id.key_len]u8 = undefined;
        _ = output.addCopyFile(compiled, b.fmt("{s}.frag", .{asset_id.key(&key, entry.id)}));
    }
    return output.getDirectory();
}
