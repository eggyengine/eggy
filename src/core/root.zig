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
pub const Notice = @import("notice.zig").Notice;
pub const entry = @import("entry.zig");
pub const plugins = @import("plugins.zig");
pub const project = @import("project.zig");
pub const preferences = @import("preferences.zig");
pub const components = @import("components.zig");
pub const scene = @import("scene.zig");
pub const scene_instance = @import("scene_instance.zig");
pub const SceneInstance = scene_instance.SceneInstance;
pub const scene_instances = @import("scene_instances.zig");
pub const SceneInstances = scene_instances.SceneInstances;
pub const Name = @import("name.zig").Name;
pub const findNamed = @import("name.zig").find;
pub const transform = @import("transform.zig");
pub const Transform = transform.Transform;
pub const mesh = @import("mesh.zig");
pub const assets = @import("eggy_assets");
pub const model_cache = @import("model_cache.zig");
pub const texture_cache = @import("texture_cache.zig");
pub const Mesh = mesh.Mesh;
pub const camera = @import("camera.zig");
pub const Camera = camera.Camera;
pub const max_drawables = @import("mesh_renderer.zig").max_drawables;
pub const Color = @import("color.zig").Color;
pub const refs = @import("refs.zig");
pub const EntityRef = refs.EntityRef;
pub const AssetRef = refs.AssetRef;
pub const ui = @import("weeoui");
pub const Event = sdl_adapter.sdl.events.Event;
pub const input = @import("input.zig");
pub const Input = input.Input;
pub const Key = input.Key;
pub const MouseButton = input.MouseButton;
pub const Time = @import("time.zig").Time;

test {
    _ = @import("graphics.zig");
    _ = @import("scene_texture.zig");
    _ = @import("notice.zig");
    _ = @import("grid.zig");
    _ = @import("input.zig");
    _ = @import("time.zig");
    _ = @import("plugins.zig");
    _ = @import("project.zig");
    _ = @import("preferences.zig");
    _ = @import("components.zig");
    _ = @import("scene.zig");
    _ = @import("scene_instance.zig");
    _ = @import("scene_instances.zig");
    _ = @import("name.zig");
    _ = @import("transform.zig");
    _ = @import("mesh.zig");
    _ = @import("mesh_renderer.zig");
    _ = @import("model_cache.zig");
    _ = @import("texture_cache.zig");
    _ = @import("eggy_assets");
    _ = @import("camera.zig");
    _ = @import("refs.zig");
    _ = @import("weeoui");
}
