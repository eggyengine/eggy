//! Zig's `std.process.Init` for Eggy's executables, which start through SDL's main callbacks:
//! those replace `main`, so Zig's start code never makes one.
const builtin = @import("builtin");
const std = @import("std");
const sdl3 = @import("vitellus_sdl3").sdl;

const Environ = std.process.Environ;

/// `std.process.Init` from SDL's `Init`: its arena, allocator, Io and arguments, with the
/// process's environment and preopens, as Zig's start code would make them. It lives in SDL's
/// process arena, freed at exit, so the pointer stays valid for the whole run.
pub fn fromSdl(sdl_init: sdl3.Init) !*const std.process.Init {
    const arena = sdl_init.arena.allocator();
    const environ = Environ{ .block = environBlock() };
    const environ_map = try arena.create(Environ.Map);
    environ_map.* = try Environ.createMap(environ, arena);
    const process = try arena.create(std.process.Init);
    process.* = .{
        .minimal = .{ .args = .{ .vector = argsVector(sdl_init.args) }, .environ = environ },
        .arena = sdl_init.arena,
        .gpa = sdl_init.gpa,
        .io = sdl_init.io,
        .environ_map = environ_map,
        .preopens = try std.process.Preopens.init(arena),
    };
    return process;
}

/// The environment as the OS gave it: libc's `environ`, or Windows' (read when asked).
fn environBlock() Environ.Block {
    if (Environ.Block == Environ.GlobalBlock) return .global;
    var count: usize = 0;
    while (std.c.environ[count] != null) : (count += 1) {}
    return .{ .slice = @ptrCast(std.c.environ[0..count :null]) };
}

/// The command line in `std.process.Args`' form: Windows' own WTF-16 line, as Zig reads it,
/// else SDL's arguments.
fn argsVector(args: [][*:0]u8) std.process.Args.Vector {
    if (builtin.os.tag == .windows) return std.os.windows.peb().ProcessParameters.CommandLine.slice();
    return args;
}

test "the environment and arguments read back through std.process.Init" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var program = "game".*;
    var args = [_][*:0]u8{&program};
    const process = try fromSdl(.{ .arena = &arena, .gpa = std.testing.allocator, .io = std.testing.io, .args = &args });
    if (builtin.os.tag != .windows) {
        try std.testing.expectEqual(@as(usize, 1), process.minimal.args.vector.len);
        try std.testing.expectEqualStrings("game", std.mem.span(process.minimal.args.vector[0]));
    }
    try std.testing.expect(process.environ_map.count() > 0);
}
