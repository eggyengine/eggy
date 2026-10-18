//! SDL gamepad ownership for the executable; game libraries use State's C bridge.
const std = @import("std");
const sdl = @import("vitellus_sdl3").sdl;
const snapshots = @import("state.zig");
pub const State = snapshots.State;
/// SDL button translation; see `state.buttonFromSdl` for its host-only contract and example.
pub const buttonFromSdl = snapshots.buttonFromSdl;
const types = @import("types.zig");

pub const Backend = struct {
    gpa: std.mem.Allocator,
    state: State,
    devices: std.AutoArrayHashMapUnmanaged(u32, sdl.gamepad.Gamepad) = .empty,

    /// Allocate a stable owner before publishing its interface to movable App/plugin values.
    /// Host-only: SDL gamepad support must already be initialized on this thread.
    /// Opens connected gamepads; allocation/SDL failures clean up partial ownership.
    /// The returned pointer owns device handles and must be destroyed with `deinit`.
    ///
    /// ```zig
    /// // Host after initializing SDL gamepad support:
    /// const backend = try Backend.init(gpa);
    /// defer backend.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator) !*Backend {
        const self = try gpa.create(Backend);
        self.* = .{ .gpa = gpa, .state = .init(gpa) };
        errdefer self.deinit();
        self.state.rumble = .{ .context = self, .run = rumble };
        const devices = try sdl.gamepad.getGamepads();
        defer sdl.free(devices);
        for (devices) |device| try self.open(device.value);
        return self;
    }

    /// Host-only: close all gamepads, free resolver state and destroy the allocated backend.
    /// Call on its owning thread before SDL shutdown; all published bridges become invalid.
    ///
    /// ```zig
    /// const backend = try Backend.init(gpa);
    /// defer backend.deinit();
    /// ```
    pub fn deinit(self: *Backend) void {
        for (self.devices.values()) |device| device.deinit();
        self.devices.deinit(self.gpa);
        self.state.deinit();
        self.gpa.destroy(self);
    }

    fn read(device: sdl.gamepad.Gamepad) !types.ControllerState {
        var state = types.ControllerState{ .rumble_supported = (try device.getProperties()).rumble orelse false };
        inline for (std.meta.fields(sdl.gamepad.Button)) |field| {
            snapshots.setButton(&state, @field(sdl.gamepad.Button, field.name), device.getButton(@field(sdl.gamepad.Button, field.name)), false);
        }
        inline for (std.meta.fields(sdl.gamepad.Axis)) |field| {
            snapshots.setAxis(&state, @field(sdl.gamepad.Axis, field.name), device.getAxis(@field(sdl.gamepad.Axis, field.name)));
        }
        return state;
    }
    fn open(self: *Backend, id: u32) !void {
        if (self.devices.contains(id)) return;
        const device = try sdl.gamepad.Gamepad.init(.{ .value = id });
        errdefer device.deinit();
        const state = try read(device);
        try self.devices.ensureUnusedCapacity(self.gpa, 1);
        try self.state.addController(id, state);
        self.devices.putAssumeCapacity(id, device);
    }

    /// Connection and raw-state events are processed even when gameplay input is gated.
    /// Host-only: feed SDL events on the initialization thread, separately from gameplay's
    /// `Input.handle`. Hotplug may allocate/open handles and return SDL or allocation errors.
    ///
    /// ```zig
    /// // Host polling SDL, regardless of play/capture state:
    /// while (sdl.events.poll()) |event| try backend.event(event);
    /// ```
    pub fn event(self: *Backend, value: sdl.events.Event) !void {
        switch (value) {
            .gamepad_added => |device| try self.open(device.id.value),
            .gamepad_removed => |device| {
                if (self.devices.fetchOrderedRemove(device.id.value)) |removed| removed.value.deinit();
                self.state.removeController(device.id.value);
            },
            .gamepad_remapped => |device| if (self.devices.get(device.id.value)) |opened| {
                if (opened.connected()) try self.state.addController(device.id.value, try read(opened));
            },
            else => self.state.rawEvent(value),
        }
    }
    fn rumble(raw: *anyopaque, id: u32, low: u16, high: u16, duration_ms: u32) !void {
        const self: *Backend = @ptrCast(@alignCast(raw));
        const device = self.devices.get(id) orelse return error.ControllerDisconnected;
        if (!device.connected()) return error.ControllerDisconnected;
        try device.rumble(low, high, duration_ms);
    }
};

test "SDL virtual gamepads hotplug, normalize state, route edges and receive rumble" {
    const Input = @import("input.zig").Input;
    const Virtual = struct {
        low: u16 = 0,
        high: u16 = 0,
        fn rumble(raw: ?*anyopaque, low: u16, high: u16) callconv(.c) bool {
            const context: *@This() = @ptrCast(@alignCast(raw.?));
            context.* = .{ .low = low, .high = high };
            return true;
        }
    };
    try sdl.init(.{ .gamepad = true });
    defer sdl.quit(.{ .gamepad = true });
    const backend = try Backend.init(std.testing.allocator);
    defer backend.deinit();
    var virtual = Virtual{};
    var description = (sdl.joystick.VirtualJoystickDescription(Virtual){
        .joystick_type = .gamepad,
        .num_axes = 6,
        .num_buttons = 1,
        .buttons = .{ .south = true },
        .axes = .{ .left_x = true, .left_y = true, .left_trigger = true },
        .name = "Eggy test gamepad",
        .user_data = &virtual,
    }).toSdl();
    description.Rumble = Virtual.rumble;
    const id = sdl.joystick.Id{ .value = sdl.c.SDL_AttachVirtualJoystick(&description) };
    if (id.value == 0) return error.SdlError;
    var attached = true;
    defer if (attached) id.deinitVirtual() catch @panic("cannot detach test gamepad");
    const joystick = try sdl.joystick.Joystick.init(id);
    defer joystick.deinit();
    var input = Input{ .backend = backend.state.interface() };
    while (sdl.events.poll()) |event| try backend.event(event);
    const controller: types.Controller = @enumFromInt(id.value);
    try std.testing.expect((try input.controllerState(controller)).rumble_supported);
    try joystick.setVirtualButton(0, true);
    try joystick.setVirtualAxis(0, -32768);
    try joystick.setVirtualAxis(1, 32767);
    sdl.joystick.update();
    while (sdl.events.poll()) |event| {
        try backend.event(event);
        try input.handle(event);
    }
    const state = try input.controllerState(controller);
    try std.testing.expect(state.buttons.contains(.south));
    try std.testing.expect(state.buttons_pressed.contains(.south));
    try std.testing.expectEqual([2]f32{ -1, 1 }, state.left_stick);
    try input.rumble(controller, 0.5, 1, 0.1);
    try std.testing.expectEqual(@as(u16, 32768), virtual.low);
    try std.testing.expectEqual(@as(u16, 65535), virtual.high);
    input.endFrame();
    try std.testing.expect((try input.controllerState(controller)).buttons_pressed.count() == 0);
    try id.deinitVirtual();
    attached = false;
    while (sdl.events.poll()) |event| try backend.event(event);
    try std.testing.expectError(error.ControllerDisconnected, input.controllerState(controller));
}
