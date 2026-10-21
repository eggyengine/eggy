//! SDL main callbacks shared by Eggy's executables. Each forwards to the program's app type and
//! shows a fatal error in a native dialog (the browser console on the web) before exiting.
const builtin = @import("builtin");
const std = @import("std");
const vit = @import("vitellus");
const sdl3 = @import("vitellus_sdl3").sdl;
const fatal_dialog = @import("fatal_dialog");
const process_init = @import("process_init.zig");
const log = @import("log/log.zig");

/// Build the process context before choosing a GUI or command-line entry point.
/// Borrows SDL's process arena/Io and allocates the environment map there; see `fromSdl`
/// in process_init.zig for the lifetime and subprocess-environment contract.
///
/// ```zig
/// const process = try eggy.entry.processInit(init_data); // init_data: sdl3.Init
/// ```
pub const processInit = process_init.fromSdl;

const web = builtin.os.tag == .emscripten;

/// The `init`, `iterate`, `event` and `quit` callbacks for `AppState`, which provides
/// `init(process, args) !AppState` (process: Zig's `std.process.Init`, valid for the whole run;
/// args: the command line, program first), `iterate(*AppState) !AppResult`, `event(*AppState, Event) !AppResult`
/// and `deinit(*AppState)`. Re-export them from the executable's root file.
/// Host-only; the generated callbacks retain ownership in SDL's app-state allocation.
/// Failures show the native fatal dialog (or browser log) before propagating.
///
/// ```zig
/// // In a custom executable root; State implements the lifecycle listed above.
/// const callbacks = eggy.entry.Callbacks(State);
/// pub const init = callbacks.init;
/// pub const iterate = callbacks.iterate;
/// pub const event = callbacks.event;
/// pub const quit = callbacks.quit;
/// ```
pub fn Callbacks(comptime AppState: type) type {
    return struct {
        const android = builtin.abi.isAndroid();
        var callback_io: std.Io = undefined;
        var callback_mutex: std.Io.Mutex = .init;

        /// Adapt SDL's startup data into a process context and owned `AppState`.
        /// Returns the state plus `.run`; process/state initialization errors are reported
        /// and propagated. SDL's callback adapter owns the returned state's storage.
        ///
        /// ```zig
        /// pub const init = eggy.entry.Callbacks(State).init; // Executable root declaration.
        /// ```
        pub fn init(init_data: sdl3.Init) !struct { AppState, sdl3.AppResult } {
            raiseStackLimit();
            const process = process_init.fromSdl(init_data) catch |err| {
                reportError("init", err);
                return err;
            };
            if (android) callback_io = process.io;
            return .{ AppState.init(process, init_data.args) catch |err| {
                reportError("init", err);
                return err;
            }, .run };
        }

        /// Forward one frame to the live state. Returns its run/exit decision; frame
        /// errors are shown as fatal errors and propagated, not treated as `.run`.
        ///
        /// ```zig
        /// pub const iterate = eggy.entry.Callbacks(State).iterate;
        /// ```
        pub fn iterate(app_state: *AppState) !sdl3.AppResult {
            if (android) callback_mutex.lockUncancelable(callback_io);
            defer if (android) callback_mutex.unlock(callback_io);
            return app_state.iterate() catch |err| {
                reportError("frame", err);
                return err;
            };
        }

        /// Forward one borrowed SDL event to the state on the main thread.
        /// Returns the state's run/exit decision, reporting and propagating event failures.
        ///
        /// ```zig
        /// pub const event = eggy.entry.Callbacks(State).event;
        /// ```
        pub fn event(app_state: *AppState, curr_event: sdl3.events.Event) !sdl3.AppResult {
            // Android delivers lifecycle events from its UI thread, even during a render frame.
            if (android) callback_mutex.lockUncancelable(callback_io);
            defer if (android) callback_mutex.unlock(callback_io);
            return app_state.event(curr_event) catch |err| {
                reportError("event", err);
                return err;
            };
        }

        /// Deinitialize a successfully created state; null means initialization never
        /// supplied one. `result` does not change cleanup. SDL frees the state storage.
        ///
        /// ```zig
        /// pub const quit = eggy.entry.Callbacks(State).quit;
        /// ```
        pub fn quit(app_state: ?*AppState, result: sdl3.AppResult) void {
            _ = result;
            if (app_state == null) return;
            if (android) callback_mutex.lockUncancelable(callback_io);
            defer if (android) callback_mutex.unlock(callback_io);
            if (app_state) |state| state.deinit();
        }
    };
}

/// The stack Eggy's programs ask for: the editor builds its state on the stack (about 8 MiB),
/// more than many systems' default limit.
// ponytail: build the editor's state in place on the heap instead, then drop this; macOS's main
// thread stack is fixed at 8 MiB and needs `-stack_size` at link time if it overflows there.
const wanted_stack_bytes = 64 << 20;

/// Raise the soft stack limit to `wanted_stack_bytes` (within the hard limit). Linux grows the main
/// thread's stack up to the current limit, so raising it this early is enough. Zig's own start
/// code does this from the executable's stack size, but SDL's callbacks replace it.
fn raiseStackLimit() void {
    if (builtin.os.tag != .linux) return;
    const limits = std.posix.getrlimit(.STACK) catch return;
    const wanted = @min(wanted_stack_bytes, limits.max);
    if (wanted > limits.cur) std.posix.setrlimit(.STACK, .{ .cur = wanted, .max = limits.max }) catch {};
}

/// Panic handler for `std.debug.FullPanic`: write a crash report, show the message, then panic as
/// usual. Borrows `message` only for reporting and never returns. `first_trace_addr` is forwarded
/// to Zig's default handler; browser panics also use the web platform hook.
///
/// ```zig
/// pub const panic = std.debug.FullPanic(eggy.entry.panic); // Executable root.
/// ```
pub fn panic(message: []const u8, first_trace_addr: ?usize) noreturn {
    if (web) vit.web.panic.call(message, first_trace_addr);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const crash_report = log.crash_report.write(std.Options.debug_io, "panic", message, .{ .current = first_trace_addr orelse @returnAddress() }, &path_buffer);
    fatal_dialog.report("panic", message, crash_report);
    std.debug.defaultPanic(message, first_trace_addr);
}

/// Report `err`, which ended `stage`: a crash report with its return trace, then the dialog.
fn reportError(stage: []const u8, err: anyerror) void {
    var message_buffer: [1280]u8 = undefined;
    const message = if (err == error.SdlError)
        std.fmt.bufPrint(&message_buffer, "SdlError: {s}", .{sdl3.errors.get() orelse ""}) catch "SdlError"
    else
        @errorName(err);
    const trace: log.crash_report.Trace = if (@errorReturnTrace()) |error_trace| .{ .error_return = error_trace } else .none;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    fatal_dialog.report(stage, message, log.crash_report.write(std.Options.debug_io, stage, message, trace, &path_buffer));
}
