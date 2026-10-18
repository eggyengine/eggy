//! SDL main callbacks shared by Eggy's executables. Each forwards to the program's app type and
//! shows a fatal error in a native dialog (the browser console on the web) before exiting.
const builtin = @import("builtin");
const std = @import("std");
const vit = @import("vitellus");
const sdl3 = @import("vitellus_sdl3").sdl;
const fatal_dialog = @import("fatal_dialog");
const process_init = @import("process_init.zig");

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

/// Panic handler for `std.debug.FullPanic`: show the message, then panic as usual.
/// Borrows `message` only for reporting and never returns. `first_trace_addr` is forwarded
/// to Zig's default handler; browser panics also use the web platform hook.
///
/// ```zig
/// pub const panic = std.debug.FullPanic(eggy.entry.panic); // Executable root.
/// ```
pub fn panic(message: []const u8, first_trace_addr: ?usize) noreturn {
    if (web) vit.web.panic.call(message, first_trace_addr);
    fatal_dialog.show("panic", message);
    std.debug.defaultPanic(message, first_trace_addr);
}

fn reportError(stage: []const u8, err: anyerror) void {
    fatal_dialog.report(stage, err, if (err == error.SdlError) sdl3.errors.get() else null);
}
