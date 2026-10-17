//! SDL main callbacks shared by Eggy's executables. Each forwards to the program's app type and
//! shows a fatal error in a native dialog (the browser console on the web) before exiting.
const builtin = @import("builtin");
const std = @import("std");
const vit = @import("vitellus");
const sdl3 = @import("vitellus_sdl3").sdl;
const fatal_dialog = @import("fatal_dialog");
const process_init = @import("process_init.zig");

const web = builtin.os.tag == .emscripten;

/// The `init`, `iterate`, `event` and `quit` callbacks for `AppState`, which provides
/// `init(process, args) !AppState` (process: Zig's `std.process.Init`, valid for the whole run;
/// args: the command line, program first), `iterate(*AppState) !AppResult`, `event(*AppState, Event) !AppResult`
/// and `deinit(*AppState)`. Re-export them from the executable's root file.
pub fn Callbacks(comptime AppState: type) type {
    return struct {
        pub fn init(init_data: sdl3.Init) !struct { AppState, sdl3.AppResult } {
            const process = process_init.fromSdl(init_data) catch |err| {
                reportError("init", err);
                return err;
            };
            return .{ AppState.init(process, init_data.args) catch |err| {
                reportError("init", err);
                return err;
            }, .run };
        }

        pub fn iterate(app_state: *AppState) !sdl3.AppResult {
            return app_state.iterate() catch |err| {
                reportError("frame", err);
                return err;
            };
        }

        pub fn event(app_state: *AppState, curr_event: sdl3.events.Event) !sdl3.AppResult {
            return app_state.event(curr_event) catch |err| {
                reportError("event", err);
                return err;
            };
        }

        pub fn quit(app_state: ?*AppState, result: sdl3.AppResult) void {
            _ = result;
            if (app_state) |state| state.deinit();
        }
    };
}

/// Panic handler for `std.debug.FullPanic`: show the message, then panic as usual.
pub fn panic(message: []const u8, first_trace_addr: ?usize) noreturn {
    if (web) vit.web.panic.call(message, first_trace_addr);
    fatal_dialog.show("panic", message);
    std.debug.defaultPanic(message, first_trace_addr);
}

fn reportError(stage: []const u8, err: anyerror) void {
    fatal_dialog.report(stage, err, if (err == error.SdlError) sdl3.errors.get() else null);
}
