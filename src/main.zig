const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const fatal_dialog = @import("fatal_dialog");

comptime {
    // zig-sdl3's callbacks build a `std.Io.Threaded`, which Zig 0.16 cannot compile for Emscripten.
    if (web) _ = WebCallbacks else _ = sdl3.main_callbacks;
}

pub const _start = void;
pub const WinMainCRTStartup = void;

const AppState = eggy.Editor;

pub const panic = std.debug.FullPanic(panicHandler);

// Zig 0.16 cannot compile its stderr writer for Emscripten, so the web build logs and panics
// through the browser console instead.
pub const std_options: std.Options = if (web) .{ .logFn = consoleLog } else .{};
const web = @import("builtin").os.tag == .emscripten;
extern fn emscripten_console_log(message: [*:0]const u8) void;
extern fn emscripten_console_error(message: [*:0]const u8) void;

fn consoleLog(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const prefix = "[" ++ @tagName(level) ++ "] " ++ (if (scope == .default) "" else @tagName(scope) ++ ": ");
    const message = std.fmt.bufPrintZ(&buffer, prefix ++ format, args) catch "[log message too long]";
    if (@intFromEnum(level) <= @intFromEnum(std.log.Level.warn)) emscripten_console_error(message) else emscripten_console_log(message);
}

fn panicHandler(message: []const u8, first_trace_addr: ?usize) noreturn {
    if (web) {
        std.log.err("panic: {s}", .{message});
        @trap();
    }
    fatal_dialog.show("panic", message);
    std.debug.defaultPanic(message, first_trace_addr);
}

fn reportError(stage: []const u8, err: anyerror) void {
    fatal_dialog.report(stage, err, if (err == error.SdlError) sdl3.errors.get() else null);
}

pub fn init(init_data: sdl3.Init) !struct { AppState, sdl3.AppResult } {
    return .{ AppState.init(init_data.gpa) catch |err| {
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

/// SDL's main-callback entry points for the browser, where SDL drives frames from
/// requestAnimationFrame. Mirrors zig-sdl3's `main_callbacks` without its `sdl3.Init`.
const WebCallbacks = struct {
    const c = sdl3.c;

    export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
        return c.SDL_EnterAppMainCallbacks(argc, argv, appInit, appIterate, appEvent, appQuit);
    }

    fn appInit(app_state: [*c]?*anyopaque, _: c_int, _: [*c][*c]u8) callconv(.c) c.SDL_AppResult {
        const state = std.heap.c_allocator.create(AppState) catch return c.SDL_APP_FAILURE;
        state.* = AppState.init(std.heap.c_allocator) catch |err| {
            reportError("init", err);
            std.heap.c_allocator.destroy(state);
            return c.SDL_APP_FAILURE;
        };
        app_state.* = state;
        return c.SDL_APP_CONTINUE;
    }

    fn appIterate(app_state: ?*anyopaque) callconv(.c) c.SDL_AppResult {
        return @intFromEnum(iterate(@ptrCast(@alignCast(app_state))) catch return c.SDL_APP_FAILURE);
    }

    fn appEvent(app_state: ?*anyopaque, curr_event: [*c]c.SDL_Event) callconv(.c) c.SDL_AppResult {
        return @intFromEnum(event(@ptrCast(@alignCast(app_state)), sdl3.events.Event.fromSdl(curr_event.*)) catch return c.SDL_APP_FAILURE);
    }

    fn appQuit(app_state: ?*anyopaque, _: c.SDL_AppResult) callconv(.c) void {
        const state: *AppState = @ptrCast(@alignCast(app_state orelse return));
        state.deinit();
        std.heap.c_allocator.destroy(state);
    }
};
