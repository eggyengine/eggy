//! The dev console: lines typed into it run as commands (Eggy's, the game's and its plugins').
//! The game owns it as `app.dev_console`; the runtime shows it over the game with ` (`overlay`),
//! and the editor in its Console panel and over the game as it plays.
pub const DevConsole = @import("console.zig").DevConsole;
pub const Line = @import("console.zig").Line;
pub const Command = @import("commands.zig").Command;
pub const Call = @import("commands.zig").Call;
pub const Commands = @import("commands.zig").Commands;
pub const overlay = @import("overlay.zig");
pub const candidates_height = @import("prompt.zig").candidates_height;

test {
    _ = @import("builtin_commands.zig");
    _ = @import("commands.zig");
    _ = @import("completion.zig");
    _ = @import("console.zig");
    _ = @import("overlay.zig");
    _ = @import("palette.zig");
    _ = @import("prompt.zig");
}
