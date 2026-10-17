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

test "typed controls aggregate devices and report exact buffer/disconnect errors" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    var input = input_api.Input{ .backend = state.interface() };
    try input.registerMap(Player, "game/player");
    const player = input.map(Player);
    try key(&input, .space, true);
    try std.testing.expect(try player.pressed(.jump));
    input.endFrame();
    try state.addController(7, .{});
    try input.handle(.{ .gamepad_button_down = .{ .common = undefined, .id = .{ .value = 7 }, .button = .south, .down = true } });
    try std.testing.expect(!try player.pressed(.jump));
    try key(&input, .space, false);
    try std.testing.expect(try player.held(.jump));
    try std.testing.expect(!try player.released(.jump));
    var empty: [0]input_api.Controller = .{};
    try std.testing.expectError(error.BufferTooSmall, input.controllers(&empty));
    var devices: [1]input_api.Controller = undefined;
    try std.testing.expectEqual(@as(usize, 1), (try input.controllers(&devices)).len);
    state.removeController(7);
    try std.testing.expect(try player.released(.jump));
    try std.testing.expectEqual(@as(usize, 0), try input.controllerCount());
    try std.testing.expectError(error.ControllerDisconnected, input.controllerState(@enumFromInt(7)));
    try std.testing.expectError(error.WrongControlKind, player.axis(.jump));
}

test "vectors normalize digital diagonals and apply mouse/stick modifiers" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    var input = input_api.Input{ .backend = state.interface() };
    try input.registerMap(Player, "game/player");
    const player = input.map(Player);
    try key(&input, .w, true);
    try key(&input, .d, true);
    const movement = try player.vector(.move);
    try std.testing.expectApproxEqAbs(@as(f32, 1), @sqrt(movement.x * movement.x + movement.y * movement.y), 1e-6);
    try std.testing.expect(movement.x > 0 and movement.y < 0);
    try input.handle(.{ .mouse_motion = .{ .common = undefined, .state = .fromSdl(0), .x = 10, .y = 20, .x_rel = 4, .y_rel = -2 } });
    const look = try player.vector(.look);
    try std.testing.expectEqual(@as(f32, 2), look.x);
    try std.testing.expectEqual(@as(f32, -0.5), look.y);
    input.endFrame();
    try std.testing.expectEqual(@as(f32, 0), (try player.vector(.look)).x);
    try state.addController(7, .{});
    try input.handle(.{ .gamepad_axis_motion = .{ .common = undefined, .id = .{ .value = 7 }, .axis = .left_trigger, .value = 32767 } });
    try std.testing.expectApproxEqAbs(@as(f32, 1), try player.axis(.throttle), 1e-6);
    try input.handle(.{ .gamepad_axis_motion = .{ .common = undefined, .id = .{ .value = 7 }, .axis = .left_trigger, .value = 1000 } });
    try std.testing.expectEqual(@as(f32, 0), try player.axis(.throttle));
}

test "hold tap and chord triggers have explicit thresholds and reject cycles" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    var input = input_api.Input{ .backend = state.interface() };
    try input.registerMap(Player, "game/player");
    const player = input.map(Player);
    try key(&input, .r, true);
    try state.advance(0.125);
    try std.testing.expect(!try player.pressed(.charge));
    try state.advance(0.125);
    try std.testing.expect(try player.pressed(.charge));
    input.endFrame();
    try state.advance(0.5);
    try std.testing.expect(try player.held(.charge) and !try player.pressed(.charge));
    try key(&input, .r, false);
    try std.testing.expect(try player.released(.charge));
    try key(&input, .t, true);
    try state.advance(0.125);
    try key(&input, .t, false);
    try std.testing.expect(try player.pressed(.tap));
    input.endFrame();
    try key(&input, .t, true);
    try state.advance(0.25);
    try key(&input, .t, false);
    try std.testing.expect(!try player.pressed(.tap));
    try key(&input, .f, true);
    try std.testing.expect(!try player.held(.fire));
    try key(&input, .left_shift, true);
    try std.testing.expect(try player.pressed(.fire));
    try key(&input, .left_shift, false);
    try std.testing.expect(try player.released(.fire));
    try std.testing.expectError(error.InvalidTrigger, state.setMappings(.{ .type_marker = marker.of(Player), .tag = @intFromEnum(Player.Control.fire) }, &.{.{ .key = .f }}, .{ .chord = "fire" }));
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

test "touch IDs are stable and quick taps survive until the frame ends" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    var input = input_api.Input{ .backend = state.interface(), .viewport_points = .{ 200, 100 } };
    var finger = sdl.events.TouchFinger{ .common = undefined, .id = .{ .value = 1 }, .finger_id = .{ .value = 2 }, .x = 0.5, .y = 0.25, .dx = 0, .dy = 0, .pressure = 1 };
    try input.handle(.{ .finger_down = finger });
    var touches: [1]input_api.Touch = undefined;
    const id = (try input.touches(&touches))[0].id;
    try std.testing.expectEqual([2]f32{ 100, 25 }, touches[0].position_points);
    finger.x = 0.75;
    finger.dx = 0.25;
    try input.handle(.{ .finger_motion = finger });
    try std.testing.expectEqual(id, (try input.touches(&touches))[0].id);
    try input.handle(.{ .finger_up = finger });
    try std.testing.expectEqual(@as(usize, 1), try input.touchCount());
    try std.testing.expectEqual(@as(@TypeOf(touches[0].phase), .ended), (try input.touches(&touches))[0].phase);
    input.endFrame();
    try std.testing.expectEqual(@as(usize, 0), try input.touchCount());
}

test "project map defaults survive registration and reset without persisting runtime switches" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    try state.readOverrides(".{ .maps = .{ .{ .owner = \"game/player\", .enabled = false, .priority = 12 } } }");
    var input = input_api.Input{ .backend = state.interface() };
    try input.registerMap(Player, "game/player");
    const map_id = marker.of(Player);
    try std.testing.expect(!state.owners.get(map_id).?.enabled);
    try std.testing.expectEqual(@as(i32, 12), state.owners.get(map_id).?.priority);
    try input.map(Player).setEnabled(true);
    try input.map(Player).setPriority(99);
    try std.testing.expectEqual(@as(i32, 12), state.overrides.maps.get("game/player").?.priority);
    try state.setMapDefaults(map_id, null);
    try std.testing.expect(state.owners.get(map_id).?.enabled);
    try std.testing.expectEqual(@as(i32, 0), state.owners.get(map_id).?.priority);
}
