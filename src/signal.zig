const std = @import("std");
const builtin = @import("builtin");

pub var interrupted: std.atomic.Value(bool) = .init(false);

const CTRL_C_EVENT: u32 = 0;
const CTRL_BREAK_EVENT: u32 = 1;
const CTRL_CLOSE_EVENT: u32 = 2;
const CTRL_LOGOFF_EVENT: u32 = 5;
const CTRL_SHUTDOWN_EVENT: u32 = 6;

pub fn setupDefaults() void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetConsoleCtrlHandler(windowsCtrlHandler, 1);
    } else {
        // posix
        listenFor(.INT, defaultHandler);
        listenFor(.TERM, defaultHandler);
    }
}

fn defaultHandler() void {
    interrupted.store(true, .release);
}

fn windowsCtrlHandler(dwCtrlType: u32) callconv(.winapi) std.os.windows.BOOL {
    switch (dwCtrlType) {
        CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT => {
            interrupted.store(true, .release);
            return 1; // we handled it
        },
        else => return 0, // pass it on to next handler
    }
}

pub fn listenFor(sig: std.posix.SIG, comptime f: fn () void) void {
    if (builtin.os.tag == .windows) {
        return;
    }

    const Handler = struct {
        pub fn handle(_: std.posix.SIG) callconv(.c) void {
            f();
        }
    };

    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = Handler.handle },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(sig, &sa, null);
}

/// Check if an interrupt signal was received
pub fn wasInterrupted() bool {
    return interrupted.load(.acquire);
}

/// Reset the interrupt flag
pub fn resetInterrupt() void {
    interrupted.store(false, .release);
}
