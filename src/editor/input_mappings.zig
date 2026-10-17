//! Developer input-map editing with captured keys and persistent modifiers/triggers.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const sdl = eggy.sdl_adapter.sdl;
const ToolWindow = @import("tool_window.zig").ToolWindow;
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

    pub fn build(self: *View, context: *ui.Context, state: *State) !void {
        const arena = context.builder().allocator;
        if (self.source == .registered) {
            context.heading(2, "Input mappings");
            context.muted("Code reads named controls. Project edits are baked into shipped games.");
            if (state.persistence == null) context.muted("No project is open: edits here are session-only.");
        } else context.muted("Apply binding/trigger edits below, then Save file to write the asset.");
        if (self.last_error) |err| context.label("Could not apply edit: {s}", .{@errorName(err)});
        if (self.capture != null) context.muted("Press the desired input. Escape cancels capture.");
        // Dropdown text remains in the previous-frame tree when a map is replaced.
        const map_labels = try arena.alloc([]const u8, state.owners.count());
        var maps = state.owners.valueIterator();
        for (map_labels) |*label| label.* = try arena.dupe(u8, maps.next().?.key);
        if (map_labels.len == 0) {
            context.muted("No maps registered. Declare input_maps on your game or plugin.");
            return;
        }
        if (self.source == .registered and context.select("Map", map_labels, &self.map_index)) {
            self.control_index = 0;
            self.binding_index = 0;
            self.loaded = null;
        }
        const first = self.selected(state) orelse return;
        const map_id = state.controls.values()[first].map_id;
        const map = state.owners.get(map_id).?;
        const defaults = state.overrides.maps.get(map.key) orelse map.defaults;
        if (self.loaded_map != map_id or self.map_revision != state.configuration_revision) {
            self.loaded_map = map_id;
            self.map_revision = state.configuration_revision;
            self.map_enabled = defaults.enabled;
            var buffer: [32]u8 = undefined;
            try self.priority.set(try std.fmt.bufPrint(&buffer, "{d}", .{defaults.priority}));
        }
        _ = context.checkbox("Enabled at startup", &self.map_enabled);
        _ = context.textInput("Map priority", &self.priority, "Higher maps own shared inputs");
        context.begin(.row);
        if (context.button(if (self.source == .asset) "Apply map settings" else "Save map defaults")) {
            const priority = std.fmt.parseInt(i32, self.priority.text(), 10) catch {
                self.last_error = error.InvalidPriority;
                context.end();
                return;
            };
            if (state.setMapDefaults(map_id, .{ .enabled = self.map_enabled, .priority = priority })) |_| {
                self.last_error = null;
            } else |err| self.last_error = err;
        }
        if (self.source == .registered and context.button("Reset map defaults")) {
            if (state.setMapDefaults(map_id, null)) |_| {
                self.last_error = null;
            } else |err| self.last_error = err;
        }
        context.end();
        context.muted("Runtime switching is temporary; these defaults ship with the game.");
        var labels: std.ArrayList([]const u8) = .empty;
        for (state.controls.values()) |control| if (control.map_id == map_id) try labels.append(arena, try arena.dupe(u8, control.name));
        if (context.select("Control", labels.items, &self.control_index)) {
            self.binding_index = 0;
            self.loaded = null;
        }
        const index = self.selected(state) orelse return;
        const control = state.controls.values()[index];
        const id = state.controls.keys()[index];
        const mappings = state.overrides.get(control.key) orelse control.defaults;
        if (self.loaded == null or !std.meta.eql(self.loaded.?, id) or self.loaded_revision != state.configuration_revision or self.loaded_binding != self.binding_index) {
            self.loaded = id;
            self.loaded_revision = state.configuration_revision;
            self.binding_index = if (mappings.len == 0) 0 else @min(self.binding_index, mappings.len - 1);
            self.loaded_binding = self.binding_index;
            self.is_new = false;
            self.draft = null;
            if (mappings.len != 0) try self.setDraft(mappings[self.binding_index]);
            const rule = state.overrides.getTrigger(control.key) orelse control.trigger;
            self.trigger_index = @intFromEnum(std.meta.activeTag(rule));
            var buffer: [64]u8 = undefined;
            try self.duration.set(try std.fmt.bufPrint(&buffer, "{d}", .{switch (rule) {
                .hold, .tap => |seconds| seconds,
                else => @as(f32, 0.25),
            }}));
            self.chord_index = 0;
            if (rule == .chord) for (labels.items, 0..) |label, i| if (std.mem.eql(u8, label, rule.chord)) {
                self.chord_index = i;
            };
        }
        context.label("Value: {t}", .{control.kind});
        const binding_labels = try arena.alloc([]const u8, mappings.len);
        for (mappings, binding_labels, 0..) |binding, *label, i| label.* = try std.fmt.allocPrint(arena, "{d}: {s}", .{ i + 1, @tagName(binding) });
        if (binding_labels.len != 0 and context.select("Binding", binding_labels, &self.binding_index)) {
            self.loaded = null;
            return;
        }
        const sources: []const []const u8 = switch (control.kind) {
            .button => &button_sources,
            .axis => &axis_sources,
            .vector => &vector_sources,
        };
        self.source_index = @min(self.source_index, sources.len - 1);
        _ = context.select("New binding source", sources, &self.source_index);
        if (context.button("Add binding")) {
            self.is_new = true;
            try self.setDraft(defaultBinding(control.kind, self.source_index));
        }
        if (self.draft) |*draft| {
            try self.editBinding(context, draft);
            if (context.button(if (self.source == .asset) "Apply binding" else "Save binding")) {
                if (self.saveBinding(state, id, mappings)) |_| {
                    self.last_error = null;
                    self.loaded = null;
                } else |err| self.last_error = err;
            }
            if (!self.is_new and context.button("Remove binding")) {
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
        }
        if (control.kind == .button) {
            _ = context.select("Trigger", &trigger_names, &self.trigger_index);
            if (self.trigger_index == 1 or self.trigger_index == 2) _ = context.textInput("Seconds", &self.duration, "Nonnegative counted input seconds");
            if (self.trigger_index == 3) _ = context.select("Chord control", labels.items, &self.chord_index);
            if (context.button(if (self.source == .asset) "Apply trigger" else "Save trigger")) {
                const rule: t.Trigger = switch (self.trigger_index) {
                    1 => .{ .hold = std.fmt.parseFloat(f32, self.duration.text()) catch {
                        self.last_error = error.InvalidTrigger;
                        return;
                    } },
                    2 => .{ .tap = std.fmt.parseFloat(f32, self.duration.text()) catch {
                        self.last_error = error.InvalidTrigger;
                        return;
                    } },
                    3 => .{ .chord = labels.items[@min(self.chord_index, labels.items.len - 1)] },
                    else => .immediate,
                };
                if (state.setMappings(id, mappings, rule)) |_| {
                    self.loaded = null;
                    self.last_error = null;
                } else |err| self.last_error = err;
            }
        }
        if (self.source == .registered and context.button("Reset control to map defaults")) {
            if (state.resetMappings(id)) |_| {
                self.loaded = null;
                self.last_error = null;
            } else |err| self.last_error = err;
        }
    }
    fn captureKey(self: *View, context: *ui.Context, label: []const u8, key: t.Key, target: Capture) void {
        const text = std.fmt.allocPrint(context.builder().allocator, "{s}: {t} (capture)", .{ label, key }) catch |err| {
            context.err = err;
            return;
        };
        if (context.button(text)) self.capture = target;
    }
    fn editBinding(self: *View, context: *ui.Context, draft: *t.Binding) !void {
        switch (draft.*) {
            .key => |key| self.captureKey(context, "Key", key, .key),
            .mouse => |*mouse| {
                var selected_index: usize = @intFromEnum(mouse.*);
                if (context.select("Mouse button", mouse_names, &selected_index)) mouse.* = @enumFromInt(selected_index);
            },
            .controller => |*controller| {
                var selected_index: usize = @intFromEnum(controller.button);
                if (context.select("Controller button", button_names, &selected_index)) controller.button = @enumFromInt(selected_index);
                if (context.button("Capture controller button")) self.capture = .controller;
            },
            .key_axis => |axis| {
                self.captureKey(context, "Negative key", axis.negative, .negative);
                self.captureKey(context, "Positive key", axis.positive, .positive);
                _ = context.textInput("Axis scale", &self.numbers[0], "1 or -1");
            },
            .keys_2d => |*keys| {
                self.captureKey(context, "Left key", keys.keys.left, .left);
                self.captureKey(context, "Right key", keys.keys.right, .right);
                self.captureKey(context, "Up key", keys.keys.up, .up);
                self.captureKey(context, "Down key", keys.keys.down, .down);
                _ = context.checkbox("Normalize diagonal movement", &keys.normalize);
                self.vectorNumbers(context);
            },
            .controller_axis => |*axis| {
                var selected_index: usize = @intCast(@intFromEnum(axis.axis));
                if (context.select("Controller axis", axis_names, &selected_index)) axis.axis = @enumFromInt(selected_index);
                _ = context.textInput("Axis scale", &self.numbers[0], "1 or -1");
                _ = context.textInput("Dead zone", &self.numbers[1], "0 to less than 1");
            },
            .controller_stick => |*stick| {
                var selected_index: usize = @intFromEnum(stick.stick);
                if (context.select("Stick", &stick_names, &selected_index)) stick.stick = @enumFromInt(selected_index);
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
        _ = context.textInput("X scale", &self.numbers[0], "1");
        _ = context.textInput("Y scale", &self.numbers[1], "1 or -1");
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

pub const InputMappingsWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    view: View = .{},
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font) !*InputMappingsWindow {
        const self = try gpa.create(InputMappingsWindow);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "Input Mappings", .{ 700, 700 }, .{ .resizable = true }) };
        return self;
    }
    pub fn close(self: *InputMappingsWindow, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.gpa.destroy(self);
    }
    pub fn handle(self: *InputMappingsWindow, event: eggy.Event) bool {
        if (self.view.capture != null and (self.window.owns(event) or eggy.game_ui.isControllerInput(event))) {
            if (self.view.captureEvent(event)) return true;
        }
        if (!self.window.owns(event)) return false;
        self.window.handle(event);
        return true;
    }
    pub fn closeRequested(self: *InputMappingsWindow, event: eggy.Event) bool {
        if (!self.window.owns(event)) return false;
        return event == .window_close_requested or (self.view.capture == null and event == .key_down and event.key_down.scancode == .escape);
    }
    pub fn update(self: *InputMappingsWindow, graphics: *eggy.Graphics, style: *const ui.Context, state: *State) !void {
        const Page = struct {
            view: *View,
            state: *State,
            pub fn build(page: *@This(), context: *ui.Context) void {
                context.beginScroll(&page.view.scroll, @max(1, context.viewport.h - 24));
                defer context.end();
                page.view.build(context, page.state) catch |err| {
                    page.view.last_error = err;
                    context.label("Input editor: {s}", .{@errorName(err)});
                };
            }
        };
        var page = Page{ .view = &self.view, .state = state };
        try self.window.present(graphics, style, &page);
    }
};

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
