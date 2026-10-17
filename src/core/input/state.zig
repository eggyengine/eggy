//! Host-owned device snapshots and typed control resolution.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const protocol = @import("bridge.zig");
const config = @import("bindings.zig");
const resolution = @import("resolution.zig");
const sdl = @import("vitellus_sdl3").sdl;
const ThreadId = if (builtin.single_threaded) u0 else std.Thread.Id;

pub const State = struct {
    gpa: std.mem.Allocator,
    thread: ThreadId,
    devices: std.AutoArrayHashMapUnmanaged(u32, Device) = .empty,
    contacts: std.ArrayList(Contact) = .empty,
    next_touch: u64 = 1,
    controls: std.AutoArrayHashMapUnmanaged(types.ControlId, Control) = .empty,
    owners: std.AutoHashMapUnmanaged(usize, Owner) = .empty,
    overrides: config.Overrides,
    persistence: ?config.Persistence = null,
    rumble: ?Rumble = null,
    buttons: types.Buttons = .{ .keys = .initEmpty(), .mouse = .initEmpty() },
    time_s: f64 = 0,
    revision: u64 = 0,
    configuration_revision: u64 = 0,

    pub const Rumble = struct { context: *anyopaque, run: *const fn (*anyopaque, u32, u16, u16, u32) anyerror!void };
    const Device = struct { raw: types.ControllerState, game: types.ControllerState };
    const Contact = struct { key: types.TouchKey, value: types.Touch };
    pub const Owner = struct { key: []u8, priority: i32, enabled: bool, consume: bool, defaults: types.MapDefaults };
    const Control = struct {
        map_id: usize,
        owner: []u8,
        name: []u8,
        key: []u8,
        defaults: []types.Binding,
        kind: types.Kind,
        trigger: types.Trigger,
        value: types.ControlState = .{},
        axis: f32 = 0,
        vector: [2]f32 = .{ 0, 0 },
        physical: bool = false,
        has_press: bool = false,
        started_s: f64 = 0,
        evaluated: u64 = 0,
        waiting_for_release: bool = false,
    };

    pub fn init(gpa: std.mem.Allocator) State {
        return .{ .gpa = gpa, .thread = if (builtin.single_threaded) 0 else std.Thread.getCurrentId(), .overrides = .init(gpa) };
    }
    pub fn deinit(self: *State) void {
        self.forgetControls();
        self.controls.deinit(self.gpa);
        self.owners.deinit(self.gpa);
        self.devices.deinit(self.gpa);
        self.contacts.deinit(self.gpa);
        self.overrides.deinit();
    }
    fn freeControl(self: *State, control: Control) void {
        self.gpa.free(control.owner);
        self.gpa.free(control.name);
        self.gpa.free(control.key);
        self.gpa.free(control.defaults);
        if (control.trigger == .chord) self.gpa.free(control.trigger.chord);
    }
    fn forgetControls(self: *State) void {
        for (self.controls.values()) |control| self.freeControl(control);
        self.controls.clearRetainingCapacity();
        var owners = self.owners.valueIterator();
        while (owners.next()) |owner| self.gpa.free(owner.key);
        self.owners.clearRetainingCapacity();
    }
    /// Device handles/overrides survive reload, compilation-local control markers do not.
    pub fn resetRun(self: *State) void {
        self.configuration_revision +%= 1;
        self.forgetControls();
        self.buttons = .{ .keys = .initEmpty(), .mouse = .initEmpty() };
        self.contacts.clearRetainingCapacity();
        self.time_s = 0;
        for (self.devices.values()) |*device| {
            device.game = device.raw;
            device.game.buttons_pressed = .initEmpty();
            device.game.buttons_released = .initEmpty();
        }
    }
    pub fn readOverrides(self: *State, source: [:0]const u8) !void {
        self.installOverrides(try self.prepareOverrides(source));
    }
    pub fn prepareOverrides(self: *State, source: [:0]const u8) !config.Overrides {
        var replacement = config.Overrides.init(self.gpa);
        errdefer replacement.deinit();
        try replacement.read(source);
        try resolution.validate(self.controls.values(), &replacement, null);
        return replacement;
    }
    /// Commit an already validated, owned configuration without allocating after a file write.
    pub fn installOverrides(self: *State, replacement: config.Overrides) void {
        self.overrides.deinit();
        self.overrides = replacement;
        var owners = self.owners.valueIterator();
        while (owners.next()) |owner| {
            const defaults = self.overrides.maps.get(owner.key) orelse owner.defaults;
            owner.priority = defaults.priority;
            owner.enabled = defaults.enabled;
        }
        self.configuration_revision +%= 1;
        self.resetEvaluation();
    }
    /// Input trigger timing uses counted unscaled gameplay seconds, not time dilation.
    pub fn advance(self: *State, delta_s: f32) !void {
        if (!std.math.isFinite(delta_s) or delta_s < 0) return error.InvalidDuration;
        self.time_s += delta_s;
        self.recompute(true);
    }
    fn resetEvaluation(self: *State) void {
        for (self.controls.values()) |*control| {
            control.value = .{};
            control.physical = false;
            control.has_press = false;
            control.waiting_for_release = false;
        }
        self.recompute(false);
    }
    pub fn interface(self: *State) protocol.Bridge {
        return .{ .context = self, .request = request };
    }
    fn request(raw: *anyopaque, input: *const protocol.Request, response: *protocol.Response) callconv(.c) protocol.Status {
        const self: *State = @ptrCast(@alignCast(raw));
        if (!builtin.single_threaded and self.thread != std.Thread.getCurrentId()) return .wrong_thread;
        self.dispatch(input.*, response) catch |err| return switch (err) {
            error.ControllerDisconnected => .no_device,
            error.UnknownControl => .unknown_control,
            error.BufferTooSmall => .buffer_too_small,
            error.InvalidBinding => .invalid_binding,
            error.TransientControllerBinding => .transient_device,
            error.DuplicateControls => .duplicate_controls,
            error.WrongControlKind => .wrong_kind,
            error.InvalidTrigger => .invalid_trigger,
            error.OutOfMemory => .out_of_memory,
            error.UnsupportedDeviceFeature => .unsupported,
            error.SdlError => {
                std.log.err("SDL input request failed: {s}", .{sdl.errors.get() orelse ""});
                return .sdl_failed;
            },
            else => {
                std.log.err("input {t} failed: {t}", .{ input.operation, err });
                return .io_failed;
            },
        };
        return .ok;
    }
    fn data(comptime T: type, request_data: ?*const anyopaque) *const T {
        return @ptrCast(@alignCast(request_data.?));
    }
    fn output(comptime T: type, request_output: ?*anyopaque) *T {
        return @ptrCast(@alignCast(request_output.?));
    }

    fn dispatch(self: *State, input: protocol.Request, response: *protocol.Response) !void {
        switch (input.operation) {
            .controller_count => response.count = self.devices.count(),
            .controllers => {
                response.count = self.devices.count();
                if (input.count < response.count) return error.BufferTooSmall;
                if (response.count != 0) {
                    const ids: [*]types.Controller = @ptrCast(@alignCast(input.output.?));
                    for (self.devices.keys(), 0..) |id, i| ids[i] = @enumFromInt(id);
                }
            },
            .controller_state => output(types.ControllerState, input.output).* = (self.devices.get(input.device) orelse return error.ControllerDisconnected).game,
            .rumble => {
                const device = self.devices.get(input.device) orelse return error.ControllerDisconnected;
                const backend = self.rumble orelse return error.UnsupportedDeviceFeature;
                if (!device.raw.rumble_supported) return error.UnsupportedDeviceFeature;
                try backend.run(backend.context, input.device, input.low, input.high, input.duration_ms);
            },
            .touch_count => response.count = self.contacts.items.len,
            .touches => {
                response.count = self.contacts.items.len;
                if (input.count < response.count) return error.BufferTooSmall;
                if (response.count != 0) {
                    const touches: [*]types.Touch = @ptrCast(@alignCast(input.output.?));
                    for (self.contacts.items, 0..) |contact, i| touches[i] = contact.value;
                }
            },
            .register_controls => try self.register(data(types.Registration, input.data).*),
            .set_bindings => {
                const control = self.controls.getPtr(input.control) orelse return error.UnknownControl;
                const mappings: []const types.Binding = if (input.count == 0) &.{} else @as([*]const types.Binding, @ptrCast(@alignCast(input.data.?)))[0..input.count];
                try self.setMappings(input.control, mappings, self.overrides.getTrigger(control.key));
            },
            .set_trigger => {
                const control = self.controls.get(input.control) orelse return error.UnknownControl;
                try self.setMappings(input.control, self.overrides.get(control.key) orelse control.defaults, data(types.Trigger, input.data).*);
            },
            .reset_bindings => {
                const control = self.controls.getPtr(input.control) orelse return error.UnknownControl;
                try resolution.validate(self.controls.values(), &self.overrides, .{ .key = control.key, .bindings = control.defaults, .trigger = control.trigger });
                try self.overrides.remove(control.owner, control.name, self.persistence);
                self.configuration_revision +%= 1;
                self.resetEvaluation();
            },
            .get_bindings => {
                const control = self.controls.get(input.control) orelse return error.UnknownControl;
                const mappings = self.overrides.get(control.key) orelse control.defaults;
                response.count = mappings.len;
                if (input.count < mappings.len) return error.BufferTooSmall;
                if (mappings.len != 0) {
                    const buffer: [*]types.Binding = @ptrCast(@alignCast(input.output.?));
                    @memcpy(buffer[0..mappings.len], mappings);
                }
            },
            .control_state => {
                const control = self.controls.get(input.control) orelse return error.UnknownControl;
                if (control.kind != .button) return error.WrongControlKind;
                output(types.ControlState, input.output).* = control.value;
            },
            .control_value => {
                const control = self.controls.get(input.control) orelse return error.UnknownControl;
                output(types.Value, input.output).* = switch (control.kind) {
                    .button => .{ .button = control.value },
                    .axis => .{ .axis = control.axis },
                    .vector => .{ .vector = control.vector },
                };
            },
            .map_enabled, .map_priority => {
                const owner = self.owners.getPtr(input.control.type_marker) orelse return error.UnknownControl;
                if (input.operation == .map_enabled) owner.enabled = input.count != 0 else owner.priority = input.priority;
                self.resetEvaluation();
            },
            .game_event => {
                const value = data(types.GameEvent, input.data);
                self.buttons = value.buttons;
                try self.gameEvent(value.event, value.viewport_points);
                self.recompute(value.event != .key_down or !value.event.key_down.repeat);
            },
            .suppress_event => {
                const value = data(types.GameEvent, input.data);
                self.buttons = value.buttons;
                self.suppress(value.event);
                self.recompute(false);
                for (self.controls.values()) |*control| if (!control.value.held) {
                    control.value.pressed = false;
                    control.value.released = false;
                };
            },
            .buttons_changed => {
                self.buttons = data(types.Buttons, input.data).*;
                self.recompute(true);
            },
            .end_frame => {
                self.buttons = data(types.Buttons, input.data).*;
                self.endFrame();
                self.recompute(false);
            },
            .cancel, .release_all => {
                self.buttons = data(types.Buttons, input.data).*;
                for (self.devices.values()) |*device| {
                    const released = device.game.buttons;
                    device.game = .{ .rumble_supported = device.raw.rumble_supported };
                    if (input.operation == .release_all) device.game.buttons_released = released;
                }
                for (self.contacts.items) |*contact| contact.value.phase = .cancelled;
                self.recompute(input.operation == .release_all);
                if (input.operation == .cancel) {
                    for (self.controls.values()) |*control| control.value = .{};
                }
            },
        }
    }

    fn register(self: *State, registration: types.Registration) !void {
        if (self.owners.contains(registration.type_marker)) return error.DuplicateControls;
        var owners = self.owners.valueIterator();
        while (owners.next()) |owner| if (std.mem.eql(u8, owner.key, registration.owner)) return error.DuplicateControls;
        const prepared = try self.gpa.alloc(Control, registration.controls.len);
        defer self.gpa.free(prepared);
        var count: usize = 0;
        errdefer for (prepared[0..count]) |control| self.freeControl(control);
        for (registration.controls, 0..) |definition, i| {
            for (registration.controls[0..i]) |previous| if (previous.tag == definition.tag) return error.DuplicateControls;
            try config.validate(definition.bindings, false);
            prepared[i] = try self.prepareControl(registration.type_marker, registration.owner, definition);
            count += 1;
        }
        try resolution.validate(prepared, &self.overrides, null);
        const owner = try self.gpa.dupe(u8, registration.owner);
        errdefer self.gpa.free(owner);
        try self.controls.ensureUnusedCapacity(self.gpa, prepared.len);
        try self.owners.ensureUnusedCapacity(self.gpa, 1);
        for (prepared, registration.controls) |control, definition| {
            self.controls.putAssumeCapacity(.{ .type_marker = registration.type_marker, .tag = definition.tag }, control);
        }
        const defaults = types.MapDefaults{ .priority = registration.priority, .enabled = registration.enabled };
        const active = self.overrides.maps.get(owner) orelse defaults;
        self.owners.putAssumeCapacity(registration.type_marker, .{ .key = owner, .priority = active.priority, .enabled = active.enabled, .consume = registration.consume, .defaults = defaults });
        self.configuration_revision +%= 1;
        self.resetEvaluation();
    }
    fn prepareControl(self: *State, map_id: usize, owner: []const u8, definition: types.ControlDefinition) !Control {
        const owner_copy = try self.gpa.dupe(u8, owner);
        errdefer self.gpa.free(owner_copy);
        const name = try self.gpa.dupe(u8, definition.name);
        errdefer self.gpa.free(name);
        const key = try config.stableKey(self.gpa, owner, definition.name);
        errdefer self.gpa.free(key);
        const trigger = if (definition.trigger == .chord) types.Trigger{ .chord = try self.gpa.dupe(u8, definition.trigger.chord) } else definition.trigger;
        errdefer if (trigger == .chord) self.gpa.free(trigger.chord);
        return .{ .map_id = map_id, .owner = owner_copy, .name = name, .key = key, .kind = definition.kind, .trigger = trigger, .defaults = try self.gpa.dupe(types.Binding, definition.bindings) };
    }
    fn recompute(self: *State, edges: bool) void {
        resolution.update(self, edges);
    }
    /// Validate and save the whole edit before changing the active resolver.
    pub fn setMappings(self: *State, id: types.ControlId, mappings: []const types.Binding, trigger: ?types.Trigger) !void {
        const control = self.controls.get(id) orelse return error.UnknownControl;
        try config.validate(mappings, self.persistence != null);
        try resolution.validate(self.controls.values(), &self.overrides, .{ .key = control.key, .bindings = mappings, .trigger = trigger orelse control.trigger });
        try self.overrides.set(control.owner, control.name, mappings, trigger, self.persistence);
        self.configuration_revision +%= 1;
        self.resetEvaluation();
    }
    pub fn resetMappings(self: *State, id: types.ControlId) !void {
        var response = protocol.Response{};
        try self.dispatch(.{ .operation = .reset_bindings, .control = id }, &response);
    }
    /// Edit project defaults, not a gameplay context's temporary activation/priority.
    pub fn setMapDefaults(self: *State, map_id: usize, value: ?types.MapDefaults) !void {
        const owner = self.owners.getPtr(map_id) orelse return error.UnknownControl;
        try self.overrides.setMap(owner.key, value, self.persistence);
        const active = value orelse owner.defaults;
        owner.priority = active.priority;
        owner.enabled = active.enabled;
        self.configuration_revision +%= 1;
        self.resetEvaluation();
    }
    pub fn addController(self: *State, id: u32, raw: types.ControllerState) !void {
        try self.devices.put(self.gpa, id, .{ .raw = raw, .game = raw });
        self.recompute(false);
    }
    pub fn removeController(self: *State, id: u32) void {
        _ = self.devices.orderedRemove(id);
        self.recompute(true);
    }
    /// Physical state is tracked while editing; only routed gameplay events create edges.
    pub fn rawEvent(self: *State, event: sdl.events.Event) void {
        switch (event) {
            .gamepad_button_down, .gamepad_button_up => |button| if (self.devices.getPtr(button.id.value)) |device| setButton(&device.raw, button.button, button.down, false),
            .gamepad_axis_motion => |axis| if (self.devices.getPtr(axis.id.value)) |device| setAxis(&device.raw, axis.axis, axis.value),
            else => {},
        }
    }
    fn gameEvent(self: *State, event: sdl.events.Event, viewport: [2]f32) !void {
        switch (event) {
            .gamepad_button_down, .gamepad_button_up => |button| if (self.devices.getPtr(button.id.value)) |device| setButton(&device.game, button.button, button.down, true),
            .gamepad_axis_motion => |axis| if (self.devices.getPtr(axis.id.value)) |device| setAxis(&device.game, axis.axis, axis.value),
            .finger_down, .finger_motion, .finger_up, .finger_canceled => |finger| try self.touch(event, finger, viewport),
            else => {},
        }
    }
    fn suppress(self: *State, event: sdl.events.Event) void {
        switch (event) {
            .gamepad_button_down, .gamepad_button_up => |button| if (self.devices.getPtr(button.id.value)) |device| {
                const mapped = buttonFromSdl(button.button);
                device.game.buttons.remove(mapped);
                device.game.buttons_pressed.remove(mapped);
                device.game.buttons_released.remove(mapped);
            },
            .gamepad_axis_motion => |axis| if (self.devices.getPtr(axis.id.value)) |device| setAxis(&device.game, axis.axis, 0),
            .finger_down, .finger_motion, .finger_up, .finger_canceled => |finger| {
                if (self.contactIndex(touchKey(finger))) |index| self.contacts.items[index].value.phase = .cancelled;
            },
            else => {},
        }
    }
    fn touch(self: *State, event: sdl.events.Event, finger: sdl.events.TouchFinger, viewport: [2]f32) !void {
        const key = touchKey(finger);
        const position = [2]f32{ finger.x * viewport[0], finger.y * viewport[1] };
        if (event == .finger_down and self.contactIndex(key) == null) {
            try self.contacts.append(self.gpa, .{ .key = key, .value = .{ .id = self.next_touch, .position_points = position, .pressure = finger.pressure } });
            self.next_touch +%= 1;
            return;
        }
        const index = self.contactIndex(key) orelse return;
        const value = &self.contacts.items[index].value;
        value.delta_points[0] += finger.dx * viewport[0];
        value.delta_points[1] += finger.dy * viewport[1];
        value.position_points = position;
        value.pressure = finger.pressure;
        value.phase = switch (event) {
            .finger_up => .ended,
            .finger_canceled => .cancelled,
            .finger_down => .began,
            else => if (value.phase == .began) .began else .moved,
        };
    }
    fn contactIndex(self: *const State, key: types.TouchKey) ?usize {
        for (self.contacts.items, 0..) |contact, i| if (std.meta.eql(contact.key, key)) return i;
        return null;
    }
    fn endFrame(self: *State) void {
        for (self.devices.values()) |*device| {
            device.game.buttons_pressed = .initEmpty();
            device.game.buttons_released = .initEmpty();
        }
        for (self.controls.values()) |*control| {
            control.value.pressed = false;
            control.value.released = false;
        }
        var i: usize = 0;
        while (i < self.contacts.items.len) {
            const value = &self.contacts.items[i].value;
            if (value.phase == .ended or value.phase == .cancelled) {
                _ = self.contacts.orderedRemove(i);
            } else {
                value.phase = .stationary;
                value.delta_points = .{ 0, 0 };
                i += 1;
            }
        }
    }
};

pub fn buttonFromSdl(button: sdl.gamepad.Button) types.ControllerButton {
    return switch (button) {
        .dpad_up => .up,
        .dpad_down => .down,
        .dpad_left => .left,
        .dpad_right => .right,
        inline else => |tag| @field(types.ControllerButton, @tagName(tag)),
    };
}
pub fn setButton(state: *types.ControllerState, button: sdl.gamepad.Button, down: bool, edges: bool) void {
    const mapped = buttonFromSdl(button);
    const held = state.buttons.contains(mapped);
    if (down) state.buttons.insert(mapped) else state.buttons.remove(mapped);
    if (edges and down and !held) state.buttons_pressed.insert(mapped);
    if (edges and !down and held) state.buttons_released.insert(mapped);
}
pub fn setAxis(state: *types.ControllerState, axis: sdl.gamepad.Axis, raw: i16) void {
    const value = @as(f32, @floatFromInt(raw)) / (if (raw < 0) @as(f32, 32768) else 32767);
    switch (axis) {
        .left_x => state.left_stick[0] = value,
        .left_y => state.left_stick[1] = value,
        .right_x => state.right_stick[0] = value,
        .right_y => state.right_stick[1] = value,
        .left_trigger => state.triggers[0] = @max(0, value),
        .right_trigger => state.triggers[1] = @max(0, value),
    }
}
pub fn touchKey(finger: sdl.events.TouchFinger) types.TouchKey {
    return .{ .device = @bitCast(finger.id.value), .finger = @bitCast(finger.finger_id.value) };
}
