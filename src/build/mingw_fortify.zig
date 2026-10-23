//! Turns MinGW's `_FORTIFY_SOURCE` wrappers off where translate-c cannot translate them.
//!
//! Zig defines `_FORTIFY_SOURCE=2` for `.safe` C, and translate-c turns MinGW's fortified
//! `wcscat`/`wcscpy` into Zig with an unused local (`extern_local_wcscat_s`), which fails every
//! C import on windows-gnu `.safe`, including those inside SDL, freetype, Vitellus and weeoui.
// ponytail: whole-graph workaround for a translate-c bug, drop once Zig translates these wrappers.
const std = @import("std");

/// Define `_FORTIFY_SOURCE=0` on `root` and every module it imports, and on the translate-c steps
/// that generate any of them, when building windows-gnu `.safe`. Call it after `root`'s imports
/// are wired: modules imported later are not reached.
pub fn disable(root: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) void {
    if (!target.result.isMinGW() or optimize != .safe) return;
    const b = root.owner;
    var seen: std.AutoArrayHashMapUnmanaged(*std.Build.Module, void) = .empty;
    seen.put(b.allocator, root, {}) catch @panic("OOM");
    var next: usize = 0;
    while (next < seen.count()) : (next += 1) {
        const module = seen.keys()[next];
        module.addCMacro("_FORTIFY_SOURCE", "0");
        if (module.root_source_file) |source| if (source == .generated) {
            if (b.graph.generated_files.items[@backingInt(source.generated.index)].cast(std.Build.Step.TranslateC)) |translate_c| translate_c.defineCMacro("_FORTIFY_SOURCE", "0");
        };
        for (module.import_table.values()) |imported| seen.put(b.allocator, imported, {}) catch @panic("OOM");
    }
}
