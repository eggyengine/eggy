//! `eggy_compose_shader <shader.slang> <name> <out.slang>`: the build's step making a project
//! shader whole (`compose.zig`) before slangc compiles it for a packaged game.
const std = @import("std");
const compose = @import("compose.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) {
        std.log.err("usage: eggy_compose_shader <shader.slang> <name> <out.slang>", .{});
        return error.InvalidArguments;
    }
    const cwd = std.Io.Dir.cwd();
    const source = try cwd.readFileAlloc(io, args[1], gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(source);
    const whole = compose.compose(gpa, source, args[2]) catch |err| {
        std.log.err("{s}: {t}", .{ args[2], err });
        return err;
    };
    defer gpa.free(whole);
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = whole });
}
