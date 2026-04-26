const std = @import("std");
const ecs = @import("ecs.zig");
const eggy = @import("eggy.zig");

pub const Context = struct {
    world: *ecs.World,
    allocator: std.mem.Allocator,
    delta_time: f32,
    running: *bool,
    proc_init: *std.process.Init,

    pub fn quit(self: *Context) void {
        std.log.debug("Quit signal received from eggy.Context", .{});
        self.running.* = false;
    }
};
