//! Fast libraries: code a game or plugin needs optimized even in a Debug build, such as terrain
//! generation, compiled on its own as a ReleaseFast static library and called through `export fn`.
//! A module's own `.optimize` doesn't do it: inside a Debug compilation the module is Debug too.
const std = @import("std");
const models = @import("models.zig");

pub const Options = struct {
    /// The library's name.
    name: []const u8,
    /// Its root, whose `export fn`s the game declares as `extern fn` and calls.
    root_source_file: std.Build.LazyPath,
    /// Modules it imports by name, made for `.fast` or with no `.optimize` of their own, so they
    /// build as fast as it does.
    /// None may import `eggy`; Eggy's eggenvector is given as `eggenvector` unless named here.
    imports: []const std.Build.Module.Import = &.{},
};

/// Build `options`' library for `target`, ReleaseFast and position independent (the editor loads
/// games as shared libraries), and link it into `into`. Panics when it would import `eggy`, whose
/// engine state a second, separately compiled copy wouldn't share.
pub fn add(b: *std.Build, engine: *std.Build.Dependency, into: *std.Build.Module, target: std.Build.ResolvedTarget, options: Options) *std.Build.Step.Compile {
    const root = b.createModule(.{ .root_source_file = options.root_source_file, .target = target, .optimize = .fast, .pic = true, .imports = options.imports });
    if (!root.import_table.contains("eggenvector")) {
        const eggenvector = engine.builder.dependency("eggenvector", .{ .target = target, .optimize = .fast });
        root.addImport("eggenvector", eggenvector.module("eggenvector"));
    }
    if (engine.builder.modules.get("eggy")) |eggy| if (reaches(b, root, eggy))
        std.debug.panic("fast library {s} imports eggy; give it only pure modules such as eggenvector", .{options.name});
    const library = b.addLibrary(.{ .name = options.name, .linkage = .static, .root_module = root });
    into.linkLibrary(library);
    return library;
}

/// Whether `root` or any module it imports, however deep, imports `eggy`.
fn reaches(b: *std.Build, root: *std.Build.Module, eggy: *std.Build.Module) bool {
    var seen: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    var pending: std.ArrayList(*std.Build.Module) = .empty;
    pending.append(b.allocator, root) catch @panic("OOM");
    while (pending.pop()) |module| {
        if (module == eggy) return true;
        if ((seen.getOrPut(b.allocator, module) catch @panic("OOM")).found_existing) continue;
        pending.appendSlice(b.allocator, module.import_table.values()) catch @panic("OOM");
    }
    return false;
}

/// Eggy's own fast library, linked into the `eggy` module: the skinning loop
/// (`src/core/skinning_fast.zig`) with the asset formats it reads, built ReleaseFast.
pub fn addEngine(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const web = target.result.os.tag == .emscripten;
    const root = b.createModule(.{
        .root_source_file = b.path("src/core/skinning_fast.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        // Linked into the editor's game library, a shared one.
        .pic = if (web) null else true,
        .imports = &.{.{ .name = "eggy_assets", .module = models.assetsModule(b, target, .ReleaseFast) }},
    });
    return b.addLibrary(.{ .name = "eggy_fast", .linkage = .static, .root_module = root });
}
