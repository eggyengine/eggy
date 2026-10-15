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
pub const Surface = @import("graphics.zig").Surface;
pub const SceneTexture = @import("scene_texture.zig").SceneTexture;
pub const entry = @import("entry.zig");
pub const plugins = @import("plugins.zig");
pub const project = @import("project.zig");
pub const preferences = @import("preferences.zig");
pub const components = @import("components.zig");
pub const scene = @import("scene.zig");
pub const Name = @import("name.zig").Name;
pub const ui = @import("weeoui");
pub const Event = sdl_adapter.sdl.events.Event;

test {
    _ = @import("graphics.zig");
    _ = @import("scene_texture.zig");
    _ = @import("plugins.zig");
    _ = @import("project.zig");
    _ = @import("preferences.zig");
    _ = @import("components.zig");
    _ = @import("scene.zig");
    _ = @import("name.zig");
    _ = @import("weeoui");
}
