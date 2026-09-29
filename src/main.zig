const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const fatal_dialog = @import("fatal_dialog");

comptime {
    _ = sdl3.main_callbacks;
}

pub const _start = void;
pub const WinMainCRTStartup = void;

const AppState = eggy.Editor;

pub const std_options: std.Options = .{ .logFn = eggy.devtools_log };

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(message: []const u8, first_trace_addr: ?usize) noreturn {
    fatal_dialog.show("panic", message);
    std.debug.defaultPanic(message, first_trace_addr);
}

fn reportError(stage: []const u8, err: anyerror) void {
    fatal_dialog.report(stage, err, if (err == error.SdlError) sdl3.errors.get() else null);
}

pub fn init(init_data: sdl3.Init) !struct { AppState, sdl3.AppResult } {
    return .{ AppState.init(init_data) catch |err| {
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
