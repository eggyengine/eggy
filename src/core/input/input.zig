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
/// Typed default entries; see `types.ControlBinding` for the constructor and example.
pub const ControlBinding = types.ControlBinding;
pub const Kind = types.Kind;
pub const Trigger = types.Trigger;
pub const Value = types.Value;
pub const ControlId = types.ControlId;
/// Code-defined map constructor; see `mapping.Map` for options and an example.
pub const Map = @import("mapping.zig").Map;
/// Resource-backed map constructor; see `mapping.FileMap` for paths and an example.
pub const FileMap = @import("mapping.zig").FileMap;
pub const asset = @import("asset.zig");
pub const bindings_file = @import("bindings.zig").file_name;

const key_count = types.key_count;
const KeySet = types.KeySet;

pub const Input = struct {
    /// Host-owned services; copied snapshots never own device handles or binding allocations.
    backend: ?protocol.Bridge = null,
    viewport_points: [2]f32 = .{ 1, 1 },
    keys_held: KeySet = .empty,
    keys_pressed: KeySet = .empty,
    keys_released: KeySet = .empty,
    buttons_held: std.EnumSet(MouseButton) = .empty,
    buttons_pressed: std.EnumSet(MouseButton) = .empty,
    buttons_released: std.EnumSet(MouseButton) = .empty,
    /// Where the pointer is in the window, in points from its top left corner.
    mouse_position: [2]f32 = .{ 0, 0 },
    /// How far it moved this frame, in points (right and down are positive).
    mouse_delta: [2]f32 = .{ 0, 0 },
    /// How far the wheel turned this frame, in notches (away from you is positive).
    wheel: f32 = 0,

    /// Whether `key` is down.
    /// Reads this snapshot without a backend; keys outside the supported scancode range are false.
    ///
    /// ```zig
    /// const walking = app.input.held(.w); // In a game hook.
    /// ```
    pub fn held(self: *const Input, key: Key) bool {
        return self.keys_held.isSet(index(key) orelse return false);
    }

    /// Whether `key` went down this frame.
    /// Repeated key-down events do not create new presses; cleared by the host at frame end.
    ///
    /// ```zig
    /// const jump_started = app.input.pressed(.space); // In a game hook.
    /// ```
    pub fn pressed(self: *const Input, key: Key) bool {
        return self.keys_pressed.isSet(index(key) orelse return false);
    }

    /// Whether `key` came up this frame.
    /// Only previously held keys produce releases; UI cancellation does not synthesize one.
    ///
    /// ```zig
    /// const stopped = app.input.released(.w); // In a game hook.
    /// ```
    pub fn released(self: *const Input, key: Key) bool {
        return self.keys_released.isSet(index(key) orelse return false);
    }

    /// -1 while `negative` is held, 1 while `positive` is, 0 with both or neither: one axis of
    /// movement from two keys, as `axis(.a, .d)` for left and right.
    ///
    /// ```zig
    /// const strafe = app.input.axis(.a, .d); // In a game hook.
    /// ```
    pub fn axis(self: *const Input, negative: Key, positive: Key) f32 {
        return @as(f32, @floatFromInt(@intFromBool(self.held(positive)))) - @as(f32, @floatFromInt(@intFromBool(self.held(negative))));
    }

    /// Horizontal and vertical axes, each -1, 0 or 1. Diagonals are not normalized.
    /// Positive Y means up here, unlike screen-space mapped vectors.
    ///
    /// ```zig
    /// const movement = app.input.direction(.{}); // Default WASD, in a game hook.
    /// ```
    pub fn direction(self: *const Input, keys: DirectionKeys) [2]f32 {
        return .{ self.axis(keys.left, keys.right), self.axis(keys.down, keys.up) };
    }

    /// Number of connected SDL gamepads. No connected devices is ordinary absence.
    /// Requires the host input bridge on its owning thread; does not allocate.
    ///
    /// ```zig
    /// const gamepad_count = try app.input.controllerCount();
    /// ```
    pub fn controllerCount(self: *const Input) !usize {
        return (try self.send(.{ .operation = .controller_count })).count;
    }
    /// Copy IDs into caller storage; BufferTooSmall never silently truncates devices.
    /// Returns a slice of `buffer`, not host storage; IDs may later disconnect.
    ///
    /// ```zig
    /// var storage: [8]eggy.input.Controller = undefined;
    /// const devices = try app.input.controllers(&storage);
    /// ```
    pub fn controllers(self: *const Input, buffer: []Controller) ![]const Controller {
        const response = try self.send(.{ .operation = .controllers, .output = buffer.ptr, .count = buffer.len });
        return buffer[0..response.count];
    }
    /// Copy connected IDs into caller-owned storage; free the result with `gpa.free`.
    /// Requires the host bridge; allocation/bridge errors leave no owned result.
    ///
    /// ```zig
    /// const devices = try app.input.controllersAlloc(gpa);
    /// defer gpa.free(devices);
    /// ```
    pub fn controllersAlloc(self: *const Input, gpa: std.mem.Allocator) ![]Controller {
        return self.sendAlloc(Controller, gpa, .{ .operation = .controllers });
    }
    /// Copy this device's routed gameplay buttons, frame edges and normalized analog values.
    /// No hidden dead zone is applied. A disconnected ID returns `ControllerDisconnected`;
    /// bridge/thread failures propagate. The returned value owns no device handles.
    ///
    /// ```zig
    /// // In a game hook, with device obtained from controllers:
    /// const state = try app.input.controllerState(device);
    /// ```
    pub fn controllerState(self: *const Input, device: Controller) !ControllerState {
        var state: ControllerState = undefined;
        _ = try self.send(.{ .operation = .controller_state, .device = @backingInt(device), .output = &state });
        return state;
    }
    /// Strengths are 0..1; zero both strengths to stop rumble. Calls stay on the host thread.
    /// `low` and `high` address the low/high-frequency motors; duration is seconds.
    /// Rejects non-finite/out-of-range values, disconnected devices and unsupported rumble.
    ///
    /// ```zig
    /// // In a game hook, with a connected rumble-capable device:
    /// try app.input.rumble(device, 0.5, 1.0, 0.15);
    /// ```
    pub fn rumble(self: *const Input, device: Controller, low: f32, high: f32, duration_s: f32) !void {
        if (!std.math.isFinite(low) or !std.math.isFinite(high) or low < 0 or low > 1 or high < 0 or high > 1) return error.InvalidRumble;
        if (!std.math.isFinite(duration_s) or duration_s < 0 or @as(f64, duration_s) * 1000 > std.math.maxInt(u32)) return error.InvalidDuration;
        _ = try self.send(.{ .operation = .rumble, .device = @backingInt(device), .low = @intFromFloat(@round(low * 65535)), .high = @intFromFloat(@round(high * 65535)), .duration_ms = @intFromFloat(@as(f64, duration_s) * 1000) });
    }
    /// Count tracked contacts, including contacts ended/cancelled until this frame ends.
    /// Requires the host bridge on its owning thread; no allocation is performed.
    ///
    /// ```zig
    /// const contact_count = try app.input.touchCount();
    /// ```
    pub fn touchCount(self: *const Input) !usize {
        return (try self.send(.{ .operation = .touch_count })).count;
    }
    /// Includes ended/cancelled contacts until endFrame, so quick taps are observable.
    /// Copies into `buffer` and returns its populated prefix; `BufferTooSmall` never truncates.
    /// Positions/deltas are viewport logical points, not pixels or normalized coordinates.
    ///
    /// ```zig
    /// var storage: [16]eggy.input.Touch = undefined;
    /// const contacts = try app.input.touches(&storage);
    /// ```
    pub fn touches(self: *const Input, buffer: []Touch) ![]const Touch {
        const response = try self.send(.{ .operation = .touches, .output = buffer.ptr, .count = buffer.len });
        return buffer[0..response.count];
    }
    /// Copy contacts, including ended/cancelled ones; free the result with `gpa.free`.
    /// Returned positions/deltas are viewport logical points; bridge/allocation failures propagate.
    ///
    /// ```zig
    /// const contacts = try app.input.touchesAlloc(gpa);
    /// defer gpa.free(contacts);
    /// ```
    pub fn touchesAlloc(self: *const Input, gpa: std.mem.Allocator) ![]Touch {
        return self.sendAlloc(Touch, gpa, .{ .operation = .touches });
    }

    /// Register a plugin's typed controls under its published key before init. Names/defaults
    /// are copied by the host; compilation-local markers are forgotten before library unload.
    /// Host-only: `Controls` is an enum with at most 64-bit tags. Missing defaults remain
    /// unbound buttons; duplicate definitions, invalid mappings and allocation failures error.
    ///
    /// ```zig
    /// const Controls = enum { jump };
    /// try input.registerControls(Controls, "game",
    ///     &.{.{ .control = .jump, .bindings = &.{.{ .key = .space }} }});
    /// ```
    pub fn registerControls(self: *Input, comptime Controls: type, owner: []const u8, defaults: []const ControlBinding(Controls)) !void {
        try self.registerType(Controls, marker.of(Controls), owner, defaults, 0, true, true);
    }

    /// Host-only: copy a code-defined `Map` and its activation/priority defaults into the resolver.
    /// `owner` is its stable published plugin/map key; registering a duplicate marker/key errors.
    /// The plugin set normally performs this before plugin init.
    ///
    /// ```zig
    /// // Host with Player declared by eggy.input.Map:
    /// try input.registerMap(Player, "game/player");
    /// ```
    pub fn registerMap(self: *Input, comptime Mapping: type, owner: []const u8) !void {
        try self.registerType(Mapping.Control, marker.of(Mapping), owner, Mapping.definitions, Mapping.priority, Mapping.enabled, Mapping.consume);
    }
    /// Register validated file defaults through the same host bridge as code-defined maps.
    /// Every declared enum control must have a matching file entry, with no unknown names.
    /// Host-only: supply a parsed/validated `asset.File` and the stable plugin/map owner.
    /// The host copies defaults, so the file arena can be released after registration.
    ///
    /// ```zig
    /// // Host with FilePlayer from FileMap and parsed file:
    /// try input.registerFileMap(FilePlayer, "game/player", file);
    /// ```
    pub fn registerFileMap(self: *Input, comptime Mapping: type, owner: []const u8, file: asset.File) !void {
        const tags = comptime std.enums.values(Mapping.Control);
        if (file.controls.len != tags.len) return error.InputMapControlsMismatch;
        var defaults: [tags.len]ControlBinding(Mapping.Control) = undefined;
        inline for (tags, &defaults) |tag, *entry| {
            const control = for (file.controls) |candidate| {
                if (std.mem.eql(u8, candidate.name, @tagName(tag))) break candidate;
            } else return error.InputMapControlsMismatch;
            entry.* = .{ .control = tag, .kind = control.kind, .trigger = control.trigger, .bindings = control.bindings };
        }
        try self.registerType(Mapping.Control, marker.of(Mapping), owner, &defaults, file.priority, file.enabled, file.consume);
    }
    fn registerType(self: *Input, comptime Controls: type, type_id: usize, owner: []const u8, defaults: []const ControlBinding(Controls), priority: i32, enabled: bool, consume: bool) !void {
        const tags = comptime std.enums.values(Controls);
        var definitions: [tags.len]types.ControlDefinition = undefined;
        inline for (tags, 0..) |control, i| {
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
            definitions[i] = .{ .tag = controlId(control).tag, .name = @tagName(control), .kind = value_kind, .trigger = trigger, .bindings = bindings };
        }
        const registration = types.Registration{ .type_marker = type_id, .owner = owner, .priority = priority, .enabled = enabled, .consume = consume, .controls = &definitions };
        _ = try self.send(.{ .operation = .register_controls, .data = &registration });
    }
    /// Borrow a named map for this input snapshot; gameplay references logical controls only.
    /// `Mapping` is a registered `Map`/`FileMap`; this view must not outlive `self`.
    /// Construction makes no requests; queries fail if its map is unregistered.
    ///
    /// ```zig
    /// // In a game hook with registered Player map:
    /// const player = app.input.map(Player);
    /// ```
    pub fn map(self: *const Input, comptime Mapping: type) MapView(Mapping) {
        return .{ .input = self };
    }
    /// Replace a control's mappings with one binding. Editor project changes are saved; the
    /// build bakes them into the runtime. Use setBindings to retain multiple input sources.
    /// `control` is a value of a registered legacy controls enum, not a named map's enum;
    /// use `map(Mapping).rebind` for named maps. Validation/save/bridge failures propagate.
    ///
    /// ```zig
    /// // Controls registered with registerControls:
    /// try app.input.rebind(Controls.jump, .{ .key = .j });
    /// ```
    pub fn rebind(self: *Input, control: anytype, binding: Binding) !void {
        try self.setBindings(control, &.{binding});
    }
    /// Replace all bindings of a registered legacy enum control; an empty slice unbinds it.
    /// The host copies bindings and saves editor project edits before applying them.
    /// Invalid kinds/bindings, unknown controls and save/bridge failures return errors.
    ///
    /// ```zig
    /// try app.input.setBindings(Controls.jump, &.{ .{ .key = .space },
    ///     .{ .controller = .{ .button = .south } } });
    /// ```
    pub fn setBindings(self: *Input, control: anytype, bindings: []const Binding) !void {
        _ = try self.send(.{ .operation = .set_bindings, .control = controlId(control), .data = bindings.ptr, .count = bindings.len });
    }
    /// Remove a legacy enum control's project override, restoring registered bindings/trigger.
    /// The host validates and persists the reset; unknown control, save and bridge errors propagate.
    ///
    /// ```zig
    /// try app.input.resetBindings(Controls.jump);
    /// ```
    pub fn resetBindings(self: *Input, control: anytype) !void {
        _ = try self.send(.{ .operation = .reset_bindings, .control = controlId(control) });
    }
    /// Copy effective bindings for a registered legacy enum control into `buffer`.
    /// Returns its populated prefix; insufficient storage returns `BufferTooSmall`.
    /// Does not include a trigger or transfer host allocations.
    ///
    /// ```zig
    /// var storage: [8]eggy.input.Binding = undefined;
    /// const bindings = try app.input.getBindings(Controls.jump, &storage);
    /// ```
    pub fn getBindings(self: *const Input, control: anytype, buffer: []Binding) ![]const Binding {
        const response = try self.send(.{ .operation = .get_bindings, .control = controlId(control), .output = buffer.ptr, .count = buffer.len });
        return buffer[0..response.count];
    }
    /// Copy a control's current bindings; free the result with `gpa.free`.
    /// Takes a registered legacy controls enum value; allocation and bridge failures propagate.
    ///
    /// ```zig
    /// const bindings = try app.input.getBindingsAlloc(gpa, Controls.jump);
    /// defer gpa.free(bindings);
    /// ```
    pub fn getBindingsAlloc(self: *const Input, gpa: std.mem.Allocator, control: anytype) ![]Binding {
        return self.sendAlloc(Binding, gpa, .{ .operation = .get_bindings, .control = controlId(control) });
    }
    /// Copy the resolved held/pressed/released state of a registered legacy button control.
    /// Non-buttons return `WrongControlKind`; unknown controls and bridge failures are errors.
    ///
    /// ```zig
    /// const jump = try app.input.controlState(Controls.jump);
    /// ```
    pub fn controlState(self: *const Input, control: anytype) !ControlState {
        var state: ControlState = undefined;
        _ = try self.send(.{ .operation = .control_state, .control = controlId(control), .output = &state });
        return state;
    }
    /// Whether a registered legacy button control is currently active after map resolution.
    /// Uses `controlState` and propagates its unknown-control/kind/bridge errors.
    ///
    /// ```zig
    /// const jumping = try app.input.heldControl(Controls.jump);
    /// ```
    pub fn heldControl(self: *const Input, control: anytype) !bool {
        return (try self.controlState(control)).held;
    }
    /// Whether a registered legacy button control activated this frame; edges last until endFrame.
    /// Propagates `controlState` errors rather than treating an unknown control as false.
    ///
    /// ```zig
    /// const jump_started = try app.input.pressedControl(Controls.jump);
    /// ```
    pub fn pressedControl(self: *const Input, control: anytype) !bool {
        return (try self.controlState(control)).pressed;
    }
    /// Whether a registered legacy button control deactivated this frame.
    /// Propagates `controlState` errors; UI cancellation does not synthesize release edges.
    ///
    /// ```zig
    /// const jump_ended = try app.input.releasedControl(Controls.jump);
    /// ```
    pub fn releasedControl(self: *const Input, control: anytype) !bool {
        return (try self.controlState(control)).released;
    }

    fn send(self: *const Input, request: protocol.Request) !protocol.Response {
        const backend = self.backend orelse return error.NoInputBackend;
        var response = protocol.Response{};
        try protocol.check(backend.request(backend.context, &request, &response));
        return response;
    }
    fn sendAlloc(self: *const Input, comptime T: type, gpa: std.mem.Allocator, request: protocol.Request) ![]T {
        const size = try self.send(request);
        const buffer = try gpa.alloc(T, size.count);
        errdefer gpa.free(buffer);
        var read = request;
        read.output = buffer.ptr;
        read.count = buffer.len;
        const response = try self.send(read);
        return try gpa.realloc(buffer, response.count);
    }
    fn notify(self: *const Input, operation: protocol.Operation) void {
        if (self.backend == null) return;
        const buttons = types.Buttons{ .keys = self.keys_held, .mouse = self.buttons_held, .mouse_delta = self.mouse_delta, .wheel = self.wheel };
        if (self.send(.{ .operation = operation, .data = &buttons })) |_| {} else |err| {
            std.log.err("input {t} failed: {t}", .{ operation, err });
        }
    }

    /// Forget gameplay state when UI takes capture, without synthesizing release actions.
    /// Host-only: preserves the backend, viewport size and pointer position. Backend failures
    /// are logged because capture cleanup cannot return an error.
    ///
    /// ```zig
    /// // Host after UI acquires keyboard focus:
    /// input.cancel();
    /// ```
    pub fn cancel(self: *Input) void {
        self.* = .{ .mouse_position = self.mouse_position, .backend = self.backend, .viewport_points = self.viewport_points };
        self.notify(.cancel);
    }

    /// Whether this mouse button is held in the gameplay snapshot; no backend request.
    ///
    /// ```zig
    /// const looking = app.input.mouseHeld(.right);
    /// ```
    pub fn mouseHeld(self: *const Input, button: MouseButton) bool {
        return self.buttons_held.contains(button);
    }

    /// Whether this mouse button went down this frame; cleared at the host's frame end.
    ///
    /// ```zig
    /// const clicked = app.input.mousePressed(.left);
    /// ```
    pub fn mousePressed(self: *const Input, button: MouseButton) bool {
        return self.buttons_pressed.contains(button);
    }

    /// Whether a previously held mouse button came up this frame; UI cancellation is not a release.
    ///
    /// ```zig
    /// const drag_ended = app.input.mouseReleased(.left);
    /// ```
    pub fn mouseReleased(self: *const Input, button: MouseButton) bool {
        return self.buttons_released.contains(button);
    }

    /// Take in an event from the window.
    /// Host-only: route only gameplay-approved events, with coordinates already localized to
    /// the viewport. Updates this snapshot before forwarding to the bridge; a bridge error
    /// does not roll back local keys/pointer state. Focus loss releases held input.
    ///
    /// ```zig
    /// // Host after UI routing accepts an SDL event:
    /// try input.handle(event);
    /// ```
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
    /// Host-only: held state survives; ended/cancelled touches expire in the backend.
    /// Backend notification failures are logged.
    ///
    /// ```zig
    /// // Host after all gameplay hooks for this frame:
    /// input.endFrame();
    /// ```
    pub fn endFrame(self: *Input) void {
        self.keys_pressed = .empty;
        self.keys_released = .empty;
        self.buttons_pressed = .empty;
        self.buttons_released = .empty;
        self.mouse_delta = .{ 0, 0 };
        self.wheel = 0;
        self.notify(.end_frame);
    }

    /// Let go of every key and button, as if each came up.
    /// Host-only: synthesizes releases for held gameplay input and cancels contacts.
    /// Unlike `cancel`, this exposes release edges; backend failures are logged.
    ///
    /// ```zig
    /// // Host handling window focus loss:
    /// input.releaseAll();
    /// ```
    pub fn releaseAll(self: *Input) void {
        self.keys_released.setUnion(self.keys_held);
        self.keys_held = .empty;
        self.buttons_released.setUnion(self.buttons_held);
        self.buttons_held = .empty;
        self.notify(.release_all);
    }

    /// Withhold a UI-consumed event while cleaning up any gameplay hold it would release.
    /// Taking keyboard focus with a UI click cancels gameplay without synthetic edges.
    /// Host-only: use viewport-local coordinates as for `handle`. Does not route the event
    /// as gameplay; backend failures are logged.
    ///
    /// ```zig
    /// // Host after the UI consumes event:
    /// input.suppress(event);
    /// ```
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

/// The borrowed query/edit view returned by `Input.map` for a typed `Map` or `FileMap`.
/// `Mapping.Control` supplies enum tags; its marker must have been registered on the host.
/// Prefer `app.input.map(Mapping)` to constructing this type; do not outlive the input snapshot.
///
/// ```zig
/// // In a hook with a registered Player map:
/// const player: eggy.input.MapView(Player) = app.input.map(Player);
/// ```
pub fn MapView(comptime Mapping: type) type {
    return struct {
        input: *const Input,
        const Self = @This();
        fn id(control: Mapping.Control) types.ControlId {
            var result = controlId(control);
            result.type_marker = marker.of(Mapping);
            return result;
        }
        /// Copy the resolved tagged button/axis/vector value of this map's control.
        /// Unknown map/control and bridge/thread failures propagate; no storage is borrowed.
        ///
        /// ```zig
        /// // player = app.input.map(Player), whose enum contains jump:
        /// const jump_value = try player.value(.jump);
        /// ```
        pub fn value(self: Self, control: Mapping.Control) !Value {
            var result: Value = undefined;
            _ = try self.input.send(.{ .operation = .control_value, .control = id(control), .output = &result });
            return result;
        }
        /// Read a button control's held and frame-edge state; non-buttons return `WrongControlKind`.
        /// Multiple sources are aggregated before trigger/priority resolution.
        ///
        /// ```zig
        /// const jump = try app.input.map(Player).button(.jump); // Player declares a button.
        /// ```
        pub fn button(self: Self, control: Mapping.Control) !ControlState {
            const result = try self.value(control);
            return if (result == .button) result.button else error.WrongControlKind;
        }
        /// Whether this button control activated this frame; propagates `button` errors.
        /// A tap may report both pressed and released in the same frame.
        ///
        /// ```zig
        /// const jump_started = try app.input.map(Player).pressed(.jump);
        /// ```
        pub fn pressed(self: Self, control: Mapping.Control) !bool {
            return (try self.button(control)).pressed;
        }
        /// Whether this button control is active after its trigger and priority rules.
        /// Propagates `button` errors; tap triggers pulse rather than remain held.
        ///
        /// ```zig
        /// const charging = try app.input.map(Player).held(.charge);
        /// ```
        pub fn held(self: Self, control: Mapping.Control) !bool {
            return (try self.button(control)).held;
        }
        /// Whether this button control deactivated this frame; propagates `button` errors.
        /// Capture cancellation clears state without synthesizing this edge.
        ///
        /// ```zig
        /// const jump_ended = try app.input.map(Player).released(.jump);
        /// ```
        pub fn released(self: Self, control: Mapping.Control) !bool {
            return (try self.button(control)).released;
        }
        /// Read a scalar axis after binding scale/dead-zone and priority processing.
        /// Sources select the largest absolute value, not their sum; non-axis kinds error.
        ///
        /// ```zig
        /// // Player declares throttle with kind .axis:
        /// const throttle = try app.input.map(Player).axis(.throttle);
        /// ```
        pub fn axis(self: Self, control: Mapping.Control) !f32 {
            const result = try self.value(control);
            return if (result == .axis) result.axis else error.WrongControlKind;
        }
        /// Read a vector after binding modifiers, selecting the source with greatest magnitude.
        /// Digital keys use right/down-positive coordinates; scales can change units/sign.
        /// Non-vector controls return `WrongControlKind`; bridge failures propagate.
        ///
        /// ```zig
        /// // Player declares move with kind .vector:
        /// const movement = try app.input.map(Player).vector(.move);
        /// ```
        pub fn vector(self: Self, control: Mapping.Control) !@import("eggenvector").Vec2 {
            const result = try self.value(control);
            return if (result == .vector) .{ .x = result.vector[0], .y = result.vector[1] } else error.WrongControlKind;
        }
        /// Context activation is session state; it never rewrites developer project defaults.
        /// Resets trigger evaluation without inventing presses from already-held sources.
        /// Unknown map and bridge/thread failures propagate.
        ///
        /// ```zig
        /// try app.input.map(Menu).setEnabled(true); // Registered menu context.
        /// ```
        pub fn setEnabled(self: Self, enabled: bool) !void {
            _ = try self.input.send(.{ .operation = .map_enabled, .control = .{ .type_marker = marker.of(Mapping), .tag = 0 }, .count = @intFromBool(enabled) });
        }
        /// Change this map's session-only priority; higher consuming maps block shared sources.
        /// Equal priorities do not block each other. Resets evaluation and does not save defaults.
        /// Unknown map and bridge failures propagate.
        ///
        /// ```zig
        /// try app.input.map(Menu).setPriority(10);
        /// ```
        pub fn setPriority(self: Self, priority: i32) !void {
            _ = try self.input.send(.{ .operation = .map_priority, .control = .{ .type_marker = marker.of(Mapping), .tag = 0 }, .priority = priority });
        }
        /// Replace this map control's bindings with one source, retaining its effective trigger.
        /// Editor project edits persist; invalid kind/binding and save/bridge failures propagate.
        ///
        /// ```zig
        /// try app.input.map(Player).rebind(.jump, .{ .key = .j });
        /// ```
        pub fn rebind(self: Self, control: Mapping.Control, binding: Binding) !void {
            try self.setBindings(control, &.{binding});
        }
        /// Copy a complete replacement binding list; empty unbinds this map's control.
        /// Sources must match its declared kind. The host saves editor edits before applying;
        /// validation, allocation, save and bridge failures propagate.
        ///
        /// ```zig
        /// try app.input.map(Player).setBindings(.jump,
        ///     &.{ .{ .key = .space }, .{ .controller = .{ .button = .south } } });
        /// ```
        pub fn setBindings(self: Self, control: Mapping.Control, bindings: []const Binding) !void {
            _ = try self.input.send(.{ .operation = .set_bindings, .control = id(control), .data = bindings.ptr, .count = bindings.len });
        }
        /// Replace a button trigger; editor project edits persist just like binding edits.
        /// Hold/tap thresholds are finite nonnegative unscaled gameplay seconds; chords name
        /// another button in this map. Invalid kinds, missing/cyclic chords and save errors fail.
        ///
        /// ```zig
        /// try app.input.map(Player).setTrigger(.charge, .{ .hold = 0.25 });
        /// ```
        pub fn setTrigger(self: Self, control: Mapping.Control, trigger: Trigger) !void {
            _ = try self.input.send(.{ .operation = .set_trigger, .control = id(control), .data = &trigger });
        }
        /// Remove this control's bindings/trigger override, restoring registered map defaults.
        /// Validation/save failures leave the active override intact; unknown controls error.
        ///
        /// ```zig
        /// try app.input.map(Player).resetBindings(.jump);
        /// ```
        pub fn resetBindings(self: Self, control: Mapping.Control) !void {
            _ = try self.input.send(.{ .operation = .reset_bindings, .control = id(control) });
        }
        /// Copy this map control's effective bindings into caller storage, returning its prefix.
        /// Insufficient capacity returns `BufferTooSmall`, never a truncated list.
        /// Unknown controls and bridge failures propagate.
        ///
        /// ```zig
        /// var storage: [8]eggy.input.Binding = undefined;
        /// const bindings = try app.input.map(Player).getBindings(.jump, &storage);
        /// ```
        pub fn getBindings(self: Self, control: Mapping.Control, buffer: []Binding) ![]const Binding {
            const response = try self.input.send(.{ .operation = .get_bindings, .control = id(control), .output = buffer.ptr, .count = buffer.len });
            return buffer[0..response.count];
        }
        /// Copy a mapped control's current bindings; free the result with `gpa.free`.
        /// The copy survives later rebinds; allocation and bridge failures propagate.
        ///
        /// ```zig
        /// const bindings = try app.input.map(Player).getBindingsAlloc(gpa, .jump);
        /// defer gpa.free(bindings);
        /// ```
        pub fn getBindingsAlloc(self: Self, gpa: std.mem.Allocator, control: Mapping.Control) ![]Binding {
            return self.input.sendAlloc(Binding, gpa, .{ .operation = .get_bindings, .control = id(control) });
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
    const tag: u64 = if (@typeInfo(Tag).int.signedness == .signed) @bitCast(@as(i64, @backingInt(control))) else @intCast(@backingInt(control));
    return .{ .type_marker = marker.of(T), .tag = tag };
}

fn index(key: Key) ?usize {
    const at: usize = @intCast(@backingInt(key));
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

test "allocated input lists free their buffer if the copy fails" {
    const Host = struct {
        fn request(_: *anyopaque, read: *const protocol.Request, response: *protocol.Response) callconv(.c) protocol.Status {
            response.count = 2;
            return if (read.output == null) .ok else .io_failed;
        }
    };
    var context: u8 = 0;
    const input = Input{ .backend = .{ .context = &context, .request = Host.request } };
    try std.testing.expectError(error.InputSettingsFailed, input.controllersAlloc(std.testing.allocator));
    try std.testing.expectError(error.InputSettingsFailed, input.touchesAlloc(std.testing.allocator));
}
