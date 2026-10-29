//! The dev console: lines typed into it run as commands (Eggy's, the game's and its plugins'),
//! or as Buzz in a session that lasts. The game owns it as `app.dev_console`; the runtime shows it
//! over the game with ` (`overlay`), and the editor in its Console panel and over the game as it plays.
pub const DevConsole = @import("console.zig").DevConsole;
pub const Line = @import("console.zig").Line;
pub const Command = @import("commands.zig").Command;
pub const Call = @import("commands.zig").Call;
pub const Commands = @import("commands.zig").Commands;
pub const overlay = @import("overlay.zig");
/// Whether this build runs Buzz; where it doesn't, only commands run.
pub const scripting = @import("buzz_session.zig").available;

test {
    _ = @import("buzz_session.zig");
    _ = @import("builtin_commands.zig");
    _ = @import("commands.zig");
    _ = @import("completion.zig");
    _ = @import("console.zig");
    _ = @import("overlay.zig");
    _ = @import("palette.zig");
    _ = @import("prompt.zig");
}
