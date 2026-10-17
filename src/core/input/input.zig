//! Input for game code: which keys and mouse buttons are held, which went down or up this frame,
//! where the pointer is and how far it moved, and how far the wheel turned. `app.input` has it
//! in hooks, and systems take `Res(eggy.Input)`. The runtime feeds it every event; the editor
//! only while the game plays. Keys are physical (`.w` is the key where W is on a US layout, on
//! any layout), so WASD works everywhere.
//!
//!     pub fn update(self: *Game, app: *eggy.App) !void {
//!         const ahead = app.input.axis(.s, .w); // -1, 0 or 1
//!         if (app.input.pressed(.space)) jump();
//!         if (app.input.mouseHeld(.right)) look(app.input.mouse_delta);
//!     }
const std = @import("std");
const sdl3 = @import("vitellus_sdl3").sdl;
const support = @import("../support.zig");
const types = @import("types.zig");
const protocol = @import("bridge.zig");
const marker = @import("../type_marker.zig");

/// A key, by where it is on the keyboard.
pub const Key = types.Key;

pub const MouseButton = types.MouseButton;

/// Four physical keys describing a two-dimensional direction.
pub const DirectionKeys = types.DirectionKeys;
pub const controller_support: support.Support = .available;
pub const touch_support: support.Support = .available;
pub const rebinding_support: support.Support = .available;
pub const Controller = types.Controller;
pub const ControllerButton = types.ControllerButton;
pub const ControllerState = types.ControllerState;
pub const Touch = types.Touch;
pub const Binding = types.Binding;
pub const ControlState = types.ControlState;
pub const ControlBinding = types.ControlBinding;
pub const Kind = types.Kind;
pub const Trigger = types.Trigger;
pub const Value = types.Value;
pub const ControlId = types.ControlId;
pub const Map = @import("mapping.zig").Map;
pub const bindings_file = @import("bindings.zig").file_name;

const key_count = types.key_count;
const KeySet = types.KeySet;

pub const Input = struct {
    /// Host-owned services; copied snapshots never own device handles or binding allocations.
    backend: ?protocol.Bridge = null,
    viewport_points: [2]f32 = .{ 1, 1 },
    keys_held: KeySet = .initEmpty(),
    keys_pressed: KeySet = .initEmpty(),
    keys_released: KeySet = .initEmpty(),
    buttons_held: std.EnumSet(MouseButton) = .initEmpty(),
    buttons_pressed: std.EnumSet(MouseButton) = .initEmpty(),
    buttons_released: std.EnumSet(MouseButton) = .initEmpty(),
    /// Where the pointer is in the window, in points from its top left corner.
    mouse_position: [2]f32 = .{ 0, 0 },
    /// How far it moved this frame, in points (right and down are positive).
    mouse_delta: [2]f32 = .{ 0, 0 },
    /// How far the wheel turned this frame, in notches (away from you is positive).
    wheel: f32 = 0,

    /// Whether `key` is down.
    pub fn held(self: *const Input, key: Key) bool {
        return self.keys_held.isSet(index(key) orelse return false);
    }

    /// Whether `key` went down this frame.
    pub fn pressed(self: *const Input, key: Key) bool {
        return self.keys_pressed.isSet(index(key) orelse return false);
    }

    /// Whether `key` came up this frame.
    pub fn released(self: *const Input, key: Key) bool {
        return self.keys_released.isSet(index(key) orelse return false);
    }

    /// -1 while `negative` is held, 1 while `positive` is, 0 with both or neither: one axis of
    /// movement from two keys, as `axis(.a, .d)` for left and right.
    pub fn axis(self: *const Input, negative: Key, positive: Key) f32 {
        return @as(f32, @floatFromInt(@intFromBool(self.held(positive)))) - @as(f32, @floatFromInt(@intFromBool(self.held(negative))));
    }

    /// Horizontal and vertical axes, each -1, 0 or 1. Diagonals are not normalized.
    pub fn direction(self: *const Input, keys: DirectionKeys) [2]f32 {
        return .{ self.axis(keys.left, keys.right), self.axis(keys.down, keys.up) };
    }

    /// Number of connected SDL gamepads. No connected devices is ordinary absence.
    pub fn controllerCount(self: *const Input) !usize {
        return (try self.send(.{ .operation = .controller_count })).count;
    }
    /// Copy IDs into caller storage; BufferTooSmall never silently truncates devices.
    pub fn controllers(self: *const Input, buffer: []Controller) ![]const Controller {
        const response = try self.send(.{ .operation = .controllers, .output = buffer.ptr, .count = buffer.len });
        return buffer[0..response.count];
    }
    pub fn controllerState(self: *const Input, device: Controller) !ControllerState {
        var state: ControllerState = undefined;
        _ = try self.send(.{ .operation = .controller_state, .device = @intFromEnum(device), .output = &state });
        return state;
    }
    /// Strengths are 0..1; zero duration/strength stops rumble. Calls stay on the host thread.
    pub fn rumble(self: *const Input, device: Controller, low: f32, high: f32, duration_s: f32) !void {
        if (!std.math.isFinite(low) or !std.math.isFinite(high) or low < 0 or low > 1 or high < 0 or high > 1) return error.InvalidRumble;
        if (!std.math.isFinite(duration_s) or duration_s < 0 or @as(f64, duration_s) * 1000 > std.math.maxInt(u32)) return error.InvalidDuration;
        _ = try self.send(.{ .operation = .rumble, .device = @intFromEnum(device), .low = @intFromFloat(@round(low * 65535)), .high = @intFromFloat(@round(high * 65535)), .duration_ms = @intFromFloat(@as(f64, duration_s) * 1000) });
    }
    pub fn touchCount(self: *const Input) !usize {
        return (try self.send(.{ .operation = .touch_count })).count;
    }
    /// Includes ended/cancelled contacts until endFrame, so quick taps are observable.
    pub fn touches(self: *const Input, buffer: []Touch) ![]const Touch {
        const response = try self.send(.{ .operation = .touches, .output = buffer.ptr, .count = buffer.len });
        return buffer[0..response.count];
    }

    /// Register a plugin's typed controls under its published key before init. Names/defaults
    /// are copied by the host; compilation-local markers are forgotten before library unload.
    pub fn registerControls(self: *Input, comptime Controls: type, owner: []const u8, defaults: []const ControlBinding(Controls)) !void {
        try self.registerType(Controls, marker.of(Controls), owner, defaults, 0, true, true);
    }

    pub fn registerMap(self: *Input, comptime Mapping: type, owner: []const u8) !void {
        try self.registerType(Mapping.Control, marker.of(Mapping), owner, Mapping.definitions, Mapping.priority, Mapping.enabled, Mapping.consume);
    }
    fn registerType(self: *Input, comptime Controls: type, type_id: usize, owner: []const u8, defaults: []const ControlBinding(Controls), priority: i32, enabled: bool, consume: bool) !void {
        const fields = @typeInfo(Controls).@"enum".fields;
        var definitions: [fields.len]types.ControlDefinition = undefined;
        inline for (fields, 0..) |field, i| {
            const control = @field(Controls, field.name);
            var bindings: []const Binding = &.{};
            var value_kind: Kind = .button;
            var trigger: Trigger = .immediate;
            var found = false;
            for (defaults) |entry| if (entry.control == control) {
                if (found) return error.DuplicateControls;
                bindings = entry.bindings;
                value_kind = entry.kind;
                trigger = entry.trigger;
                found = true;
            };
            definitions[i] = .{ .tag = controlId(control).tag, .name = field.name, .kind = value_kind, .trigger = trigger, .bindings = bindings };
        }
        const registration = types.Registration{ .type_marker = type_id, .owner = owner, .priority = priority, .enabled = enabled, .consume = consume, .controls = &definitions };
        _ = try self.send(.{ .operation = .register_controls, .data = &registration });
    }
    /// Borrow a named map for this input snapshot; gameplay references logical controls only.
    pub fn map(self: *const Input, comptime Mapping: type) MapView(Mapping) {
        return .{ .input = self };
    }
    /// Replace a control's mappings with one binding. Editor project changes are saved; the
    /// build bakes them into the runtime. Use setBindings to retain multiple input sources.
    pub fn rebind(self: *Input, control: anytype, binding: Binding) !void {
        try self.setBindings(control, &.{binding});
    }
    pub fn setBindings(self: *Input, control: anytype, bindings: []const Binding) !void {
        _ = try self.send(.{ .operation = .set_bindings, .control = controlId(control), .data = bindings.ptr, .count = bindings.len });
    }
    pub fn resetBindings(self: *Input, control: anytype) !void {
        _ = try self.send(.{ .operation = .reset_bindings, .control = controlId(control) });
    }
    pub fn getBindings(self: *const Input, control: anytype, buffer: []Binding) ![]const Binding {
        const response = try self.send(.{ .operation = .get_bindings, .control = controlId(control), .output = buffer.ptr, .count = buffer.len });
        return buffer[0..response.count];
    }
    pub fn controlState(self: *const Input, control: anytype) !ControlState {
        var state: ControlState = undefined;
        _ = try self.send(.{ .operation = .control_state, .control = controlId(control), .output = &state });
        return state;
    }
    pub fn heldControl(self: *const Input, control: anytype) !bool {
        return (try self.controlState(control)).held;
    }
    pub fn pressedControl(self: *const Input, control: anytype) !bool {
        return (try self.controlState(control)).pressed;
    }
    pub fn releasedControl(self: *const Input, control: anytype) !bool {
        return (try self.controlState(control)).released;
    }

    fn send(self: *const Input, request: protocol.Request) !protocol.Response {
        const backend = self.backend orelse return error.NoInputBackend;
        var response = protocol.Response{};
        try protocol.check(backend.request(backend.context, &request, &response));
        return response;
    }
    fn notify(self: *const Input, operation: protocol.Operation) void {
        if (self.backend == null) return;
        const buttons = types.Buttons{ .keys = self.keys_held, .mouse = self.buttons_held, .mouse_delta = self.mouse_delta, .wheel = self.wheel };
        if (self.send(.{ .operation = operation, .data = &buttons })) |_| {} else |err| {
            std.log.err("input {t} failed: {t}", .{ operation, err });
        }
    }

    /// Forget gameplay state when UI takes capture, without synthesizing release actions.
    pub fn cancel(self: *Input) void {
        self.* = .{ .mouse_position = self.mouse_position, .backend = self.backend, .viewport_points = self.viewport_points };
        self.notify(.cancel);
    }

    pub fn mouseHeld(self: *const Input, button: MouseButton) bool {
        return self.buttons_held.contains(button);
    }

    pub fn mousePressed(self: *const Input, button: MouseButton) bool {
        return self.buttons_pressed.contains(button);
    }

    pub fn mouseReleased(self: *const Input, button: MouseButton) bool {
        return self.buttons_released.contains(button);
    }

    /// Take in an event from the window.
    pub fn handle(self: *Input, event: sdl3.events.Event) !void {
        switch (event) {
            .key_down => |key| if (key.scancode) |code| if (index(code)) |at| {
                if (!key.repeat and !self.keys_held.isSet(at)) self.keys_pressed.set(at);
                self.keys_held.set(at);
            },
            .key_up => |key| if (key.scancode) |code| if (index(code)) |at| {
                if (self.keys_held.isSet(at)) self.keys_released.set(at);
                self.keys_held.unset(at);
            },
            .mouse_button_down => |down| if (mouseButton(down.button)) |which| {
                self.buttons_held.insert(which);
                self.buttons_pressed.insert(which);
            },
            .mouse_button_up => |up| if (mouseButton(up.button)) |which| {
                if (self.buttons_held.contains(which)) self.buttons_released.insert(which);
                self.buttons_held.remove(which);
            },
            .mouse_motion => |motion| {
                self.mouse_position = .{ motion.x, motion.y };
                self.mouse_delta[0] += motion.x_rel;
                self.mouse_delta[1] += motion.y_rel;
            },
            .mouse_wheel => |wheel| self.wheel += wheel.scroll_y,
            // Keys and buttons held while the window loses focus never come up in it.
            .window_focus_lost => self.releaseAll(),
            else => {},
        }
        if (self.backend != null) {
            const game_event = types.GameEvent{ .event = event, .buttons = .{ .keys = self.keys_held, .mouse = self.buttons_held, .mouse_delta = self.mouse_delta, .wheel = self.wheel }, .viewport_points = self.viewport_points };
            _ = try self.send(.{ .operation = .game_event, .data = &game_event });
        }
    }

    /// Forget this frame's presses, releases, movement and wheel: call once a frame, after the
    /// game has seen them.
    pub fn endFrame(self: *Input) void {
        self.keys_pressed = .initEmpty();
        self.keys_released = .initEmpty();
        self.buttons_pressed = .initEmpty();
        self.buttons_released = .initEmpty();
        self.mouse_delta = .{ 0, 0 };
        self.wheel = 0;
        self.notify(.end_frame);
    }

    /// Let go of every key and button, as if each came up.
    pub fn releaseAll(self: *Input) void {
        self.keys_released.setUnion(self.keys_held);
        self.keys_held = .initEmpty();
        self.buttons_released.setUnion(self.buttons_held);
        self.buttons_held = .initEmpty();
        self.notify(.release_all);
    }

    /// Withhold a UI-consumed event while cleaning up any gameplay hold it would release.
    /// Taking keyboard focus with a UI click cancels gameplay without synthetic edges.
    pub fn suppress(self: *Input, event: sdl3.events.Event) void {
        switch (event) {
            .key_down, .key_up => |key| if (key.scancode) |code| if (index(code)) |at| {
                self.keys_held.unset(at);
                self.keys_pressed.unset(at);
                self.keys_released.unset(at);
            },
            .mouse_button_down => self.cancel(),
            .mouse_button_up => |up| if (mouseButton(up.button)) |button| {
                self.buttons_held.remove(button);
                self.buttons_pressed.remove(button);
                self.buttons_released.remove(button);
            },
            .mouse_motion => self.mouse_delta = .{ 0, 0 },
            .mouse_wheel => self.wheel = 0,
            else => {},
        }
        if (self.backend != null) {
            const game_event = types.GameEvent{ .event = event, .buttons = .{ .keys = self.keys_held, .mouse = self.buttons_held, .mouse_delta = self.mouse_delta, .wheel = self.wheel }, .viewport_points = self.viewport_points };
            if (self.send(.{ .operation = .suppress_event, .data = &game_event })) |_| {} else |err| {
                std.log.err("cannot suppress input: {t}", .{err});
            }
        }
    }
};

pub fn MapView(comptime Mapping: type) type {
    return struct {
        input: *const Input,
        const Self = @This();
        fn id(control: Mapping.Control) types.ControlId {
            var result = controlId(control);
            result.type_marker = marker.of(Mapping);
            return result;
        }
        pub fn value(self: Self, control: Mapping.Control) !Value {
            var result: Value = undefined;
            _ = try self.input.send(.{ .operation = .control_value, .control = id(control), .output = &result });
            return result;
        }
        pub fn button(self: Self, control: Mapping.Control) !ControlState {
            const result = try self.value(control);
            return if (result == .button) result.button else error.WrongControlKind;
        }
        pub fn pressed(self: Self, control: Mapping.Control) !bool {
            return (try self.button(control)).pressed;
        }
        pub fn held(self: Self, control: Mapping.Control) !bool {
            return (try self.button(control)).held;
        }
        pub fn released(self: Self, control: Mapping.Control) !bool {
            return (try self.button(control)).released;
        }
        pub fn axis(self: Self, control: Mapping.Control) !f32 {
            const result = try self.value(control);
            return if (result == .axis) result.axis else error.WrongControlKind;
        }
        pub fn vector(self: Self, control: Mapping.Control) !@import("eggenvector").Vec2 {
            const result = try self.value(control);
            return if (result == .vector) .{ .x = result.vector[0], .y = result.vector[1] } else error.WrongControlKind;
        }
        /// Context activation is session state; it never rewrites developer project defaults.
        pub fn setEnabled(self: Self, enabled: bool) !void {
            _ = try self.input.send(.{ .operation = .map_enabled, .control = .{ .type_marker = marker.of(Mapping), .tag = 0 }, .count = @intFromBool(enabled) });
        }
        pub fn setPriority(self: Self, priority: i32) !void {
            _ = try self.input.send(.{ .operation = .map_priority, .control = .{ .type_marker = marker.of(Mapping), .tag = 0 }, .priority = priority });
        }
        pub fn rebind(self: Self, control: Mapping.Control, binding: Binding) !void {
            try self.setBindings(control, &.{binding});
        }
        pub fn setBindings(self: Self, control: Mapping.Control, bindings: []const Binding) !void {
            _ = try self.input.send(.{ .operation = .set_bindings, .control = id(control), .data = bindings.ptr, .count = bindings.len });
        }
        /// Replace a button trigger; editor project edits persist just like binding edits.
        pub fn setTrigger(self: Self, control: Mapping.Control, trigger: Trigger) !void {
            _ = try self.input.send(.{ .operation = .set_trigger, .control = id(control), .data = &trigger });
        }
        pub fn resetBindings(self: Self, control: Mapping.Control) !void {
            _ = try self.input.send(.{ .operation = .reset_bindings, .control = id(control) });
        }
        pub fn getBindings(self: Self, control: Mapping.Control, buffer: []Binding) ![]const Binding {
            const response = try self.input.send(.{ .operation = .get_bindings, .control = id(control), .output = buffer.ptr, .count = buffer.len });
            return buffer[0..response.count];
        }
    };
}

fn controlId(control: anytype) types.ControlId {
    const T = @TypeOf(control);
    comptime {
        if (@typeInfo(T) != .@"enum") @compileError("a control must be a value of your controls enum");
        if (@bitSizeOf(@typeInfo(T).@"enum".tag_type) > 64) @compileError("control enum tags must fit in 64 bits");
    }
    const Tag = @typeInfo(T).@"enum".tag_type;
    const tag: u64 = if (@typeInfo(Tag).int.signedness == .signed) @bitCast(@as(i64, @intFromEnum(control))) else @intCast(@intFromEnum(control));
    return .{ .type_marker = marker.of(T), .tag = tag };
}

fn index(key: Key) ?usize {
    const at: usize = @intCast(@intFromEnum(key));
    return if (at < key_count) at else null;
}

fn mouseButton(from: sdl3.mouse.Button) ?MouseButton {
    return switch (from) {
        .left => .left,
        .middle => .middle,
        .right => .right,
        .x1 => .x1,
        .x2 => .x2,
        _ => null,
    };
}

test "a key held for frames is pressed once, and an axis reads two keys" {
    var input = Input{};
    try input.handle(.{ .key_down = .{ .common = undefined, .id = null, .scancode = .w, .key = null, .mod = .{}, .raw = 0, .down = true, .repeat = false } });
    try std.testing.expect(input.pressed(.w) and input.held(.w));
    try std.testing.expectEqual(@as(f32, 1), input.axis(.s, .w));
    try std.testing.expectEqual([2]f32{ 0, 1 }, input.direction(.{}));
    input.endFrame();
    try std.testing.expect(!input.pressed(.w) and input.held(.w));
    input.releaseAll();
    try std.testing.expect(input.released(.w) and !input.held(.w));
    try std.testing.expectEqual(@as(f32, 0), input.axis(.s, .w));
    input.cancel();
    try std.testing.expect(!input.released(.w));
}

test "a swallowed release clears a gameplay hold without inventing an edge" {
    var input = Input{};
    const down = sdl3.events.Event{ .key_down = .{ .common = undefined, .id = null, .scancode = .w, .key = null, .mod = .{}, .raw = 0, .down = true, .repeat = false } };
    try input.handle(down);
    input.endFrame();
    var up = down.key_down;
    up.down = false;
    const event = sdl3.events.Event{ .key_up = up };
    input.suppress(event);
    try std.testing.expect(!input.held(.w) and !input.released(.w));
    try input.handle(event);
    try std.testing.expect(!input.released(.w));
}
