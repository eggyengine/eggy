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
        inline for (comptime std.enums.values(sdl.gamepad.Button)) |button| snapshots.setButton(&state, button, device.getButton(button), false);
        inline for (comptime std.enums.values(sdl.gamepad.Axis)) |axis| snapshots.setAxis(&state, axis, device.getAxis(axis));
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
