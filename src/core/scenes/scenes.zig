//! Scene instances created through the current world's registry and file provider, at once or
//! streamed in over several frames (`stream.zig`).
const std = @import("std");
const ecs = @import("clutch");
const refs = @import("../refs.zig");
const scene = @import("../scene.zig");
const instances = @import("../scene_instances.zig");
const Resources = @import("../resources/resources.zig").Resources;
const support = @import("../support.zig");
pub const streaming_support: support.Support = .available;
pub const Transition = @import("transition.zig").Transition;
const stream_zig = @import("stream.zig");
pub const SceneStream = stream_zig.SceneStream;
pub const StreamOptions = stream_zig.Options;
pub const StreamTicket = stream_zig.Ticket;
pub const Loading = stream_zig.Loading;
pub const Placed = stream_zig.Placed;
pub const loading_screen = @import("loading_screen.zig");

/// A borrowed view of the current world. Do not retain it across world resets or hot reload.
pub const Scenes = struct {
    world: *ecs.World,
    instances: *instances.SceneInstances,
    resources: Resources,
    access: ?scene.Access,
    transition: ?*Transition = null,
    streaming: ?*SceneStream = null,

    pub const Options = struct { parent: ?ecs.EntityId = null };

    /// Create a scene-instance root and its immediate scene entities synchronously. Nested
    /// instances synchronize at the normal scene-sync point. Returns the root; the world owns
    /// it. Read/parse/allocation failures remove everything this call spawned.
    /// `options.parent`, when supplied, must be alive in this world. Requires a scene registry
    /// and resource provider; do not retain the returned ID across world resets.
    ///
    /// ```zig
    /// // In a game hook:
    /// const root = try app.scenes().instantiate(.init("resources/enemy.scene.zon"), .{});
    /// ```
    pub fn instantiate(self: Scenes, file: refs.AssetRef(.scene), options: Options) !ecs.EntityId {
        if (file.len == 0) return error.UnsetAsset;
        const access = self.access orelse return error.NoSceneRegistry;
        if (options.parent) |parent| if (!self.world.isAlive(parent)) return error.InvalidEntity;
        var resources = self.resources;
        return self.instances.create(resources.sceneFiles(), self.world, access, file, options.parent);
    }

    /// Load `file` over the frames to come, then place it: beside the world as an instance (under
    /// `options.parent`), or with `options.replace` in place of every entity, as `replace` does.
    /// Its file is read in the background and the models and images it uses are put on the GPU
    /// one a frame, with Eggy's loading screen over the game unless `options.loading_screen` is
    /// false; `loading` says how far it has come, for a screen of the game's own. One scene
    /// streams at a time (`SceneStreamBusy`). Ask `streamed` with the ticket how it ended.
    ///
    /// ```zig
    /// const ticket = try app.scenes().stream(.init("resources/level.scene.zon"), .{ .replace = true });
    /// // Later, in an update:
    /// if (try app.scenes().streamed(ticket)) |placed| _ = placed;
    /// ```
    pub fn stream(self: Scenes, file: refs.AssetRef(.scene), options: StreamOptions) !StreamTicket {
        if (self.access == null) return error.NoSceneRegistry;
        const streaming = self.streaming orelse return error.NoSceneStreamHost;
        if (options.replace and options.parent != null) return error.InvalidStreamOptions;
        if (options.parent) |parent| if (!self.world.isAlive(parent)) return error.InvalidEntity;
        return streaming.start(self.world.allocator, self.resources, file, options);
    }

    /// How the stream `ticket` names ended: null while it loads, then where it was placed (its
    /// instance's root; null when it replaced the world), or the error that stopped it. Kept
    /// until the next `stream` starts, after which an older ticket is `UnknownSceneStream`.
    pub fn streamed(self: Scenes, ticket: StreamTicket) !?Placed {
        const streaming = self.streaming orelse return error.NoSceneStreamHost;
        return streaming.outcome(ticket);
    }

    /// How far the scene streaming in has come; null when none is. Its names are borrowed until
    /// the next frame.
    pub fn loading(self: Scenes) ?Loading {
        const streaming = self.streaming orelse return null;
        return streaming.loading();
    }
    /// Read and parse a replacement now; commit it after the current gameplay update.
    /// All old entities are removed only after the replacement instantiates successfully.
    /// Plugin state, schedules, resources and UI survive. Entity/component pointers do not.
    /// Missing/invalid files leave the current world untouched; only one request may be pending.
    ///
    /// ```zig
    /// try app.scenes().replace(.init("resources/level.scene.zon"));
    /// ```
    pub fn replace(self: Scenes, file: refs.AssetRef(.scene)) !void {
        if (file.len == 0) return error.UnsetAsset;
        if (self.access == null) return error.NoSceneRegistry;
        const transition = self.transition orelse return error.NoSceneTransitionHost;
        try transition.request(self.world.allocator, self.resources, file);
    }

    test {
        _ = @import("transition.zig");
        _ = @import("stream.zig");
        _ = @import("loading_screen.zig");
    }
};

test "scene instantiation reports missing context rather than manufacturing a root" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    var made = instances.SceneInstances.init(std.testing.allocator);
    defer made.deinit();
    const scenes = Scenes{ .world = &world, .instances = &made, .resources = .{}, .access = null };
    try std.testing.expectError(error.NoSceneRegistry, scenes.instantiate(.init("level.scene.zon"), .{}));
}
