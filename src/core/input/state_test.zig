//! Logical input tests independent of physical hardware or a graphical window.
const std = @import("std");
const input_api = @import("input.zig");
const State = @import("state.zig").State;
const sdl = @import("vitellus_sdl3").sdl;
const marker = @import("../type_marker.zig");

const Player = input_api.Map(enum { jump, move, look, charge, tap, modifier, fire, throttle }, .{
    .key = "player",
    .controls = &.{
        .{ .control = .jump, .bindings = &.{ .{ .key = .space }, .{ .controller = .{ .button = .south } } } },
        .{ .control = .move, .kind = .vector, .bindings = &.{ .{ .keys_2d = .{} }, .{ .controller_stick = .{} } } },
        .{ .control = .look, .kind = .vector, .bindings = &.{.{ .mouse_delta = .{ .scale = .{ 0.5, 0.25 } } }} },
        .{ .control = .charge, .trigger = .{ .hold = 0.25 }, .bindings = &.{.{ .key = .r }} },
        .{ .control = .tap, .trigger = .{ .tap = 0.2 }, .bindings = &.{.{ .key = .t }} },
        .{ .control = .modifier, .bindings = &.{.{ .key = .left_shift }} },
        .{ .control = .fire, .trigger = .{ .chord = "modifier" }, .bindings = &.{.{ .key = .f }} },
        .{ .control = .throttle, .kind = .axis, .bindings = &.{.{ .controller_axis = .{ .axis = .left_trigger, .dead_zone = 0.2 } }} },
    },
});
fn key(input: *input_api.Input, code: input_api.Key, down: bool) !void {
    const event = sdl.events.Keyboard{ .common = undefined, .id = null, .scancode = code, .key = null, .mod = .{}, .raw = 0, .down = down, .repeat = false };
    try input.handle(if (down) .{ .key_down = event } else .{ .key_up = event });
}

test "file maps match enum names, coexist with code maps and retain project overrides" {
    const FilePlayer = input_api.FileMap(enum(u8) { jump = 7, move = 12 }, .{ .key = "file-player", .file = "resources/player.inmap.zon" });
    const FileMenu = input_api.FileMap(enum { accept }, .{ .key = "file-menu", .file = "resources/menu.inmap.zon" });
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    try state.readOverrides(".{ .controls = .{ .{ .owner = \"game/file-player\", .name = \"jump\", .bindings = .{ .{ .key = .j } } } } }");
    var input = input_api.Input{ .backend = state.interface() };
    try input.registerMap(Player, "game/player");
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const player = try input_api.asset.File.parse(arena.allocator(),
            \\.{ .controls = .{
            \\    .{ .name = "move", .kind = .vector, .bindings = .{ .{ .keys_2d = .{} } } },
            \\    .{ .name = "jump", .bindings = .{ .{ .key = .space } } },
            \\} }
        );
        const menu = try input_api.asset.File.parse(arena.allocator(),
            \\.{ .priority = 10, .enabled = false, .controls = .{ .{ .name = "accept", .bindings = .{ .{ .key = .e } } } } }
        );
        try input.registerFileMap(FilePlayer, "game/file-player", player);
        try input.registerFileMap(FileMenu, "game/file-menu", menu);
    }
    try std.testing.expectEqual(@as(usize, 3), state.owners.count());
    var bindings: [2]input_api.Binding = undefined;
    try std.testing.expectEqual(input_api.Key.j, (try input.map(FilePlayer).getBindings(.jump, &bindings))[0].key);
    try std.testing.expectEqual(input_api.Key.e, (try input.map(FileMenu).getBindings(.accept, &bindings))[0].key);
    try std.testing.expectEqual(input_api.Key.space, (try input.map(Player).getBindings(.jump, &bindings))[0].key);
    try key(&input, .j, true);
    try std.testing.expect(try input.map(FilePlayer).pressed(.jump));
    try key(&input, .w, true);
    try std.testing.expectEqual(@as(f32, -1), (try input.map(FilePlayer).vector(.move)).y);
    try std.testing.expectError(error.InputMapControlsMismatch, input.registerFileMap(FilePlayer, "game/file-player", .{ .controls = &.{.{ .name = "jump" }} }));
    try std.testing.expectError(error.InputMapControlsMismatch, input.registerFileMap(FilePlayer, "game/file-player", .{ .controls = &.{ .{ .name = "jump" }, .{ .name = "unknown" } } }));
    try std.testing.expectEqual(@as(usize, 3), state.owners.count());
    try std.testing.expectEqual(input_api.Key.j, (try input.map(FilePlayer).getBindings(.jump, &bindings))[0].key);
    try input.map(FilePlayer).resetBindings(.jump);
    try std.testing.expectEqual(input_api.Key.space, (try input.map(FilePlayer).getBindings(.jump, &bindings))[0].key);
}

test "higher priority maps own overlapping sources and activation does not invent a press" {
    const Menu = input_api.Map(enum { accept }, .{
        .key = "menu",
        .priority = 10,
        .enabled = false,
        .controls = &.{.{ .control = .accept, .bindings = &.{.{ .key = .space }} }},
    });
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    var input = input_api.Input{ .backend = state.interface() };
    try input.registerMap(Player, "game/player");
    try input.registerMap(Menu, "game/menu");
    const player = input.map(Player);
    const menu = input.map(Menu);
    try menu.setEnabled(true);
    try key(&input, .space, true);
    try std.testing.expect(try menu.pressed(.accept));
    try std.testing.expect(!try player.pressed(.jump));
    try menu.setEnabled(false);
    try std.testing.expect(!try player.pressed(.jump));
    try key(&input, .space, false);
    try std.testing.expect(!try player.released(.jump));
    try key(&input, .space, true);
    try std.testing.expect(try player.pressed(.jump));
}
