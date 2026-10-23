//! Developer input-map editing with captured keys and persistent modifiers/triggers.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const sdl = eggy.sdl_adapter.sdl;
const page_style = @import("page_style.zig");
const restyle = page_style.restyle;
const beginSection = page_style.beginSection;
const endSection = page_style.endSection;
const endRow = page_style.endRow;
const State = eggy.input_backend.State;
const t = eggy.input;

const Capture = enum { key, negative, positive, left, right, up, down, mouse, controller };
const trigger_names = [_][]const u8{ "Immediate", "Hold", "Tap", "Chord" };
const button_names = std.meta.fieldNames(t.ControllerButton);
const mouse_names = std.meta.fieldNames(t.MouseButton);
const axis_names = std.meta.fieldNames(sdl.gamepad.Axis);
const stick_names = [_][]const u8{ "Left", "Right" };
const button_sources = [_][]const u8{ "Keyboard key", "Mouse button", "Controller button" };
const axis_sources = [_][]const u8{ "Two keys", "Controller axis", "Mouse wheel" };
const vector_sources = [_][]const u8{ "Four keys", "Controller stick", "Mouse movement" };

/// Pure UI state; the SDL window is owned separately so the editor can exercise this in tests.
pub const View = struct {
    source: enum { registered, asset } = .registered,
    scroll: ui.Layout.ScrollState = .{},
    map_index: usize = 0,
    control_index: usize = 0,
    binding_index: usize = 0,
    source_index: usize = 0,
    loaded: ?eggy.input.ControlId = null,
    loaded_revision: u64 = 0,
    loaded_binding: usize = 0,
    draft: ?t.Binding = null,
    is_new: bool = false,
    numbers: [4]ui.TextEdit(64) = @splat(.{}),
    trigger_index: usize = 0,
    duration: ui.TextEdit(64) = .{},
    chord_index: usize = 0,
    capture: ?Capture = null,
    last_error: ?anyerror = null,
    loaded_map: ?usize = null,
    map_revision: u64 = 0,
    map_enabled: bool = true,
    priority: ui.TextEdit(32) = .{},

    fn number(self: *View, index: usize, value: f32) !void {
        var buffer: [64]u8 = undefined;
        try self.numbers[index].set(try std.fmt.bufPrint(&buffer, "{d}", .{value}));
    }
    fn setDraft(self: *View, binding: t.Binding) !void {
        self.draft = binding;
        self.capture = null;
        switch (binding) {
            .key, .mouse, .controller => {},
            .key_axis => |value| try self.number(0, value.scale),
            .keys_2d => |value| {
                try self.number(0, value.scale[0]);
                try self.number(1, value.scale[1]);
            },
            .controller_axis => |value| {
                try self.number(0, value.scale);
                try self.number(1, value.dead_zone);
            },
            .controller_stick => |value| {
                try self.number(0, value.scale[0]);
                try self.number(1, value.scale[1]);
                try self.number(2, value.dead_zone);
            },
            .mouse_delta => |value| {
                try self.number(0, value.scale[0]);
                try self.number(1, value.scale[1]);
            },
            .mouse_wheel => |value| try self.number(0, value.scale),
        }
    }
    fn selected(self: *View, state: *State) ?usize {
        if (state.owners.count() == 0) return null;
        self.map_index = @min(self.map_index, state.owners.count() - 1);
        var iterator = state.owners.keyIterator();
        var map_id: usize = 0;
        for (0..self.map_index + 1) |_| map_id = iterator.next().?.*;
        var count: usize = 0;
        for (state.controls.values(), 0..) |control, i| {
            if (control.map_id != map_id) continue;
            if (count == self.control_index) return i;
            count += 1;
        }
        self.control_index = 0;
        for (state.controls.values(), 0..) |control, i| if (control.map_id == map_id) return i;
        return null;
    }

    /// Build the internal mapping editor in an active UI frame, borrowing the registered
    /// backend. Save/reset actions mutate mappings and may call its persistence writer;
    /// the view owns drafts across frames, while labels use the context's frame arena.
    /// Allocation errors propagate; edit-validation failures are displayed in the view.
    ///
    /// ```zig
    /// // Editor host: context.newFrame has run and state contains registered maps.
    /// var view = View{};
    /// try view.build(context, state);
    /// ```
    pub fn build(self: *View, context: *ui.Context, state: *State) !void {
        const arena = context.builder().allocator;
        if (self.source == .registered) {
            context.heading(2, "Input mappings");
            context.muted("Code reads named controls. Project edits are baked into shipped games.");
            if (state.persistence == null) context.muted("No project is open: edits here are session-only.");
        }
        if (self.last_error) |err| context.alert("Could not apply edit", @errorName(err), true);
        if (self.capture != null) context.alert("Press the input to bind", "Escape cancels.", false);
        // Dropdown text remains in the previous-frame tree when a map is replaced.
        const map_labels = try arena.alloc([]const u8, state.owners.count());
        var maps = state.owners.valueIterator();
        for (map_labels) |*label| label.* = try arena.dupe(u8, maps.next().?.key);
        if (map_labels.len == 0) {
            context.muted("No maps registered. Declare input_maps on your game or plugin.");
            return;
        }

        // The map: which one, and how it starts.
        beginSection(context, "Map");
        if (self.source == .registered and context.select("Map", map_labels, &self.map_index)) {
            self.control_index = 0;
            self.binding_index = 0;
            self.loaded = null;
        }
        const map_id: ?usize = if (self.selected(state)) |first| state.controls.values()[first].map_id else null;
        if (map_id) |id| try self.mapDefaults(context, state, id);
        endSection(context);
        const shown_map = map_id orelse return;

        // The control: which one, and what it reads as.
        var labels: std.ArrayList([]const u8) = .empty;
        for (state.controls.values()) |control| if (control.map_id == shown_map) try labels.append(arena, try arena.dupe(u8, control.name));
        beginSection(context, "Control");
        context.begin(.row);
        if (context.select("Control", labels.items, &self.control_index)) {
            self.binding_index = 0;
            self.loaded = null;
        }
        restyle(context, .{ .grow = 1 });
        const index = self.selected(state);
        if (index) |i| context.badge(@tagName(state.controls.values()[i].kind), .secondary);
        endRow(context);
        if (index) |i| if (self.source == .registered and context.buttonVariant("Reset control to map defaults", .link)) {
            if (state.resetMappings(state.controls.keys()[i])) |_| {
                self.loaded = null;
                self.last_error = null;
            } else |err| self.last_error = err;
        };
        endSection(context);
        const shown = index orelse return;
        const control = state.controls.values()[shown];
        const id = state.controls.keys()[shown];
        const mappings = state.overrides.get(control.key) orelse control.defaults;
        try self.load(state, control, id, mappings, labels.items);

        beginSection(context, "Bindings");
        const reselected = try self.bindings(context, state, control, id, mappings);
        endSection(context);
        if (reselected) return;
        if (control.kind == .button) {
            beginSection(context, "Trigger");
            self.trigger(context, state, id, mappings, labels.items);
            endSection(context);
        }
    }

    /// The map's startup state and priority, saved together.
    fn mapDefaults(self: *View, context: *ui.Context, state: *State, map_id: usize) !void {
        const map = state.owners.get(map_id).?;
        const defaults = state.overrides.maps.get(map.key) orelse map.defaults;
        if (self.loaded_map != map_id or self.map_revision != state.configuration_revision) {
            self.loaded_map = map_id;
            self.map_revision = state.configuration_revision;
            self.map_enabled = defaults.enabled;
            var buffer: [32]u8 = undefined;
            try self.priority.set(try std.fmt.bufPrint(&buffer, "{d}", .{defaults.priority}));
        }
        context.begin(.row);
        _ = context.checkbox("Enabled at startup", &self.map_enabled);
        _ = context.textInput("Map priority", &self.priority, "Higher maps own shared inputs");
        endRow(context);
        context.muted("Runtime switching is temporary; these defaults ship with the game.");
        context.begin(.row);
        if (context.buttonVariant(if (self.source == .asset) "Apply map settings" else "Save map defaults", .secondary)) {
            if (std.fmt.parseInt(i32, self.priority.text(), 10)) |priority| {
                if (state.setMapDefaults(map_id, .{ .enabled = self.map_enabled, .priority = priority })) |_| {
                    self.last_error = null;
                } else |err| self.last_error = err;
            } else |_| self.last_error = error.InvalidPriority;
        }
        if (self.source == .registered and context.buttonVariant("Reset map defaults", .ghost)) {
            if (state.setMapDefaults(map_id, null)) |_| {
                self.last_error = null;
            } else |err| self.last_error = err;
        }
        endRow(context);
    }

    /// Read the control's bindings and trigger into the drafts when it, or the configuration,
    /// changed since last frame.
    fn load(self: *View, state: *State, control: anytype, id: eggy.input.ControlId, mappings: []const t.Binding, labels: []const []const u8) !void {
        if (self.loaded != null and std.meta.eql(self.loaded.?, id) and self.loaded_revision == state.configuration_revision and self.loaded_binding == self.binding_index) return;
        self.loaded = id;
        self.loaded_revision = state.configuration_revision;
        self.binding_index = if (mappings.len == 0) 0 else @min(self.binding_index, mappings.len - 1);
        self.loaded_binding = self.binding_index;
        self.is_new = false;
        self.draft = null;
        if (mappings.len != 0) try self.setDraft(mappings[self.binding_index]);
        const rule = state.overrides.getTrigger(control.key) orelse control.trigger;
        self.trigger_index = @backingInt(std.meta.activeTag(rule));
        var buffer: [64]u8 = undefined;
        try self.duration.set(try std.fmt.bufPrint(&buffer, "{d}", .{switch (rule) {
            .hold, .tap => |seconds| seconds,
            else => @as(f32, 0.25),
        }}));
        self.chord_index = 0;
        if (rule == .chord) for (labels, 0..) |label, i| if (std.mem.eql(u8, label, rule.chord)) {
            self.chord_index = i;
        };
    }

    /// The control's bindings: pick one to edit, or add one from a source. Returns whether a
    /// different binding was picked, which loads next frame.
    fn bindings(self: *View, context: *ui.Context, state: *State, control: anytype, id: eggy.input.ControlId, mappings: []const t.Binding) !bool {
        const arena = context.builder().allocator;
        const binding_labels = try arena.alloc([]const u8, mappings.len);
        for (mappings, binding_labels, 0..) |binding, *label, i| label.* = try std.fmt.allocPrint(arena, "{d}: {s}", .{ i + 1, @tagName(binding) });
        if (binding_labels.len != 0 and context.select("Binding", binding_labels, &self.binding_index)) {
            self.loaded = null;
            return true;
        }
        if (binding_labels.len == 0) context.muted("No bindings yet: add one below.");
        const sources: []const []const u8 = switch (control.kind) {
            .button => &button_sources,
            .axis => &axis_sources,
            .vector => &vector_sources,
        };
        self.source_index = @min(self.source_index, sources.len - 1);
        context.begin(.row);
        _ = context.select("New binding source", sources, &self.source_index);
        restyle(context, .{ .grow = 1 });
        if (context.buttonVariant("Add binding", .outline)) {
            self.is_new = true;
            try self.setDraft(defaultBinding(control.kind, self.source_index));
        }
        endRow(context);
        const draft = if (self.draft) |*draft| draft else return false;
        context.separator();
        context.muted(if (self.is_new) "New binding" else "Selected binding");
        try self.editBinding(context, draft);
        context.begin(.row);
        if (context.buttonVariant(if (self.source == .asset) "Apply binding" else "Save binding", .secondary)) {
            if (self.saveBinding(state, id, mappings)) |_| {
                self.last_error = null;
                self.loaded = null;
            } else |err| self.last_error = err;
        }
        if (!self.is_new and context.buttonVariant("Remove binding", .ghost)) {
            const next = try arena.alloc(t.Binding, mappings.len - 1);
            var at: usize = 0;
            for (mappings, 0..) |binding, i| if (i != self.binding_index) {
                next[at] = binding;
                at += 1;
            };
            if (state.setMappings(id, next, state.overrides.getTrigger(control.key))) |_| {
                self.loaded = null;
                self.last_error = null;
            } else |err| self.last_error = err;
        }
        endRow(context);
        return false;
    }

    /// A button control's trigger rule: immediate, held, tapped or chorded with another control.
    fn trigger(self: *View, context: *ui.Context, state: *State, id: eggy.input.ControlId, mappings: []const t.Binding, labels: []const []const u8) void {
        context.begin(.row);
        _ = context.select("Trigger", &trigger_names, &self.trigger_index);
        if (self.trigger_index == 1 or self.trigger_index == 2) _ = context.textInput("Seconds", &self.duration, "Nonnegative counted input seconds");
        if (self.trigger_index == 3) _ = context.select("Chord control", labels, &self.chord_index);
        endRow(context);
        if (!context.buttonVariant(if (self.source == .asset) "Apply trigger" else "Save trigger", .secondary)) return;
        const seconds = std.fmt.parseFloat(f32, self.duration.text()) catch null;
        const rule: t.Trigger = switch (self.trigger_index) {
            1 => .{ .hold = seconds orelse return self.fail(error.InvalidTrigger) },
            2 => .{ .tap = seconds orelse return self.fail(error.InvalidTrigger) },
            3 => .{ .chord = labels[@min(self.chord_index, labels.len - 1)] },
            else => .immediate,
        };
        if (state.setMappings(id, mappings, rule)) |_| {
            self.loaded = null;
            self.last_error = null;
        } else |err| self.last_error = err;
    }

    fn fail(self: *View, err: anyerror) void {
        self.last_error = err;
    }

    fn captureKey(self: *View, context: *ui.Context, label: []const u8, key: t.Key, target: Capture) void {
        const capturing = self.capture == target;
        const text = (if (capturing) std.fmt.allocPrint(context.builder().allocator, "{s}: press a key...", .{label}) else std.fmt.allocPrint(context.builder().allocator, "{s}: {t}", .{ label, key })) catch |err| {
            context.err = err;
            return;
        };
        if (context.buttonVariant(text, if (capturing) .default else .outline)) self.capture = target;
    }
    fn editBinding(self: *View, context: *ui.Context, draft: *t.Binding) !void {
        switch (draft.*) {
            .key => |key| self.captureKey(context, "Key", key, .key),
            .mouse => |*mouse| {
                var selected_index: usize = @backingInt(mouse.*);
                if (context.select("Mouse button", mouse_names, &selected_index)) mouse.* = @fromBackingInt(@intCast(selected_index));
            },
            .controller => |*controller| {
                var selected_index: usize = @backingInt(controller.button);
                if (context.select("Controller button", button_names, &selected_index)) controller.button = @fromBackingInt(@intCast(selected_index));
                if (context.buttonVariant(if (self.capture == .controller) "Press a controller button..." else "Capture controller button", .outline)) self.capture = .controller;
            },
            .key_axis => |axis| {
                context.beginGrid(2);
                self.captureKey(context, "Negative key", axis.negative, .negative);
                self.captureKey(context, "Positive key", axis.positive, .positive);
                context.end();
                _ = context.textInput("Axis scale", &self.numbers[0], "1 or -1");
            },
            .keys_2d => |*keys| {
                context.beginGrid(2);
                self.captureKey(context, "Left key", keys.keys.left, .left);
                self.captureKey(context, "Right key", keys.keys.right, .right);
                self.captureKey(context, "Up key", keys.keys.up, .up);
                self.captureKey(context, "Down key", keys.keys.down, .down);
                context.end();
                _ = context.checkbox("Normalize diagonal movement", &keys.normalize);
                self.vectorNumbers(context);
            },
            .controller_axis => |*axis| {
                var selected_index: usize = @intCast(@backingInt(axis.axis));
                if (context.select("Controller axis", axis_names, &selected_index)) axis.axis = @fromBackingInt(@intCast(selected_index));
                _ = context.textInput("Axis scale", &self.numbers[0], "1 or -1");
                _ = context.textInput("Dead zone", &self.numbers[1], "0 to less than 1");
            },
            .controller_stick => |*stick| {
                var selected_index: usize = @backingInt(stick.stick);
                if (context.select("Stick", &stick_names, &selected_index)) stick.stick = @fromBackingInt(@intCast(selected_index));
                self.vectorNumbers(context);
                _ = context.textInput("Dead zone", &self.numbers[2], "0 to less than 1");
            },
            .mouse_delta => self.vectorNumbers(context),
            .mouse_wheel => {
                _ = context.textInput("Wheel scale", &self.numbers[0], "1");
            },
        }
    }
    fn vectorNumbers(self: *View, context: *ui.Context) void {
        context.begin(.row);
        _ = context.textInput("X scale", &self.numbers[0], "1");
        _ = context.textInput("Y scale", &self.numbers[1], "1 or -1");
        endRow(context);
    }
    fn parseNumber(self: *const View, index: usize) !f32 {
        return std.fmt.parseFloat(f32, self.numbers[index].text());
    }
    fn saveBinding(self: *View, state: *State, id: eggy.input.ControlId, mappings: []const t.Binding) !void {
        var draft = self.draft.?;
        switch (draft) {
            .key, .mouse, .controller => {},
            .key_axis => |*value| value.scale = try self.parseNumber(0),
            .keys_2d => |*value| value.scale = .{ try self.parseNumber(0), try self.parseNumber(1) },
            .controller_axis => |*value| {
                value.scale = try self.parseNumber(0);
                value.dead_zone = try self.parseNumber(1);
            },
            .controller_stick => |*value| {
                value.scale = .{ try self.parseNumber(0), try self.parseNumber(1) };
                value.dead_zone = try self.parseNumber(2);
            },
            .mouse_delta => |*value| value.scale = .{ try self.parseNumber(0), try self.parseNumber(1) },
            .mouse_wheel => |*value| value.scale = try self.parseNumber(0),
        }
        const next = try state.gpa.alloc(t.Binding, mappings.len + @intFromBool(self.is_new));
        defer state.gpa.free(next);
        @memcpy(next[0..mappings.len], mappings);
        next[if (self.is_new) mappings.len else self.binding_index] = draft;
        const control = state.controls.get(id).?;
        try state.setMappings(id, next, state.overrides.getTrigger(control.key));
    }
    /// Consume the next suitable key/controller press into the active draft capture.
    /// Escape cancels; key repeats and unrelated events return false. This changes only
    /// the draft: a later Save action persists it. The UI must set a matching draft/capture.
    ///
    /// ```zig
    /// // Host routes owned-window/controller events before normal input:
    /// if (view.captureEvent(event)) return;
    /// ```
    pub fn captureEvent(self: *View, event: eggy.Event) bool {
        const target = self.capture orelse return false;
        if (event == .key_down and event.key_down.scancode == .escape) {
            self.capture = null;
            return true;
        }
        const draft = if (self.draft) |*draft| draft else return false;
        if (target == .controller) {
            if (event != .gamepad_button_down) return false;
            draft.controller.button = eggy.input_backend.buttonFromSdl(event.gamepad_button_down.button);
        } else {
            if (event != .key_down or event.key_down.repeat) return false;
            const key = event.key_down.scancode orelse return false;
            switch (target) {
                .key => draft.key = key,
                .negative => draft.key_axis.negative = key,
                .positive => draft.key_axis.positive = key,
                .left => draft.keys_2d.keys.left = key,
                .right => draft.keys_2d.keys.right = key,
                .up => draft.keys_2d.keys.up = key,
                .down => draft.keys_2d.keys.down = key,
                else => return false,
            }
        }
        self.capture = null;
        return true;
    }
};

fn defaultBinding(kind: t.Kind, index: usize) t.Binding {
    return switch (kind) {
        .button => switch (index) {
            1 => .{ .mouse = .left },
            2 => .{ .controller = .{ .button = .south } },
            else => .{ .key = .space },
        },
        .axis => switch (index) {
            1 => .{ .controller_axis = .{ .axis = .left_x } },
            2 => .{ .mouse_wheel = .{} },
            else => .{ .key_axis = .{ .negative = .a, .positive = .d } },
        },
        .vector => switch (index) {
            1 => .{ .controller_stick = .{} },
            2 => .{ .mouse_delta = .{} },
            else => .{ .keys_2d = .{} },
        },
    };
}

test "the mapping editor captures keys/controllers and lays out a scrollable vector editor" {
    const gpa = std.testing.allocator;
    const Player = t.Map(enum { move }, .{ .key = "player", .controls = &.{.{ .control = .move, .kind = .vector, .bindings = &.{.{ .keys_2d = .{} }} }} });
    var state = State.init(gpa);
    defer state.deinit();
    var input = eggy.Input{ .backend = state.interface() };
    try input.registerMap(Player, "game/player");
    var view = View{};
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    context.density = .compact;
    context.newFrame(.{ .x = 0, .y = 0, .w = 700, .h = 700 });
    context.beginScroll(&view.scroll, 676);
    try view.build(&context, &state);
    context.end();
    try std.testing.expect((try context.render()).len > 0);
    try std.testing.expect(view.scroll.content.y > view.scroll.viewport.h);
    view.capture = .left;
    try std.testing.expect(view.captureEvent(.{ .key_down = .{
        .common = undefined,
        .id = null,
        .scancode = .j,
        .key = null,
        .mod = .{},
        .raw = 0,
        .down = true,
        .repeat = false,
    } }));
    try std.testing.expectEqual(t.Key.j, view.draft.?.keys_2d.keys.left);
    try view.setDraft(.{ .controller = .{ .button = .south } });
    view.capture = .controller;
    try std.testing.expect(view.captureEvent(.{ .gamepad_button_down = .{ .common = undefined, .id = .{ .value = 1 }, .button = .north, .down = true } }));
    try std.testing.expectEqual(t.ControllerButton.north, view.draft.?.controller.button);
    try std.testing.expect(view.draft.?.controller.device == null);
}
