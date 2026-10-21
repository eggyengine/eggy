//! Entry point of a game's runtime executable, on every platform. `addGame` compiles it against
//! the game's generated `eggy_project` module.
const std = @import("std");
const eggy = @import("eggy");
const Runtime = @import("eggy_runtime").Runtime(@import("eggy_project"));
pub const eggy_asset_ids = @import("eggy_project").asset_ids;

comptime {
    _ = eggy.sdl_adapter.main_callbacks;
}

// SDL's main callbacks provide the real entry point.
pub const _start = void;
pub const WinMainCRTStartup = void;

pub const panic = std.debug.FullPanic(eggy.entry.panic);
/// Android and the web log to their own consoles; the desktop through `eggy.log`, which chooses
/// what is printed while running (so every level is compiled in) and keeps a log file.
pub const std_options: std.Options = if (@import("builtin").abi.isAndroid())
    @import("weeoui_sdl3").std_options
else if (@import("builtin").os.tag == .emscripten)
    eggy.vit.web.std_options
else
    .{ .log_level = .debug, .logFn = eggy.log.logFn };

const callbacks = eggy.entry.Callbacks(Runtime);
pub const init = callbacks.init;
pub const iterate = callbacks.iterate;
pub const event = callbacks.event;
pub const quit = callbacks.quit;
