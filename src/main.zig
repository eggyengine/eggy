const std = @import("std");
const builtin = @import("builtin");
const eggy = @import("eggy");
const sdl3 = eggy.vit.windowing.sdl3.sdl;

comptime {
    _ = sdl3.main_callbacks;
}

pub const _start = void;
pub const WinMainCRTStartup = void;

const AppState = eggy.Editor;

pub fn init(init_data: sdl3.Init) !struct { AppState, sdl3.AppResult } {
    return .{ try AppState.init(init_data), .run };
}

pub fn iterate(app_state: *AppState) !sdl3.AppResult {
    return app_state.iterate();
}

pub fn event(app_state: *AppState, curr_event: sdl3.events.Event) !sdl3.AppResult {
    return app_state.event(curr_event);
}

pub fn quit(app_state: ?*AppState, result: sdl3.AppResult) void {
    _ = result;
    if (app_state) |state| state.deinit();
}

// SDLActivity looks up this symbol in libmain.so.
export fn SDL_main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return sdl3.c.SDL_EnterAppMainCallbacks(
        argc,
        argv,
        @ptrCast(&sdl3.main_callbacks.SDL_AppInit),
        @ptrCast(&sdl3.main_callbacks.SDL_AppIterate),
        @ptrCast(&sdl3.main_callbacks.SDL_AppEvent),
        @ptrCast(&sdl3.main_callbacks.SDL_AppQuit),
    );
}
