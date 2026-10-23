//! The package a build script runs for, as a directory it reads while configuring.
const std = @import("std");

/// `b`'s package root, opened. What a build reads there isn't tracked, so this marks the
/// configuration uncacheable: Zig reconfigures on every build, as it always did before 0.17.
/// ponytail: declare what is read with `dependOnFileContents`/`dependOnDirectoryContents`
/// instead once configuration time matters.
pub fn open(b: *std.Build) std.Io.Dir {
    b.graph.poisonCache();
    return b.root.openDir(b.graph.io, ".", .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {f}: {t}", .{ b.root, err });
}

/// `b`'s package root as an absolute path, for tools run during the build.
pub fn absolute(b: *std.Build) []const u8 {
    return open(b).realPathFileAlloc(b.graph.io, ".", b.allocator) catch |err|
        std.debug.panic("cannot resolve {f}: {t}", .{ b.root, err });
}
