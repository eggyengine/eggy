//! Play mode: the game runs (its `update` hooks, the world's systems, input events) only while
//! playing and not paused; otherwise only its editor tools do (`editorUpdate`), so nothing
//! changes by itself. Play keeps the scene as it was and starts the game over on it, as it starts
//! when shipped; Stop starts it over again, keeping none of what play made (not even what the
//! plugins' `init` spawned): whatever happened while playing, every value and entity goes back. Three presses of Escape in a row
//! (`escape_presses` within `escape_window_ms`) stop it too. Ctrl+Shift+K keeps the selected
//! entity's `Transform` as it is while playing (`keepTransform`): Stop puts the scene back with
//! that one change.
const std = @import("std");
const eggy = @import("eggy");
const HotGame = @import("hot_reload/hot_reload.zig").HotGame;

/// How many presses of Escape, each within `escape_window_ms` of the last, stop play.
pub const escape_presses = 3;
const escape_window_ms = 600;

pub const PlayMode = struct {
    /// The scene as it was when play began; null while not playing.
    before: ?eggy.scene.Scene = null,
    /// Whether play is paused: the game is held where it is until resumed.
    paused: bool = false,
    /// Escape presses in a row while playing, and when the last one was.
    escapes: u8 = 0,
    last_escape_ms: u64 = 0,

    pub fn deinit(self: *PlayMode) void {
        if (self.before) |*scene| scene.deinit();
    }

    pub fn playing(self: *const PlayMode) bool {
        return self.before != null;
    }

    /// Whether the game runs this frame: playing, and not paused.
    pub fn running(self: *const PlayMode) bool {
        return self.playing() and !self.paused;
    }

    /// Count a press of Escape at `now_ms`; true when it makes `escape_presses` in a row while
    /// playing, which should stop play.
    pub fn escapePressed(self: *PlayMode, now_ms: u64) bool {
        if (!self.playing()) return false;
        self.escapes = if (now_ms -| self.last_escape_ms <= escape_window_ms) self.escapes + 1 else 1;
        self.last_escape_ms = now_ms;
        if (self.escapes < escape_presses) return false;
        self.escapes = 0;
        return true;
    }

    /// Start playing: keep the scene as it is now, from its top-level entities `roots` in order,
    /// for `stop`, and start the game over on it, as the shipped game starts (its plugins'
    /// `init` running, keeping what they spawn).
    pub fn play(self: *PlayMode, gpa: std.mem.Allocator, app: *eggy.App, game: *HotGame, roots: []const eggy.ecs.EntityId, off: []const []const u8) !void {
        if (self.before != null) return;
        self.before = try eggy.scene.Scene.capture(gpa, &app.world, game.sceneAccess(), roots);
        // Its entities are made anew: the scene's sources follow them, for `keepTransform`.
        const made = game.restartMaking(app, &self.before.?, off, .keep);
        defer gpa.free(made);
        if (made.len == self.before.?.sources.len) @memcpy(@constCast(self.before.?.sources), made);
    }

    /// Keep `entity`'s `Transform` as it is now in the scene that `stop` puts back. Returns
    /// false, keeping nothing, when not playing, or the entity began during play or has no
    /// `Transform`.
    pub fn keepTransform(self: *PlayMode, app: *eggy.App, game: *const HotGame, entity: eggy.ecs.EntityId) !bool {
        const scene = if (self.before) |*kept| kept else return false;
        const place = for (scene.sources, 0..) |source, i| {
            if (source.eql(entity)) break i;
        } else return false;
        const access = game.sceneAccess();
        const component = for (access.types(), 0..) |info, i| {
            if (std.mem.eql(u8, info.name, "Transform") and std.mem.eql(u8, info.owner, "eggy")) break i;
        } else return false;
        if (!access.has(&app.world, entity, component)) return false;

        // Its fields as they are now, in the scene's own memory.
        const arena = scene.arena.allocator();
        const info = access.types()[component];
        const fields = try arena.alloc(eggy.scene.Scene.Field, info.fields.len);
        for (fields, info.fields, 0..) |*field, field_info, index| {
            var buffer: [4096]u8 = undefined;
            const value = access.readField(&app.world, entity, component, index, &buffer) orelse return false;
            field.* = .{ .name = field_info.name, .value = try arena.dupe(u8, value) };
        }
        // In place of the Transform it had when play began, or added if it had none.
        const kept_entity = &@constCast(scene.entities)[place];
        for (@constCast(kept_entity.components)) |*kept| {
            if (std.mem.eql(u8, kept.type, info.name) and std.mem.eql(u8, kept.owner, info.owner)) {
                kept.fields = fields;
                return true;
            }
        }
        kept_entity.components = try std.mem.concat(arena, eggy.scene.Scene.Component, &.{ kept_entity.components, &.{.{ .type = info.name, .owner = info.owner, .fields = fields }} });
        return true;
    }

    /// Stop playing: the game starts over on the scene kept by `play`, with the plugins keyed in
    /// `off` turned off.
    pub fn stop(self: *PlayMode, app: *eggy.App, game: *HotGame, off: []const []const u8) void {
        var scene = self.before orelse return;
        self.before = null;
        self.paused = false;
        self.escapes = 0;
        defer scene.deinit();
        game.restart(app, &scene, off, .discard);
    }
};

test "three quick presses of Escape stop play, slow ones don't" {
    var mode = PlayMode{};
    try std.testing.expect(!mode.escapePressed(0)); // not playing
    mode.before = undefined; // playing, as far as `playing` can tell
    try std.testing.expect(!mode.escapePressed(1000));
    try std.testing.expect(!mode.escapePressed(1300));
    try std.testing.expect(mode.escapePressed(1600));
    try std.testing.expect(!mode.escapePressed(5000));
    try std.testing.expect(!mode.escapePressed(6000));
    try std.testing.expect(!mode.escapePressed(7000));
    mode.before = null;
}
