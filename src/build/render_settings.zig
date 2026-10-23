//! Bake a project's shipped graphics defaults into its runtime module.
const std = @import("std");
const package_root = @import("package_root.zig");
const project = @import("../core/project.zig");
const Settings = @import("../core/render_settings.zig").Settings;

pub fn appendDefaults(b: *std.Build, source: *std.ArrayList(u8), own: bool) void {
    const defaults: Settings = if (own) .{} else readDefaults(b);
    var zon: std.Io.Writer.Allocating = .init(b.allocator);
    std.zon.stringify.serialize(defaults, .{}, &zon.writer) catch @panic("cannot serialize graphics defaults");
    source.print(b.allocator, "pub const graphics_zon = \"{f}\";\n", .{std.zig.fmtString(zon.written())}) catch @panic("OOM");
}

fn readDefaults(b: *std.Build) Settings {
    const text = package_root.open(b).readFileAllocOptions(b.graph.io, project.file_name, b.allocator, .limited(1 << 20), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => std.debug.panic("cannot read graphics defaults in {s}: {t}", .{ project.file_name, err }),
    };
    const config = project.parse(b.allocator, text) catch |err|
        std.debug.panic("invalid graphics defaults in {s}: {t}", .{ project.file_name, err });
    return config.graphics;
}
