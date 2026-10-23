//! Plain values shared by input snapshots and host input services.
const std = @import("std");
const sdl = @import("vitellus_sdl3").sdl;

pub const Key = sdl.Scancode;
pub const MouseButton = enum { left, middle, right, x1, x2 };
pub const DirectionKeys = struct { left: Key = .a, right: Key = .d, down: Key = .s, up: Key = .w };
pub const key_count = 512;
pub const KeySet = std.StaticBitSet(key_count);
pub const Controller = enum(u32) { _ };
pub const ControllerButton = enum {
    south,
    east,
    west,
    north,
    left_shoulder,
    right_shoulder,
    left_stick,
    right_stick,
    start,
    back,
    up,
    down,
    left,
    right,
    guide,
    misc1,
    misc2,
    misc3,
    misc4,
    misc5,
    misc6,
    left_paddle1,
    right_paddle1,
    left_paddle2,
    right_paddle2,
    touchpad,
};
pub const ControllerState = struct {
    buttons: std.EnumSet(ControllerButton) = .empty,
    buttons_pressed: std.EnumSet(ControllerButton) = .empty,
    buttons_released: std.EnumSet(ControllerButton) = .empty,
    /// Sticks are normalized to -1..1, with right/down positive. No hidden dead zone.
    left_stick: [2]f32 = .{ 0, 0 },
    right_stick: [2]f32 = .{ 0, 0 },
    /// Left and right trigger pressures, 0..1.
    triggers: [2]f32 = .{ 0, 0 },
    rumble_supported: bool = false,
};
pub const Touch = struct {
    id: u64,
    position_points: [2]f32,
    pressure: f32,
    delta_points: [2]f32 = .{ 0, 0 },
    phase: enum { began, stationary, moved, ended, cancelled } = .began,
};
pub const TouchKey = struct { device: u64, finger: u64 };
pub const Kind = enum { button, axis, vector };
pub const MapDefaults = struct { priority: i32 = 0, enabled: bool = true };
pub const Stick = enum { left, right };
pub const Trigger = union(enum) {
    immediate,
    hold: f32,
    tap: f32,
    /// A button control in the same map; its held or pulse state gates this control.
    chord: []const u8,
};
pub const Binding = union(enum) {
    key: Key,
    mouse: MouseButton,
    /// Null selects any connected controller; physical IDs are for runtime-only bindings.
    controller: struct { device: ?Controller = null, button: ControllerButton },
    key_axis: struct { negative: Key, positive: Key, scale: f32 = 1 },
    keys_2d: struct { keys: DirectionKeys = .{}, normalize: bool = true, scale: [2]f32 = .{ 1, 1 } },
    controller_axis: struct { device: ?Controller = null, axis: sdl.gamepad.Axis, dead_zone: f32 = 0.15, scale: f32 = 1 },
    controller_stick: struct { device: ?Controller = null, stick: Stick = .left, dead_zone: f32 = 0.15, scale: [2]f32 = .{ 1, 1 } },
    mouse_delta: struct { scale: [2]f32 = .{ 1, 1 } },
    mouse_wheel: struct { scale: f32 = 1 },
};
pub const ControlState = struct { held: bool = false, pressed: bool = false, released: bool = false };
pub const Value = union(Kind) { button: ControlState, axis: f32, vector: [2]f32 };

/// Defaults declared by a game/plugin. Project overrides use its published owner and tag name.
/// `Controls` is the plugin's controls enum; each entry names one control, its value kind,
/// trigger and borrowed binding defaults. The host copies entries during registration.
///
/// ```zig
/// const Controls = enum { jump };
/// const jump: eggy.input.ControlBinding(Controls) = .{
///     .control = .jump, .bindings = &.{.{ .key = .space }},
/// };
/// ```
pub fn ControlBinding(comptime Controls: type) type {
    return struct { control: Controls, kind: Kind = .button, trigger: Trigger = .immediate, bindings: []const Binding };
}

pub const Buttons = struct { keys: KeySet, mouse: std.EnumSet(MouseButton), mouse_delta: [2]f32 = .{ 0, 0 }, wheel: f32 = 0 };
pub const GameEvent = struct { event: sdl.events.Event, buttons: Buttons, viewport_points: [2]f32 };
pub const ControlId = extern struct { type_marker: usize, tag: u64 };
pub const ControlDefinition = struct { tag: u64, name: []const u8, kind: Kind = .button, trigger: Trigger = .immediate, bindings: []const Binding };
pub const Registration = struct { type_marker: usize, owner: []const u8, priority: i32 = 0, enabled: bool = true, consume: bool = true, controls: []const ControlDefinition };
