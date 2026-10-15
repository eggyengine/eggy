//! The buttons floating at the top left of the Scene panel: which gizmo the selected entity
//! gets (Move, Rotate, Scale), and whether the scene is seen through the game's camera.
const std = @import("std");
const ui = @import("eggy").ui;
const L = ui.Layout;
const Tool = @import("gizmo.zig").Tool;

pub const Button = enum(u32) { move, rotate, scale, game_camera };

/// What the buttons show: the tool picked, and whether the game's camera is looked through.
pub const State = struct {
    tool: Tool = .move,
    through_game_camera: bool = false,
};

/// Button `b`'s element id: `first_id` plus the button, below the dock's ids.
const first_id: u32 = 0x5100_0000;

/// The button element `id` is, if it is one of these.
pub fn buttonOf(id: u32) ?Button {
    if (id < first_id) return null;
    return std.enums.fromInt(Button, id - first_id);
}

/// The buttons over the Scene panel at `scene`, floating above it.
pub fn element(b: L.Builder, state: State, scene: ui.Rect) !*L.Element {
    var buttons: [std.enums.values(Button).len]*L.Element = undefined;
    for (&buttons, std.enums.values(Button)) |*slot, button| {
        const pressed = switch (button) {
            .move => state.tool == .move,
            .rotate => state.tool == .rotate,
            .scale => state.tool == .scale,
            .game_camera => state.through_game_camera,
        };
        const label = switch (button) {
            .move => "Move",
            .rotate => "Rotate",
            .scale => "Scale",
            .game_camera => "Game camera",
        };
        slot.* = try b.node(first_id + @intFromEnum(button), .{ .height = 26 }, .{ .toggle_button = .{ .label = label, .pressed = pressed } }, &.{});
        slot.*.cursor = .pointer;
        slot.*.accessibility = .{ .role = .button, .label = label };
    }
    const row = try b.node(0, .{ .direction = .row, .gap = 4, .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 }, .z_index = 20 }, .{ .surface = .popover }, &buttons);
    row.overlay = .{ .point = .init(scene.x + 8, scene.y + 8) };
    return row;
}

test "every button is told apart by its id, and other ids are none of them" {
    try std.testing.expectEqual(Button.scale, buttonOf(first_id + 2).?);
    try std.testing.expect(buttonOf(first_id + 9) == null);
    try std.testing.expect(buttonOf(12) == null);
}
