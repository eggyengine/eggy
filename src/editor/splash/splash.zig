//! The splash screen a project's editor shows from the moment it starts until its first frame is
//! up: the editor runs itself again as the splash (`screen.zig`) and tells it each startup step
//! (`link.zig`), so the splash keeps moving while the editor works.
const std = @import("std");
const link = @import("link.zig");
const screen = @import("screen.zig");
const log = std.log.scoped(.splash);

pub const Step = @import("message.zig").Step;
pub const open = link.open;
pub const step = link.step;
pub const detail = link.detail;
pub const finish = link.finish;
pub const wait = link.wait;

/// Whether `args` start this executable as a splash screen (see `link.open`).
pub fn isCommand(args: []const [*:0]const u8) bool {
    return args.len >= 4 and std.mem.eql(u8, std.mem.span(args[1]), link.flag);
}

/// Run as the splash screen `args` ask for, until the editor is done with it.
///
/// ```zig
/// if (splash.isCommand(args)) return splash.run(process, args);
/// ```
pub fn run(process: *const std.process.Init, args: []const [*:0]const u8) void {
    screen.run(process.gpa, process.io, std.mem.span(args[2]), std.mem.span(args[3])) catch |err|
        log.err("cannot show the splash screen: {t}", .{err});
}

test {
    _ = @import("message.zig");
    _ = @import("motion.zig");
    _ = @import("canvas.zig");
    _ = screen;
    _ = link;
}

test "only the splash flag with a project and version starts the splash" {
    try std.testing.expect(isCommand(&.{ "garden_editor", "--splash", "garden", "0.1.0" }));
    try std.testing.expect(!isCommand(&.{ "garden_editor", "--splash" }));
    try std.testing.expect(!isCommand(&.{ "garden_editor", "--project", "/games/garden", "x" }));
}
