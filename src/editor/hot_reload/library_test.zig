//! Hot reload for real, with Eggy's own (empty) game's library: load it, run a frame, swap it,
//! and unload it. The game's hooks only reach the world, so no window or GPU is needed.
const std = @import("std");
const eggy = @import("eggy");
const HotGame = @import("hot_reload.zig").HotGame;

test "the game's library loads, runs, swaps for a fresh copy, and unloads cleanly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const path = try std.fs.path.resolve(gpa, &.{@import("test_library").path});
    defer gpa.free(path);
    var app: eggy.App = undefined;
    app.world = .init(gpa);
    app.instances = null;
    app.scene_access = null;
    defer app.world.deinit();
    app.preference_values = .init(gpa);
    defer app.preference_values.deinit();

    var game = try HotGame.load(gpa, path);
    game.start(&app, &.{}, .keep);
    game.update(&app);
    try std.testing.expect(game.state != null);
    const first_copy = try gpa.dupe(u8, game.copy_path);
    defer gpa.free(first_copy);

    // A swap loads a copy of its own and deletes the old one.
    try game.reload(&app);
    game.start(&app, &.{}, .keep);
    game.update(&app);
    try std.testing.expect(game.state != null);
    try std.testing.expect(!std.mem.eql(u8, first_copy, game.copy_path));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, first_copy, .{}));

    const last_copy = try gpa.dupe(u8, game.copy_path);
    defer gpa.free(last_copy);
    game.deinit(&app);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, last_copy, .{}));
}
