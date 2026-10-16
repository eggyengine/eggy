//! `zig build export`: a game ready to ship, for `-Dtarget` (by default, this machine's system
//! on any CPU of its kind), starting in the scene chosen for it (`-Dscene`, else the default).
//! It builds the runtime again in ReleaseFast, with everything it needs (its shaders, compiled
//! in; its libraries; its resources, packaged), into `<prefix>/export/<name>-<target>/`, and
//! zips that folder beside it. The build runs as a nested `zig build runtime` (this build's
//! runner, started directly so its steps show under this one: see `runner.zig`), so the export
//! never shares a compilation with the debug build.
const std = @import("std");
const runner = @import("runner.zig");

/// Add the `export` step to `b` for the game `name` on `target`, starting in `scene` (`-Dscene`
/// or `eggy.zon`'s `.default_scene`; without one the step fails, asking for one), with Eggy's
/// builder `engine` (for the zip tool).
pub fn addExport(b: *std.Build, engine: *std.Build, target: std.Build.ResolvedTarget, name: []const u8, scene: ?[]const u8) void {
    const step = b.step("export", "Build the game to ship for -Dtarget, as fast as it runs, into export/");
    const start = scene orelse {
        step.dependOn(&b.addFail("export needs the scene the game starts in: set the default scene in Project Settings (eggy.zon's .default_scene), or pass -Dscene=<path>").step);
        return;
    };
    const result = target.result;
    const triple = b.fmt("{t}-{t}-{t}", .{ result.cpu.arch, result.os.tag, result.abi });
    const folder = b.fmt("{s}-{s}", .{ name, triple });

    // The runtime and all it needs, as fast as it runs. This machine's system stays `native`, so
    // its own libraries (GTK, for the error dialog) are found; the CPU is any of its kind unless
    // one is asked for, so the game runs on other machines too.
    const asked = if (target.query.isNativeOs() and target.query.isNativeAbi() and target.query.cpu_arch == null) "native" else target.query.zigTriple(b.allocator) catch @panic("OOM");
    const nested = b.addSystemCommand(runner.argv(b));
    nested.addArgs(&.{ "runtime", "-Doptimize=ReleaseFast", b.fmt("-Dtarget={s}", .{asked}), b.fmt("-Dscene={s}", .{start}), "--color", "off", "--summary", "all" });
    nested.addArg(switch (target.query.cpu_model) {
        .explicit => |model| b.fmt("-Dcpu={s}", .{model.name}),
        else => "-Dcpu=baseline",
    });
    nested.setCwd(b.path("."));
    nested.addArg("--prefix");
    const built = nested.addOutputDirectoryArg(folder);
    // Its output captured (shown if it fails), as only then does its progress come through;
    // run every time, as the nested build has its own cache and knows when its sources changed.
    nested.expectExitCode(0);
    nested.has_side_effects = true;
    nested.setName(b.fmt("zig build runtime for {s} (ReleaseFast)", .{triple}));

    // The folder, zipped to hand out.
    const zip_tool = b.addExecutable(.{
        .name = "eggy_zip",
        .root_module = engine.createModule(.{ .root_source_file = engine.path("src/build/zip.zig"), .target = engine.graph.host, .optimize = .ReleaseFast }),
    });
    const zip = b.addRunArtifact(zip_tool);
    const archive = zip.addOutputFileArg(b.fmt("{s}.zip", .{folder}));
    zip.addDirectoryArg(built);
    zip.addArg(folder);
    zip.setName(b.fmt("zip {s}", .{folder}));

    step.dependOn(&b.addInstallDirectory(.{ .source_dir = built, .install_dir = .prefix, .install_subdir = b.fmt("export/{s}", .{folder}) }).step);
    step.dependOn(&b.addInstallFileWithDir(archive, .prefix, b.fmt("export/{s}.zip", .{folder})).step);
}
