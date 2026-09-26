// re-exports
pub const math = @import("eggenvector");
pub const vit = @import("vitellus");
pub const sdl_adapter = @import("vitellus_sdl3");
pub const slangc = @import("slangc");

pub const Editor = @import("game.zig").Game;

test {
    _ = @import("graphics.zig");
    _ = @import("ui_demo.zig");
    _ = @import("weeoui");
}
