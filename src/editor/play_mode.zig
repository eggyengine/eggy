//! Play mode: the game runs (its `update` hooks, the world's systems, input events) only while
//! playing and not paused; otherwise only its editor tools do (`editorUpdate`), so nothing
//! changes by itself. Play keeps the scene as it was and starts the game over on it, as it starts
//! when shipped; Stop starts it over again, keeping none of what play made (not even what the
//! plugins' `init` spawned): whatever happened while playing, every value and entity goes back.
//! The configured Stop key (Escape by default) stops Play or Simulate. Ctrl+Shift+K keeps the selected
//! entity's `Transform` as it is while playing (`keepTransform`): Stop puts the scene back with
//! that one change.
const std = @import("std");
const eggy = @import("eggy");
const HotGame = @import("hot_reload/hot_reload.zig").HotGame;

pub const PlayMode = struct {
    /// The scene as it was when play began; null while not playing.
    before: ?eggy.scene.Scene = null,
    /// Whether play is paused: the game is held where it is until resumed.
    paused: bool = false,

    /// Free the editor's pre-play snapshot without restarting/restoring the game.
    /// Shutdown-only cleanup; call `stop` instead to leave a still-running editor in edit mode.
    ///
    /// ```zig
    /// var mode = PlayMode{};
    /// defer mode.deinit(); // Host teardown after the game's final use.
    /// ```
    pub fn deinit(self: *PlayMode) void {
        if (self.before) |*scene| scene.deinit();
    }

    /// Whether the host has a saved pre-play scene, including while paused.
    /// Pure query; `running` additionally checks pause state.
    ///
    /// ```zig
    /// if (mode.playing()) mode.stop(app, game, switches.off());
    /// ```
    pub fn playing(self: *const PlayMode) bool {
        return self.before != null;
    }

    /// Whether the game runs this frame: playing, and not paused.
    /// Editor-host scheduling query; does not itself invoke game hooks or step the world.
    ///
    /// ```zig
    /// const simulate_game = mode.running();
    /// _ = simulate_game; // Host uses this to gate gameplay update/input.
    /// ```
    pub fn running(self: *const PlayMode) bool {
        return self.playing() and !self.paused;
    }

    /// Reserve one non-repeated press of the configured key for Stop, even while paused.
    /// Call before routing keys into editor navigation or game UI.
    pub fn stopPressed(self: *const PlayMode, event: eggy.Event, key: eggy.Key) bool {
        return self.playing() and event == .key_down and !event.key_down.repeat and event.key_down.scancode == key;
    }

    /// Start playing: keep the scene as it is now, from its top-level entities `roots` in order,
    /// for `stop`, and start the game over on it, as the shipped game starts (its plugins'
    /// `init` running, keeping what they spawn).
    /// Editor-host only: `game` must be loaded/started against this app; `roots` are current
    /// world's top-level IDs and `off` the plugin keys to disable. Borrows the slices,
    /// owns a captured snapshot until stop/deinit, and invalidates old world entity IDs; each of
    /// `follow` is rewritten to the entity made from it (one not in the scene keeps its id).
    /// Already playing is a no-op; capture/allocation errors propagate.
    ///
    /// ```zig
    /// try mode.play(gpa, app, game, root_ids, switches.off(), &.{});
    /// // Later, after gameplay frames:
    /// mode.stop(app, game, switches.off());
    /// ```
    pub fn play(self: *PlayMode, gpa: std.mem.Allocator, app: *eggy.App, game: *HotGame, roots: []const eggy.ecs.EntityId, off: []const []const u8, follow: []eggy.ecs.EntityId) !void {
        if (self.before != null) return;
        self.before = try eggy.scene.Scene.capture(gpa, &app.world, game.sceneAccess(), roots);
        // Its entities are made anew: the scene's sources follow them, for `keepTransform`.
        const made = game.restartMaking(app, &self.before.?, off, .keep);
        defer gpa.free(made);
        if (made.len != self.before.?.sources.len) return;
        for (follow) |*entity| for (self.before.?.sources, made) |source, new| if (source.eql(entity.*)) {
            entity.* = new;
            break;
        };
        @memcpy(@constCast(self.before.?.sources), made);
    }

    /// Keep `entity`'s `Transform` as it is now in the scene that `stop` puts back. Returns
    /// false, keeping nothing, when not playing, or the entity began during play or has no
    /// `Transform`.
    /// Borrows the live app/library; `entity` must refer to the current play world.
    /// Mutates only the saved snapshot, not the running entity; allocation failures propagate.
    ///
    /// ```zig
    /// if (try mode.keepTransform(app, game, selected))
    ///     std.log.info("Transform will survive Stop", .{});
    /// ```
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
    /// No-op outside play. Recreates world entities (invalidating play IDs), discards entities
    /// spawned by plugin init, frees the snapshot, and clears pause state.
    ///
    /// ```zig
    /// mode.stop(app, game, switches.off()); // Editor Stop action.
    /// ```
    pub fn stop(self: *PlayMode, app: *eggy.App, game: *HotGame, off: []const []const u8) void {
        var scene = self.before orelse return;
        self.before = null;
        self.paused = false;
        defer scene.deinit();
        game.restart(app, &scene, off, .discard);
    }
};

test "one configured Stop press exits play or paused simulation without key repeats" {
    var mode = PlayMode{};
    var event = eggy.Event{ .key_down = .{ .common = .{ .timestamp = 0 }, .id = null, .scancode = .escape, .key = .escape, .mod = .{}, .raw = 0, .down = true, .repeat = false } };
    try std.testing.expect(!mode.stopPressed(event, .escape));
    mode.before = undefined; // playing, as far as `playing` can tell
    try std.testing.expect(mode.stopPressed(event, .escape));
    try std.testing.expect(!mode.stopPressed(event, .func8));
    mode.paused = true;
    event.key_down.scancode = .func8;
    try std.testing.expect(mode.stopPressed(event, .func8));
    event.key_down.repeat = true;
    try std.testing.expect(!mode.stopPressed(event, .func8));
    try std.testing.expect(!mode.stopPressed(.{ .key_up = event.key_down }, .func8));
    mode.before = null;
}
