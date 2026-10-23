//! Map priority, modifiers, and timed/chord trigger evaluation.
const std = @import("std");
const t = @import("types.zig");
const modifiers = @import("mapping.zig");
const config = @import("bindings.zig");
const sdl = @import("vitellus_sdl3").sdl;

pub const Change = struct { key: []const u8, bindings: []const t.Binding, trigger: t.Trigger };
/// Host-only: borrow effective bindings, preferring a matching proposed edit, then saved
/// overrides, then `control.defaults`. `control` supplies key/defaults; result lifetime is
/// whichever source won, so do not retain it across source mutation/deinitialization.
///
/// ```zig
/// // Host with a resolver control value and owned overrides:
/// const bindings = mappings(control, &overrides, null);
/// ```
pub fn mappings(control: anytype, overrides: *const config.Overrides, change: ?Change) []const t.Binding {
    if (change) |value| if (std.mem.eql(u8, value.key, control.key)) return value.bindings;
    return overrides.get(control.key) orelse control.defaults;
}
/// Host-only: choose a proposed trigger, saved override or `control.trigger`, in that order.
/// The returned value is copied, but a chord name borrows the selected source's storage.
///
/// ```zig
/// const rule = trigger(control, &overrides, null); // Host resolver control and overrides.
/// ```
pub fn trigger(control: anytype, overrides: *const config.Overrides, change: ?Change) t.Trigger {
    if (change) |value| if (std.mem.eql(u8, value.key, control.key)) return value.trigger;
    return overrides.getTrigger(control.key) orelse control.trigger;
}
/// Host-only: validate effective value kinds and same-owner button chord graphs, optionally
/// previewing one edit without installing it. Controls supply key/defaults/kind/trigger/
/// owner/name fields. Reports `WrongControlKind` or `InvalidTrigger`; does not allocate or
/// validate physical binding payloads (use `bindings.validate` for those).
///
/// ```zig
/// // Host validating registered controls against a candidate configuration:
/// try validate(state.controls.values(), &replacement, null);
/// ```
pub fn validate(controls: anytype, overrides: *const config.Overrides, change: ?Change) !void {
    for (controls) |control| {
        for (mappings(control, overrides, change)) |binding| if (modifiers.kind(binding) != control.kind) return error.WrongControlKind;
        try modifiers.validateTrigger(control.kind, trigger(control, overrides, change));
    }
    for (controls, 0..) |_, start| {
        var cursor = start;
        var depth: usize = 0;
        while (trigger(controls[cursor], overrides, change) == .chord) {
            if (depth >= controls.len) return error.InvalidTrigger;
            const name = trigger(controls[cursor], overrides, change).chord;
            cursor = for (controls, 0..) |candidate, i| {
                if (std.mem.eql(u8, candidate.owner, controls[cursor].owner) and std.mem.eql(u8, candidate.name, name)) break i;
            } else return error.InvalidTrigger;
            if (controls[cursor].kind != .button) return error.InvalidTrigger;
            depth += 1;
        }
    }
}

const Source = union(enum) { key: t.Key, mouse: t.MouseButton, button: struct { device: u32, button: t.ControllerButton }, axis: struct { device: u32, axis: sdl.gamepad.Axis }, motion, wheel };
fn used(binding: t.Binding, source: Source) bool {
    return switch (source) {
        .key => |key| modifiers.usesKey(binding, key),
        .mouse => |button| binding == .mouse and binding.mouse == button,
        .button => |value| modifiers.usesButton(binding, value.device, value.button),
        .axis => |value| modifiers.usesAxis(binding, value.device, value.axis),
        .motion => binding == .mouse_delta,
        .wheel => binding == .mouse_wheel,
    };
}
fn blocked(state: anytype, map_id: usize, source: Source) bool {
    const own = state.owners.get(map_id).?;
    if (!own.enabled) return true;
    for (state.controls.values()) |control| {
        if (control.map_id == map_id) continue;
        const other = state.owners.get(control.map_id).?;
        if (!other.enabled or !other.consume or other.priority <= own.priority) continue;
        for (mappings(control, &state.overrides, null)) |binding| if (used(binding, source)) return true;
    }
    return false;
}
fn keyHeld(state: anytype, map_id: usize, key: t.Key) bool {
    return !blocked(state, map_id, .{ .key = key }) and state.buttons.keys.isSet(@backingInt(key));
}
fn axisValue(device: t.ControllerState, axis: sdl.gamepad.Axis) f32 {
    return switch (axis) {
        .left_x => device.left_stick[0],
        .left_y => device.left_stick[1],
        .right_x => device.right_stick[0],
        .right_y => device.right_stick[1],
        .left_trigger => device.triggers[0],
        .right_trigger => device.triggers[1],
    };
}
fn axisRead(state: anytype, map_id: usize, device_id: u32, axis: sdl.gamepad.Axis) f32 {
    if (blocked(state, map_id, .{ .axis = .{ .device = device_id, .axis = axis } })) return 0;
    return axisValue(state.devices.get(device_id).?.game, axis);
}
fn deviceMatches(selector: ?t.Controller, device_id: u32) bool {
    return selector == null or @backingInt(selector.?) == device_id;
}

fn rawValue(state: anytype, index: usize) t.Value {
    const control = state.controls.values()[index];
    if (!state.owners.get(control.map_id).?.enabled) return switch (control.kind) {
        .button => .{ .button = .{} },
        .axis => .{ .axis = 0 },
        .vector => .{ .vector = .{ 0, 0 } },
    };
    var held = false;
    var scalar: f32 = 0;
    var vector: [2]f32 = .{ 0, 0 };
    for (mappings(control, &state.overrides, null)) |binding| {
        var one: f32 = 0;
        var pair: [2]f32 = .{ 0, 0 };
        switch (binding) {
            .key => |key| held = held or keyHeld(state, control.map_id, key),
            .mouse => |button| held = held or (!blocked(state, control.map_id, .{ .mouse = button }) and state.buttons.mouse.contains(button)),
            .controller => |mapping| for (state.devices.keys(), state.devices.values()) |id, device| {
                if (deviceMatches(mapping.device, id) and !blocked(state, control.map_id, .{ .button = .{ .device = id, .button = mapping.button } })) held = held or device.game.buttons.contains(mapping.button);
            },
            .key_axis => |axis| one = (@as(f32, @floatFromInt(@intFromBool(keyHeld(state, control.map_id, axis.positive)))) - @as(f32, @floatFromInt(@intFromBool(keyHeld(state, control.map_id, axis.negative))))) * axis.scale,
            .keys_2d => |keys| {
                pair = .{
                    @as(f32, @floatFromInt(@intFromBool(keyHeld(state, control.map_id, keys.keys.right)))) - @as(f32, @floatFromInt(@intFromBool(keyHeld(state, control.map_id, keys.keys.left)))),
                    @as(f32, @floatFromInt(@intFromBool(keyHeld(state, control.map_id, keys.keys.down)))) - @as(f32, @floatFromInt(@intFromBool(keyHeld(state, control.map_id, keys.keys.up)))),
                };
                const length = @sqrt(pair[0] * pair[0] + pair[1] * pair[1]);
                if (keys.normalize and length > 1) for (&pair) |*value| {
                    value.* /= length;
                };
                pair[0] *= keys.scale[0];
                pair[1] *= keys.scale[1];
            },
            .controller_axis => |axis| for (state.devices.keys()) |id| {
                if (!deviceMatches(axis.device, id)) continue;
                const candidate = modifiers.deadZone(axisRead(state, control.map_id, id, axis.axis), axis.dead_zone) * axis.scale;
                if (@abs(candidate) > @abs(one)) one = candidate;
            },
            .controller_stick => |stick| for (state.devices.keys()) |id| {
                if (!deviceMatches(stick.device, id)) continue;
                var candidate = modifiers.stick(.{
                    axisRead(state, control.map_id, id, if (stick.stick == .left) .left_x else .right_x),
                    axisRead(state, control.map_id, id, if (stick.stick == .left) .left_y else .right_y),
                }, stick.dead_zone);
                candidate[0] *= stick.scale[0];
                candidate[1] *= stick.scale[1];
                if (lengthSquared(candidate) > lengthSquared(pair)) pair = candidate;
            },
            .mouse_delta => |delta| if (!blocked(state, control.map_id, .motion)) {
                pair = .{ state.buttons.mouse_delta[0] * delta.scale[0], state.buttons.mouse_delta[1] * delta.scale[1] };
            },
            .mouse_wheel => |wheel| if (!blocked(state, control.map_id, .wheel)) {
                one = state.buttons.wheel * wheel.scale;
            },
        }
        if (@abs(one) > @abs(scalar)) scalar = one;
        if (lengthSquared(pair) > lengthSquared(vector)) vector = pair;
    }
    return switch (control.kind) {
        .button => .{ .button = .{ .held = held } },
        .axis => .{ .axis = scalar },
        .vector => .{ .vector = vector },
    };
}
fn lengthSquared(value: [2]f32) f32 {
    return value[0] * value[0] + value[1] * value[1];
}

/// Host-only: recompute a State-shaped resolver's values from routed devices/buttons and
/// map priority. Requires validated bindings/chords and registered owners; `edges` permits
/// new press/release edges, while false avoids activating already-held input after a reset.
/// Mutates revision, trigger timing and cached values; caller owns end-of-frame edge clearing.
///
/// ```zig
/// // Host with a valid resolver state after changing routed physical input:
/// update(&state, true);
/// ```
pub fn update(state: anytype, edges: bool) void {
    state.revision +%= 1;
    for (0..state.controls.count()) |index| resolve(state, index, edges, 0);
}
fn resolve(state: anytype, index: usize, edges: bool, depth: usize) void {
    const control = &state.controls.values()[index];
    if (control.evaluated == state.revision) return;
    std.debug.assert(depth <= state.controls.count());
    control.evaluated = state.revision;
    const raw = rawValue(state, index);
    if (raw == .axis) {
        control.axis = raw.axis;
        return;
    }
    if (raw == .vector) {
        control.vector = raw.vector;
        return;
    }
    const physical = raw.button.held;
    const rule = trigger(control.*, &state.overrides, null);
    if (physical != control.physical) {
        if (!edges and physical) control.waiting_for_release = true;
        if (physical) {
            control.started_s = state.time_s;
            control.has_press = edges;
        }
        control.physical = physical;
    }
    if (!physical) control.waiting_for_release = false;
    var active = physical and !control.waiting_for_release;
    switch (rule) {
        .immediate => {},
        .hold => |seconds| active = active and control.has_press and state.time_s - control.started_s >= seconds,
        .tap => |seconds| {
            if (!physical and control.has_press and edges and state.time_s - control.started_s <= seconds) {
                control.value.pressed = true;
                control.value.released = true;
            }
            active = false;
        },
        .chord => |name| {
            const target = for (state.controls.values(), 0..) |candidate, i| {
                if (std.mem.eql(u8, candidate.owner, control.owner) and std.mem.eql(u8, candidate.name, name)) break i;
            } else unreachable;
            resolve(state, target, edges, depth + 1);
            const modifier = state.controls.values()[target];
            active = active and (modifier.value.held or (trigger(modifier, &state.overrides, null) == .tap and modifier.value.pressed));
        },
    }
    if (!physical) control.has_press = false;
    if (edges) {
        control.value.pressed = control.value.pressed or (active and !control.value.held);
        control.value.released = control.value.released or (!active and control.value.held);
    }
    control.value.held = active;
}
