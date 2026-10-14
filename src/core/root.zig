//! The `eggy` module: the engine games and plugins import. Builds for every platform, the web included.

// re-exports
pub const math = @import("eggenvector");
pub const ecs = @import("clutch");
pub const vit = @import("vitellus");
pub const sdl_adapter = @import("vitellus_sdl3");
pub const slangc = @import("vitellus_slangc");

pub const App = @import("app.zig").App;
pub const Graphics = @import("graphics.zig").Graphics;
pub const Frame = @import("graphics.zig").Frame;
pub const entry = @import("entry.zig");
pub const plugins = @import("plugins.zig");
pub const ui = @import("weeoui");
pub const Event = sdl_adapter.sdl.events.Event;

test {
    _ = @import("graphics.zig");
    _ = @import("plugins.zig");
    _ = @import("weeoui");
}
