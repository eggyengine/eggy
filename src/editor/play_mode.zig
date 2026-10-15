//! Play mode: the game runs (its `update` hooks, the world's systems, input events) only while
//! playing; otherwise only its editor tools do (`editorUpdate`), so nothing changes by itself.
//! Play keeps the scene as it was, and Stop starts the game over on it: whatever happened while
//! playing, every value goes back.
const std = @import("std");
const eggy = @import("eggy");
const HotGame = @import("hot_reload/hot_reload.zig").HotGame;

pub const PlayMode = struct {
    /// The scene as it was when play began; null while not playing.
    before: ?eggy.scene.Scene = null,

    pub fn deinit(self: *PlayMode) void {
        if (self.before) |*scene| scene.deinit();
    }

    pub fn playing(self: *const PlayMode) bool {
        return self.before != null;
    }

    /// Start playing: keep the scene as it is now, from its top-level entities `roots` in order,
    /// for `stop`.
    pub fn play(self: *PlayMode, gpa: std.mem.Allocator, app: *eggy.App, game: *const HotGame, roots: []const eggy.ecs.EntityId) !void {
        if (self.before != null) return;
        self.before = try eggy.scene.Scene.capture(gpa, &app.world, game.sceneAccess(), roots);
    }

    /// Stop playing: the game starts over on the scene kept by `play`, with the plugins keyed in
    /// `off` turned off.
    pub fn stop(self: *PlayMode, app: *eggy.App, game: *HotGame, off: []const []const u8) void {
        var scene = self.before orelse return;
        self.before = null;
        defer scene.deinit();
        game.restart(app, &scene, off);
    }
};
