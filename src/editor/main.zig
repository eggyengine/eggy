//! Entry point of a game's editor executable, desktop only. `addGame` compiles it against the
//! game's generated `eggy_project` module.
const std = @import("std");
const eggy = @import("eggy");
const Editor = @import("eggy_editor").Editor(@import("eggy_project"));

comptime {
    _ = eggy.sdl_adapter.main_callbacks;
}

// SDL's main callbacks provide the real entry point.
pub const _start = void;
pub const WinMainCRTStartup = void;

pub const panic = std.debug.FullPanic(eggy.entry.panic);
/// Log through the editor, which keeps messages for its Console panel.
pub const std_options: std.Options = .{ .logFn = @import("eggy_editor").logFn };

const callbacks = eggy.entry.Callbacks(Editor);
pub const init = callbacks.init;
pub const iterate = callbacks.iterate;
pub const event = callbacks.event;
pub const quit = callbacks.quit;
