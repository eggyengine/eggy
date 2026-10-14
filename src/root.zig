// re-exports
pub const math = @import("eggenvector");
pub const vit = @import("vitellus");
pub const sdl_adapter = @import("vitellus_sdl3");
pub const slangc = @import("vitellus_slangc");

pub const Game = @import("game.zig").Game;

test {
    _ = @import("graphics.zig");
    _ = @import("weeoui");
}
