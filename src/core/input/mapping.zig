//! Typed map declarations and binding modifier rules.
const std = @import("std");
const t = @import("types.zig");

pub fn Map(comptime Controls: type, comptime options: struct {
    key: []const u8,
    controls: []const t.ControlBinding(Controls),
    priority: i32 = 0,
    enabled: bool = true,
    consume: bool = true,
}) type {
    if (@typeInfo(Controls) != .@"enum") @compileError("input maps use a controls enum");
    if (options.key.len == 0) @compileError("input maps need a stable key");
    return struct {
        pub const Control = Controls;
        pub const key = options.key;
        pub const definitions = options.controls;
        pub const priority = options.priority;
        pub const enabled = options.enabled;
        pub const consume = options.consume;
    };
}

pub fn kind(binding: t.Binding) t.Kind {
    return switch (binding) {
        .key, .mouse, .controller => .button,
        .key_axis, .controller_axis, .mouse_wheel => .axis,
        .keys_2d, .controller_stick, .mouse_delta => .vector,
    };
}
pub fn validateTrigger(control_kind: t.Kind, trigger: t.Trigger) !void {
    if (control_kind != .button and trigger != .immediate) return error.InvalidTrigger;
    switch (trigger) {
        .immediate => {},
        .hold, .tap => |seconds| if (!std.math.isFinite(seconds) or seconds < 0) return error.InvalidTrigger,
        .chord => |name| if (name.len == 0) return error.InvalidTrigger,
    }
}
pub fn deadZone(value: f32, dead_zone: f32) f32 {
    if (@abs(value) <= dead_zone) return 0;
    return std.math.sign(value) * (@abs(value) - dead_zone) / (1 - dead_zone);
}
pub fn stick(value: [2]f32, dead_zone: f32) [2]f32 {
    const length = @sqrt(value[0] * value[0] + value[1] * value[1]);
    if (length <= dead_zone) return .{ 0, 0 };
    const scale = (@min(length, 1) - dead_zone) / ((1 - dead_zone) * length);
    return .{ value[0] * scale, value[1] * scale };
}
pub fn usesKey(binding: t.Binding, key: t.Key) bool {
    return switch (binding) {
        .key => |value| value == key,
        .key_axis => |value| value.negative == key or value.positive == key,
        .keys_2d => |value| value.keys.left == key or value.keys.right == key or value.keys.up == key or value.keys.down == key,
        else => false,
    };
}
pub fn usesButton(binding: t.Binding, device: u32, button: t.ControllerButton) bool {
    return switch (binding) {
        .controller => |value| (value.device == null or @intFromEnum(value.device.?) == device) and value.button == button,
        else => false,
    };
}
pub fn usesAxis(binding: t.Binding, device: u32, axis: @import("vitellus_sdl3").sdl.gamepad.Axis) bool {
    return switch (binding) {
        .controller_axis => |value| (value.device == null or @intFromEnum(value.device.?) == device) and value.axis == axis,
        .controller_stick => |value| (value.device == null or @intFromEnum(value.device.?) == device) and switch (axis) {
            .left_x, .left_y => value.stick == .left,
            .right_x, .right_y => value.stick == .right,
            else => false,
        },
        else => false,
    };
}
