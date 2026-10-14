//! Entry point of a game's runtime executable, on every platform. `addGame` compiles it against
//! the game's generated `eggy_project` module.
const std = @import("std");
const eggy = @import("eggy");
const Runtime = @import("eggy_runtime").Runtime(@import("eggy_project"));

comptime {
    _ = eggy.sdl_adapter.main_callbacks;
}

// SDL's main callbacks provide the real entry point.
pub const _start = void;
pub const WinMainCRTStartup = void;

pub const panic = std.debug.FullPanic(eggy.entry.panic);
pub const std_options = eggy.vit.web.std_options;

const callbacks = eggy.entry.Callbacks(Runtime);
pub const init = callbacks.init;
pub const iterate = callbacks.iterate;
pub const event = callbacks.event;
pub const quit = callbacks.quit;
