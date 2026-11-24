//! Own a build's or export's whole process tree, so cancelling stops the compilers and SDK
//! installers it started too, not only its root.
const std = @import("std");
const windows = @import("builtin").os.tag == .windows;
const win = std.os.windows;

pub const Process = struct {
    child: std.process.Child,
    job: ?win.HANDLE = null,

    /// Spawn in a private POSIX process group or Windows job, which its descendants join.
    /// Windows attaches the suspended process before it can spawn any.
    pub fn spawn(io: std.Io, options: std.process.SpawnOptions) !Process {
        var configured = options;
        if (windows) configured.start_suspended = true else configured.pgid = 0;
        var child = try std.process.spawn(io, configured);
        errdefer child.kill(io);
        if (windows) {
            const job = kernel.CreateJobObjectW(null, null) orelse return error.ExportProcessGroupFailed;
            errdefer _ = kernel.CloseHandle(job);
            if (kernel.AssignProcessToJobObject(job, child.id.?) == .FALSE) return error.ExportProcessGroupFailed;
            if (kernel.ResumeThread(child.thread_handle) == std.math.maxInt(u32)) return error.ExportProcessGroupFailed;
            return .{ .child = child, .job = job };
        }
        return .{ .child = child };
    }

    /// Kill the whole tree now without reaping the root, so pipes its processes hold close and
    /// whoever reads them sees the end. Safe from another thread while the root isn't yet reaped.
    pub fn terminate(self: *const Process) void {
        if (windows) {
            _ = kernel.TerminateJobObject(self.job.?, 1);
        } else if (self.child.id) |id| {
            _ = std.c.kill(-id, .KILL);
        }
    }

    /// Kill remaining descendants if the root has not exited, then reap the root and close ownership.
    pub fn stop(self: *Process, io: std.Io) void {
        if (self.child.id != null) self.terminate();
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
