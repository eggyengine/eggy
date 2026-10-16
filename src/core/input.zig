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

/// A key, by where it is on the keyboard.
pub const Key = sdl3.Scancode;

pub const MouseButton = enum { left, middle, right, x1, x2 };

const key_count = 512;
const KeySet = std.StaticBitSet(key_count);

pub const Input = struct {
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
    pub fn handle(self: *Input, event: sdl3.events.Event) void {
        switch (event) {
            .key_down => |key| if (key.scancode) |code| if (index(code)) |at| {
                if (!key.repeat and !self.keys_held.isSet(at)) self.keys_pressed.set(at);
                self.keys_held.set(at);
            },
            .key_up => |key| if (key.scancode) |code| if (index(code)) |at| {
                self.keys_held.unset(at);
                self.keys_released.set(at);
            },
            .mouse_button_down => |down| if (mouseButton(down.button)) |which| {
                self.buttons_held.insert(which);
                self.buttons_pressed.insert(which);
            },
            .mouse_button_up => |up| if (mouseButton(up.button)) |which| {
                self.buttons_held.remove(which);
                self.buttons_released.insert(which);
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
    }

    /// Let go of every key and button, as if each came up.
    pub fn releaseAll(self: *Input) void {
        self.keys_released.setUnion(self.keys_held);
        self.keys_held = .initEmpty();
        self.buttons_released.setUnion(self.buttons_held);
        self.buttons_held = .initEmpty();
    }
};

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
    input.handle(.{ .key_down = .{ .common = undefined, .id = null, .scancode = .w, .key = null, .mod = .{}, .raw = 0, .down = true, .repeat = false } });
    try std.testing.expect(input.pressed(.w) and input.held(.w));
    try std.testing.expectEqual(@as(f32, 1), input.axis(.s, .w));
    input.endFrame();
    try std.testing.expect(!input.pressed(.w) and input.held(.w));
    input.releaseAll();
    try std.testing.expect(input.released(.w) and !input.held(.w));
    try std.testing.expectEqual(@as(f32, 0), input.axis(.s, .w));
}
