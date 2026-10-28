//! Bake a project's shipped graphics defaults, and whether its dev console opens, into its
//! runtime module.
const std = @import("std");
const package_root = @import("package_root.zig");
const project = @import("../core/project.zig");
const Settings = @import("../core/render_settings.zig").Settings;

pub fn appendDefaults(b: *std.Build, source: *std.ArrayList(u8), own: bool) void {
    const config: ?project.Config = if (own) null else readConfig(b);
    if (config) |read| if (!read.dev_console) source.appendSlice(b.allocator, "pub const dev_console = false;\n") catch @panic("OOM");
    const defaults: Settings = if (config) |read| read.graphics else .{};
    var zon: std.Io.Writer.Allocating = .init(b.allocator);
    std.zon.stringify.serialize(defaults, .{}, &zon.writer) catch @panic("cannot serialize graphics defaults");
    source.print(b.allocator, "pub const graphics_zon = \"{f}\";\n", .{std.zig.fmtString(zon.written())}) catch @panic("OOM");
}

fn readConfig(b: *std.Build) ?project.Config {
    const text = package_root.open(b).readFileAllocOptions(b.graph.io, project.file_name, b.allocator, .limited(1 << 20), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => std.debug.panic("cannot read {s}: {t}", .{ project.file_name, err }),
    };
    return project.parse(b.allocator, text) catch |err|
        std.debug.panic("invalid {s}: {t}", .{ project.file_name, err });
}
