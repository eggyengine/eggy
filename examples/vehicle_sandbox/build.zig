const std = @import("std");
const eggy = @import("eggy");

/// Build the vehicle physics sandbox (`zig build run-runtime` or `zig build run`).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const game = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    eggy.addGame(b, .{
        .name = "vehicle_sandbox",
        .game = game,
        .target = target,
        .optimize = optimize,
    });
}
