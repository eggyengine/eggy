//! Own the complete export process tree so cancellation also stops SDK installers.
const std = @import("std");
const windows = @import("builtin").os.tag == .windows;
const win = std.os.windows;

pub const Process = struct {
    child: std.process.Child,
    job: ?win.HANDLE = null,
    grouped: bool,

    /// Spawn with a private POSIX process group or Windows job when `grouped` is true.
    /// Windows attaches the suspended process before any installer can spawn descendants.
    pub fn spawn(io: std.Io, options: std.process.SpawnOptions, grouped: bool) !Process {
        var configured = options;
        if (grouped) {
            if (windows) configured.start_suspended = true else configured.pgid = 0;
        }
        var child = try std.process.spawn(io, configured);
        errdefer child.kill(io);
        if (windows and grouped) {
            const job = kernel.CreateJobObjectW(null, null) orelse return error.ExportProcessGroupFailed;
            errdefer _ = kernel.CloseHandle(job);
            if (kernel.AssignProcessToJobObject(job, child.id.?) == .FALSE) return error.ExportProcessGroupFailed;
            if (kernel.ResumeThread(child.thread_handle) == std.math.maxInt(u32)) return error.ExportProcessGroupFailed;
            return .{ .child = child, .job = job, .grouped = true };
        }
        return .{ .child = child, .grouped = grouped };
    }

    /// Kill remaining descendants if the root has not exited, then reap the root and close ownership.
    pub fn stop(self: *Process, io: std.Io) void {
        if (self.child.id) |id| if (self.grouped) {
            if (windows) {
                _ = kernel.TerminateJobObject(self.job.?, 1);
            } else {
                _ = std.c.kill(-id, .KILL);
            }
        };
        self.child.kill(io);
        if (windows) if (self.job) |job| {
            _ = kernel.CloseHandle(job);
            self.job = null;
        };
    }
};

const kernel = struct {
    extern "kernel32" fn CreateJobObjectW(?*anyopaque, ?[*:0]const u16) callconv(.winapi) ?win.HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(win.HANDLE, win.HANDLE) callconv(.winapi) win.BOOL;
    extern "kernel32" fn ResumeThread(win.HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn TerminateJobObject(win.HANDLE, u32) callconv(.winapi) win.BOOL;
    extern "kernel32" fn CloseHandle(win.HANDLE) callconv(.winapi) win.BOOL;
};

test "an export owns a separate process group and cancellation reaps its root" {
    if (windows) return error.SkipZigTest;
    var process = try Process.spawn(std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "printf ready; sleep 30" },
        .stdout = .pipe,
        .stderr = .ignore,
    }, true);
    defer process.stop(std.testing.io);
    var buffer: [32]u8 = undefined;
    var reader = process.child.stdout.?.readerStreaming(std.testing.io, &buffer);
    try std.testing.expectEqualStrings("ready", try reader.interface.take(5));
    const libc = struct {
        extern "c" fn getpgid(c_int) c_int;
    };
    try std.testing.expectEqual(process.child.id.?, libc.getpgid(process.child.id.?));
    process.stop(std.testing.io);
    try std.testing.expect(process.child.id == null);
}
