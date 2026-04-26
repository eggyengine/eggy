const std = @import("std");
pub const sdl = @import("sdl3");
const eggy = @import("eggy.zig");

pub const KeyboardInput = struct {
    /// Keys currently held down
    pressed: std.AutoHashMapUnmanaged(sdl.Scancode, void) = .{},
    /// Keys pressed this frame (not held last frame)
    just_pressed: std.AutoHashMapUnmanaged(sdl.Scancode, void) = .{},
    /// Keys released this frame
    just_released: std.AutoHashMapUnmanaged(sdl.Scancode, void) = .{},

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) KeyboardInput {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *KeyboardInput) void {
        self.pressed.deinit(self.allocator);
        self.just_pressed.deinit(self.allocator);
        self.just_released.deinit(self.allocator);
    }

    /// Call at the start of each frame to clear per-frame state
    pub fn clearFrameState(self: *KeyboardInput) void {
        self.just_pressed.clearRetainingCapacity();
        self.just_released.clearRetainingCapacity();
    }

    /// Process a key down event
    pub fn onKeyDown(self: *KeyboardInput, scancode: sdl.Scancode) void {
        // Only mark as just_pressed if it wasn't already held
        if (!self.pressed.contains(scancode)) {
            self.just_pressed.put(self.allocator, scancode, {}) catch {};
        }
        self.pressed.put(self.allocator, scancode, {}) catch {};
    }

    /// Process a key up event
    pub fn onKeyUp(self: *KeyboardInput, scancode: sdl.Scancode) void {
        _ = self.pressed.remove(scancode);
        self.just_released.put(self.allocator, scancode, {}) catch {};
    }

    /// Check if a key is currently pressed
    pub fn isPressed(self: *const KeyboardInput, scancode: sdl.Scancode) bool {
        return self.pressed.contains(scancode);
    }

    /// Check if a key was just pressed this frame
    pub fn isJustPressed(self: *const KeyboardInput, scancode: sdl.Scancode) bool {
        return self.just_pressed.contains(scancode);
    }

    /// Check if a key was just released this frame
    pub fn isJustReleased(self: *const KeyboardInput, scancode: sdl.Scancode) bool {
        return self.just_released.contains(scancode);
    }
};

pub const MouseButton = enum(u8) {
    left = 1,
    middle = 2,
    right = 3,
    x1 = 4,
    x2 = 5,
};

pub const MouseInput = struct {
    /// Current mouse position (window coordinates)
    x: f32 = 0,
    y: f32 = 0,

    /// Mouse movement delta this frame
    delta_x: f32 = 0,
    delta_y: f32 = 0,

    /// Scroll wheel delta this frame
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,

    pressed: std.AutoHashMapUnmanaged(MouseButton, void) = .{},
    just_pressed: std.AutoHashMapUnmanaged(MouseButton, void) = .{},
    just_released: std.AutoHashMapUnmanaged(MouseButton, void) = .{},

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MouseInput {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MouseInput) void {
        self.pressed.deinit(self.allocator);
        self.just_pressed.deinit(self.allocator);
        self.just_released.deinit(self.allocator);
    }

    /// Call at the start of each frame to clear per-frame state
    pub fn clearFrameState(self: *MouseInput) void {
        self.delta_x = 0;
        self.delta_y = 0;
        self.scroll_x = 0;
        self.scroll_y = 0;
        self.just_pressed.clearRetainingCapacity();
        self.just_released.clearRetainingCapacity();
    }

    /// Process mouse motion event
    pub fn onMotion(self: *MouseInput, new_x: f32, new_y: f32, dx: f32, dy: f32) void {
        self.x = new_x;
        self.y = new_y;
        self.delta_x += dx;
        self.delta_y += dy;
    }

    /// Process mouse button down event
    pub fn onButtonDown(self: *MouseInput, button: MouseButton) void {
        if (!self.pressed.contains(button)) {
            self.just_pressed.put(self.allocator, button, {}) catch {};
        }
        self.pressed.put(self.allocator, button, {}) catch {};
    }

    /// Process mouse button up event
    pub fn onButtonUp(self: *MouseInput, button: MouseButton) void {
        _ = self.pressed.remove(button);
        self.just_released.put(self.allocator, button, {}) catch {};
    }

    /// Process scroll event
    pub fn onScroll(self: *MouseInput, sx: f32, sy: f32) void {
        self.scroll_x += sx;
        self.scroll_y += sy;
    }

    /// Check if a button is currently pressed
    pub fn isPressed(self: *const MouseInput, button: MouseButton) bool {
        return self.pressed.contains(button);
    }

    /// Check if a button was just pressed this frame
    pub fn isJustPressed(self: *const MouseInput, button: MouseButton) bool {
        return self.just_pressed.contains(button);
    }

    /// Check if a button was just released this frame
    pub fn isJustReleased(self: *const MouseInput, button: MouseButton) bool {
        return self.just_released.contains(button);
    }

    /// Get mouse position as a vector
    pub fn position(self: *const MouseInput) eggy.math.Vector2(f32) {
        return .{ .x = self.x, .y = self.y };
    }

    /// Get mouse delta as a vector
    pub fn delta(self: *const MouseInput) eggy.math.Vector2(f32) {
        return .{ .x = self.delta_x, .y = self.delta_y };
    }
};

pub const GamepadButton = enum(u8) {
    invalid = 0,
    /// A (Xbox), Cross (PS)
    south = 1,
    /// B (Xbox), Circle (PS)
    east = 2,
    /// X (Xbox), Square (PS)
    west = 3,
    /// Y (Xbox), Triangle (PS)
    north = 4,
    back = 5,
    guide = 6,
    start = 7,
    left_stick = 8,
    right_stick = 9,
    left_shoulder = 10,
    right_shoulder = 11,
    dpad_up = 12,
    dpad_down = 13,
    dpad_left = 14,
    dpad_right = 15,
    misc1 = 16,
    right_paddle1 = 17,
    left_paddle1 = 18,
    right_paddle2 = 19,
    left_paddle2 = 20,
    touchpad = 21,
    misc2 = 22,
    misc3 = 23,
    misc4 = 24,
    misc5 = 25,
    misc6 = 26,
};

pub const GamepadAxis = enum(u8) {
    invalid = 0,
    left_x = 1,
    left_y = 2,
    right_x = 3,
    right_y = 4,
    left_trigger = 5,
    right_trigger = 6,
};

pub const GamepadState = struct {
    id: sdl.joystick.Id,

    pressed: std.AutoHashMapUnmanaged(GamepadButton, void) = .{},
    just_pressed: std.AutoHashMapUnmanaged(GamepadButton, void) = .{},
    just_released: std.AutoHashMapUnmanaged(GamepadButton, void) = .{},

    /// Axis values (-1.0 to 1.0 for sticks, 0.0 to 1.0 for triggers)
    axes: std.AutoHashMapUnmanaged(GamepadAxis, f32) = .{},

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: sdl.joystick.Id) GamepadState {
        return .{
            .allocator = allocator,
            .id = id,
        };
    }

    pub fn deinit(self: *GamepadState) void {
        self.pressed.deinit(self.allocator);
        self.just_pressed.deinit(self.allocator);
        self.just_released.deinit(self.allocator);
        self.axes.deinit(self.allocator);
    }

    pub fn clearFrameState(self: *GamepadState) void {
        self.just_pressed.clearRetainingCapacity();
        self.just_released.clearRetainingCapacity();
    }

    pub fn onButtonDown(self: *GamepadState, button: GamepadButton) void {
        if (!self.pressed.contains(button)) {
            self.just_pressed.put(self.allocator, button, {}) catch {};
        }
        self.pressed.put(self.allocator, button, {}) catch {};
    }

    pub fn onButtonUp(self: *GamepadState, button: GamepadButton) void {
        _ = self.pressed.remove(button);
        self.just_released.put(self.allocator, button, {}) catch {};
    }

    pub fn onAxisMotion(self: *GamepadState, axis: GamepadAxis, value: f32) void {
        self.axes.put(self.allocator, axis, value) catch {};
    }

    pub fn isPressed(self: *const GamepadState, button: GamepadButton) bool {
        return self.pressed.contains(button);
    }

    pub fn isJustPressed(self: *const GamepadState, button: GamepadButton) bool {
        return self.just_pressed.contains(button);
    }

    pub fn isJustReleased(self: *const GamepadState, button: GamepadButton) bool {
        return self.just_released.contains(button);
    }

    pub fn getAxis(self: *const GamepadState, axis: GamepadAxis) f32 {
        return self.axes.get(axis) orelse 0.0;
    }

    /// Get left stick as a vector
    pub fn leftStick(self: *const GamepadState) eggy.math.Vector2(f32) {
        return .{
            .x = self.getAxis(.left_x),
            .y = self.getAxis(.left_y),
        };
    }

    /// Get right stick as a vector
    pub fn rightStick(self: *const GamepadState) eggy.math.Vector2(f32) {
        return .{
            .x = self.getAxis(.right_x),
            .y = self.getAxis(.right_y),
        };
    }
};

/// Manages all connected gamepads
pub const GamepadInput = struct {
    gamepads: std.AutoHashMapUnmanaged(sdl.joystick.Id, GamepadState) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GamepadInput {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GamepadInput) void {
        var it = self.gamepads.valueIterator();
        while (it.next()) |state| {
            state.deinit();
        }
        self.gamepads.deinit(self.allocator);
    }

    /// Call at the start of each frame to clear per-frame state
    pub fn clearFrameState(self: *GamepadInput) void {
        var it = self.gamepads.valueIterator();
        while (it.next()) |state| {
            state.clearFrameState();
        }
    }

    /// Called when a gamepad is connected
    pub fn onConnected(self: *GamepadInput, id: sdl.joystick.Id) void {
        if (!self.gamepads.contains(id)) {
            self.gamepads.put(self.allocator, id, GamepadState.init(self.allocator, id)) catch {};
        }
    }

    /// Called when a gamepad is disconnected
    pub fn onDisconnected(self: *GamepadInput, id: sdl.joystick.Id) void {
        if (self.gamepads.getPtr(id)) |state| {
            state.deinit();
        }
        _ = self.gamepads.remove(id);
    }

    /// Get state for a specific gamepad
    pub fn getGamepad(self: *GamepadInput, id: sdl.joystick.Id) ?*GamepadState {
        return self.gamepads.getPtr(id);
    }

    /// Get state for the first connected gamepad (for single-player games)
    pub fn getFirstGamepad(self: *GamepadInput) ?*GamepadState {
        var it = self.gamepads.valueIterator();
        return it.next();
    }

    /// Check if any gamepad has a button pressed
    pub fn anyPressed(self: *GamepadInput, button: GamepadButton) bool {
        var it = self.gamepads.valueIterator();
        while (it.next()) |state| {
            if (state.isPressed(button)) return true;
        }
        return false;
    }

    /// Check if any gamepad just pressed a button
    pub fn anyJustPressed(self: *GamepadInput, button: GamepadButton) bool {
        var it = self.gamepads.valueIterator();
        while (it.next()) |state| {
            if (state.isJustPressed(button)) return true;
        }
        return false;
    }

    /// Get number of connected gamepads
    pub fn count(self: *const GamepadInput) usize {
        return self.gamepads.count();
    }
};

pub fn InputModule() type {
    return struct {
        pub const schedules = .{
            .init = &.{initInput},
            .pre_update = &.{clearInputState},
            .deinit = &.{deinitInput},
        };

        fn initInput(ctx: *eggy.Context) !void {
            try ctx.world.insertResource(KeyboardInput.init(ctx.allocator));
            try ctx.world.insertResource(MouseInput.init(ctx.allocator));
            try ctx.world.insertResource(GamepadInput.init(ctx.allocator));
        }

        fn clearInputState(ctx: *eggy.Context) void {
            if (ctx.world.getResource(KeyboardInput)) |kb| {
                kb.clearFrameState();
            }
            if (ctx.world.getResource(MouseInput)) |mouse| {
                mouse.clearFrameState();
            }
            if (ctx.world.getResource(GamepadInput)) |gamepad| {
                gamepad.clearFrameState();
            }
        }

        fn deinitInput(ctx: *eggy.Context) void {
            if (ctx.world.getResource(KeyboardInput)) |kb| {
                kb.deinit();
            }
            if (ctx.world.getResource(MouseInput)) |mouse| {
                mouse.deinit();
            }
            if (ctx.world.getResource(GamepadInput)) |gamepad| {
                gamepad.deinit();
            }
        }
    };
}
