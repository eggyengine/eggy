//! The libraries Eggy's API is made of (Vitellus, Weeoui, Clutch and Eggenvector), given as
//! Eggy's own to every module a game builds with: a package that pins its own copy, to work
//! without Eggy, uses Eggy's inside a game, so its types are Eggy's.
const std = @import("std");
const Module = std.Build.Module;

/// The import names Eggy's own modules give these libraries.
const names = [_][]const u8{ "vitellus", "weeoui", "clutch", "eggenvector" };

/// Point every import named in `names`, in `roots` and every module they import, at `eggy`'s.
/// Eggy's own modules are left as they are.
///
/// ```zig
/// shared_libraries.share(b, eggy, &.{ options.game, plugin_module });
/// ```
pub fn share(b: *std.Build, eggy: *Module, roots: []const *Module) void {
    var seen: std.AutoHashMapUnmanaged(*Module, void) = .empty;
    var pending: std.ArrayList(*Module) = .empty;
    pending.appendSlice(b.allocator, roots) catch @panic("OOM");
    while (pending.pop()) |module| {
        if (module == eggy or (seen.getOrPut(b.allocator, module) catch @panic("OOM")).found_existing) continue;
        for (names) |name| if (module.import_table.getPtr(name)) |imported| {
            imported.* = eggy.import_table.get(name) orelse continue;
        };
        pending.appendSlice(b.allocator, module.import_table.values()) catch @panic("OOM");
    }
}
