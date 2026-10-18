//! Typed map declarations and binding modifier rules.
const std = @import("std");
const t = @import("types.zig");

/// Reference a complete `.inmap.zon` resource while keeping typed control names in game code.
/// Paths are project-relative resources; the stable key is independent of the file's name.
/// `Controls` must be an enum, the key nonempty and the file end in `.inmap.zon`.
/// This declares a type only; list it in a plugin's `input_maps` to register it before init.
///
/// ```zig
/// const Player = eggy.input.FileMap(enum { jump, move },
///     .{ .key = "player", .file = "resources/player.inmap.zon" });
/// pub const input_maps = .{Player}; // Inside Game or Plugin.
/// ```
pub fn FileMap(comptime Controls: type, comptime options: struct { key: []const u8, file: []const u8 }) type {
    if (@typeInfo(Controls) != .@"enum") @compileError("input maps use a controls enum");
    if (options.key.len == 0) @compileError("input maps need a stable key");
    if (!std.mem.endsWith(u8, options.file, ".inmap.zon")) @compileError("input map files end in .inmap.zon");
    return struct {
        pub const Control = Controls;
        pub const key = options.key;
        pub const file = options.file;
    };
}

/// Declare a typed map with code defaults; list the returned type in a plugin's `input_maps`.
/// `Controls` must be an enum and key nonempty. Higher consuming priorities block shared
/// sources; missing control entries default to unbound buttons. Defaults are copied on host
/// registration, where binding/trigger validity is checked.
///
/// ```zig
/// const Player = eggy.input.Map(enum { jump }, .{
///     .key = "player",
///     .controls = &.{.{ .control = .jump, .bindings = &.{.{ .key = .space }} }},
/// });
/// pub const input_maps = .{Player}; // Inside Game or Plugin.
/// ```
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

/// Host-only: classify the value a binding produces, without validating its payload.
///
/// ```zig
/// const value_kind = kind(.{ .key_axis = .{ .negative = .a, .positive = .d } }); // .axis
/// ```
pub fn kind(binding: t.Binding) t.Kind {
    return switch (binding) {
        .key, .mouse, .controller => .button,
        .key_axis, .controller_axis, .mouse_wheel => .axis,
        .keys_2d, .controller_stick, .mouse_delta => .vector,
    };
}
/// Host-only: reject non-immediate analog triggers, non-finite/negative hold or tap seconds,
/// and empty chord names with `InvalidTrigger`. Does not resolve chord names or detect cycles.
///
/// ```zig
/// try validateTrigger(.button, .{ .hold = 0.25 });
/// ```
pub fn validateTrigger(control_kind: t.Kind, trigger: t.Trigger) !void {
    if (control_kind != .button and trigger != .immediate) return error.InvalidTrigger;
    switch (trigger) {
        .immediate => {},
        .hold, .tap => |seconds| if (!std.math.isFinite(seconds) or seconds < 0) return error.InvalidTrigger,
        .chord => |name| if (name.len == 0) return error.InvalidTrigger,
    }
}
/// Host-only: remove a scalar dead zone and rescale the remainder to full travel.
/// Requires finite normalized `value` and `0 <= dead_zone < 1`; does not validate or clamp.
///
/// ```zig
/// const filtered = deadZone(0.5, 0.2); // 0.375.
/// ```
pub fn deadZone(value: f32, dead_zone: f32) f32 {
    if (@abs(value) <= dead_zone) return 0;
    return std.math.sign(value) * (@abs(value) - dead_zone) / (1 - dead_zone);
}
/// Host-only: apply a radial dead zone, preserving direction and capping output length at one.
/// Requires finite normalized components and `0 <= dead_zone < 1`; no allocation or validation.
///
/// ```zig
/// const filtered = stick(.{ 0.5, 0.0 }, 0.2);
/// ```
pub fn stick(value: [2]f32, dead_zone: f32) [2]f32 {
    const length = @sqrt(value[0] * value[0] + value[1] * value[1]);
    if (length <= dead_zone) return .{ 0, 0 };
    const scale = (@min(length, 1) - dead_zone) / ((1 - dead_zone) * length);
    return .{ value[0] * scale, value[1] * scale };
}
/// Host-only: whether a digital binding references this physical key, for source consumption.
/// Does not test whether the key is currently held.
///
/// ```zig
/// const overlaps = usesKey(.{ .keys_2d = .{} }, .w); // true.
/// ```
pub fn usesKey(binding: t.Binding, key: t.Key) bool {
    return switch (binding) {
        .key => |value| value == key,
        .key_axis => |value| value.negative == key or value.positive == key,
        .keys_2d => |value| value.keys.left == key or value.keys.right == key or value.keys.up == key or value.keys.down == key,
        else => false,
    };
}
/// Host-only: whether a controller-button binding matches this SDL device ID and button.
/// A binding without a device selector matches any device; does not inspect physical state.
///
/// ```zig
/// const overlaps = usesButton(.{ .controller = .{ .button = .south } }, 7, .south);
/// ```
pub fn usesButton(binding: t.Binding, device: u32, button: t.ControllerButton) bool {
    return switch (binding) {
        .controller => |value| (value.device == null or @intFromEnum(value.device.?) == device) and value.button == button,
        else => false,
    };
}
/// Host-only: whether an axis/stick binding uses this SDL device ID and physical axis.
/// Stick bindings match their X/Y pair, not trigger axes; null selectors match any device.
///
/// ```zig
/// const overlaps = usesAxis(.{ .controller_stick = .{} }, 7, .left_x);
/// ```
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
