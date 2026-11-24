//! The Input Map editor's page for one control: its name, value type, trigger and bindings,
//! each change made to the document as it is made.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const sdl = eggy.sdl_adapter.sdl;
const page_style = @import("../page_style.zig");
const restyle = page_style.restyle;
const setting_rows = eggy.setting_rows;
const SettingRows = setting_rows.SettingRows;
const Document = @import("document.zig").Document;
const t = eggy.input;

/// Bindings a control shows fields for.
/// ponytail: fixed number fields per binding, so a hand-written file with more shows only these; keep fields per binding in a list if games need more.
const max_bindings = 16;
const field_width: f32 = 64;
const plus_glyph = "\u{f067}";
const remove_glyph = "\u{f00d}";
const gamepad_glyph = "\u{f11b}";

const kind_labels = displayNames(std.meta.fieldNames(t.Kind));
const trigger_labels = displayNames(std.meta.fieldNames(@typeInfo(t.Trigger).@"union".tag_type.?));
const mouse_labels = displayNames(std.meta.fieldNames(t.MouseButton));
const button_labels = displayNames(std.meta.fieldNames(t.ControllerButton));
const axis_labels = displayNames(std.meta.fieldNames(sdl.gamepad.Axis));
const stick_labels = displayNames(std.meta.fieldNames(@FieldType(@FieldType(t.Binding, "controller_stick"), "stick")));

/// Which key of a binding a capture fills, or a controller button.
pub const Part = enum { key, negative, positive, left, right, up, down, controller };

/// What the page did that the window must follow.
pub const Outcome = enum { none, removed };

/// The page's fields between frames; the document holds every value.
pub const ControlPage = struct {
    /// The control the fields were filled from; null fills them again next frame.
    filled: ?usize = null,
    name: ui.TextEdit(128) = .{},
    name_problem: ?[]const u8 = null,
    seconds: ui.TextEdit(32) = .{},
    /// Each binding's scale and dead zone fields, by `numberSlots`.
    numbers: [max_bindings][3]ui.TextEdit(32) = @splat(@splat(.{})),
    capture: ?struct { binding: usize, part: Part } = null,
    /// Why the last button or menu edit was refused.
    message: ?[]const u8 = null,

    /// Fill the fields from the document again next frame, as after an undo.
    pub fn forget(self: *ControlPage) void {
        self.filled = null;
        self.capture = null;
        self.message = null;
    }

    /// Whether a key or controller button is being captured, so Escape cancels it.
    pub fn capturing(self: *const ControlPage) bool {
        return self.capture != null;
    }

    /// Build the page for control `index` of `document` (which must exist), editing the document
    /// as fields change. UI allocation errors propagate; refused edits show on the page.
    ///
    /// ```zig
    /// if (try page.build(context, &document, 0) == .removed) selection = .map;
    /// ```
    pub fn build(self: *ControlPage, context: *ui.Context, document: *Document, index: usize) !Outcome {
        if (self.filled != index) try self.fill(document, index);
        const arena = context.builder().allocator;

        // A copy for the frame: an edit replaces what the document's control borrows.
        const control = document.controls()[index];
        const kind = control.kind;
        const trigger: t.Trigger = switch (control.trigger) {
            .chord => |name| .{ .chord = try arena.dupe(u8, name) },
            else => control.trigger,
        };
        const bindings = try arena.dupe(t.Binding, control.defaults);
        var chord_names: std.ArrayList([]const u8) = .empty;
        for (document.controls(), 0..) |other, i| if (i != index and other.kind == .button) try chord_names.append(arena, try arena.dupe(u8, other.name));

        if (self.message) |message| context.alert(message, "", true);

        // The control itself: name, value type and, for buttons, when it fires.
        var rows = SettingRows{};
        setting_rows.beginGroup(context);
        rows.begin(context, "Name", "");
        if (context.textInput("##control name", &self.name, "")) self.rename(document, index);
        restyle(context, .{ .width = SettingRows.control_width });
        if (self.name_problem) |problem| {
            context.muted(problem);
            page_style.smallText(context, 12);
        }
        _ = rows.endWithButton(context, "", null);
        rows.begin(context, "Value", if (bindings.len > 0) "Changing it removes its bindings." else "");
        var kind_index: usize = @backingInt(kind);
        if (context.select("##control value", &kind_labels, &kind_index)) {
            self.report(document.setKind(index, @fromBackingInt(@intCast(kind_index))));
            self.filled = null;
        }
        restyle(context, .{ .width = SettingRows.control_width });
        _ = rows.endWithButton(context, "", null);
        if (kind == .button) self.triggerRows(context, &rows, document, index, trigger, chord_names.items);
        setting_rows.endGroup(context);

        // Each binding in its own card, then one button per source to add another.
        for (bindings[0..@min(bindings.len, max_bindings)], 0..) |binding, b| self.bindingCard(context, document, index, bindings, b, binding);
        if (bindings.len == 0) context.muted("No bindings yet.");
        if (bindings.len < max_bindings) {
            context.begin(.row);
            for (sources(kind)) |source| {
                if (context.buttonVariant(try std.fmt.allocPrint(arena, plus_glyph ++ "  {s}", .{source.name}), .outline)) {
                    const grown = try arena.alloc(t.Binding, bindings.len + 1);
                    @memcpy(grown[0..bindings.len], bindings);
                    grown[bindings.len] = source.binding;
                    self.report(document.setBindings(index, grown));
                    self.filled = null;
                }
            }
            page_style.endRow(context);
        }

        // Removing it last, away from the edits.
        context.begin(.column);
        context.end();
        restyle(context, .{ .height = 8 });
        if (context.buttonVariant("Remove control", .destructive)) {
            document.removeControl(index) catch |err| {
                self.message = if (err == error.InvalidTrigger) "Another control chords with this one, so it stays." else describe(err);
                return .none;
            };
            self.forget();
            return .removed;
        }
        return .none;
    }

    /// The trigger menu and, under it, its seconds or the control it chords with.
    fn triggerRows(self: *ControlPage, context: *ui.Context, rows: *SettingRows, document: *Document, index: usize, trigger: t.Trigger, chord_names: []const []const u8) void {
        rows.begin(context, "Trigger", "");
        var trigger_index: usize = @backingInt(std.meta.activeTag(trigger));
        if (context.select("##trigger", &trigger_labels, &trigger_index)) {
            const seconds = self.parsedSeconds() orelse 0.25;
            const next: ?t.Trigger = switch (trigger_index) {
                1 => .{ .hold = seconds },
                2 => .{ .tap = seconds },
                3 => if (chord_names.len > 0) .{ .chord = chord_names[0] } else null,
                else => .immediate,
            };
            if (next) |rule| self.report(document.setTrigger(index, rule)) else self.message = "A chord needs another button control.";
            self.filled = null;
        }
        restyle(context, .{ .width = SettingRows.control_width });
        _ = rows.endWithButton(context, "", null);
        switch (trigger) {
            .hold, .tap => {
                rows.begin(context, "Seconds", "");
                // In a row, like the binding number fields, so it keeps its width.
                context.begin(.row);
                if (context.textInput("##trigger seconds", &self.seconds, "")) if (self.parsedSeconds()) |seconds| {
                    const rule: t.Trigger = if (trigger == .hold) .{ .hold = seconds } else .{ .tap = seconds };
                    document.setTrigger(index, rule) catch {};
                };
                restyle(context, .{ .width = field_width });
                page_style.endRow(context);
                if (self.parsedSeconds() == null) {
                    context.muted("0 or more.");
                    page_style.smallText(context, 12);
                }
                _ = rows.endWithButton(context, "", null);
            },
            .chord => |name| {
                rows.begin(context, "Chord with", "");
                var chord_index: usize = 0;
                for (chord_names, 0..) |candidate, i| if (std.mem.eql(u8, candidate, name)) {
                    chord_index = i;
                };
                if (context.select("##chord with", chord_names, &chord_index)) self.report(document.setTrigger(index, .{ .chord = chord_names[chord_index] }));
                restyle(context, .{ .width = SettingRows.control_width });
                _ = rows.endWithButton(context, "", null);
            },
            .immediate => {},
        }
    }

    fn parsedSeconds(self: *const ControlPage) ?f32 {
        const seconds = std.fmt.parseFloat(f32, self.seconds.text()) catch return null;
        return if (std.math.isFinite(seconds) and seconds >= 0) seconds else null;
    }

    /// Binding `b`: its source and main field with a remove button, then a row per setting.
    fn bindingCard(self: *ControlPage, context: *ui.Context, document: *Document, index: usize, bindings: []const t.Binding, b: usize, binding: t.Binding) void {
        const arena = context.builder().allocator;
        var rows = SettingRows{};
        setting_rows.beginGroup(context);
        const capturing_here = if (self.capture) |capture| capture.binding == b else false;
        rows.begin(context, sourceName(binding), if (capturing_here) "Escape cancels." else "");
        var next = binding;
        switch (binding) {
            .key => |key| self.keyButton(context, b, .key, key, SettingRows.control_width),
            .mouse => |button| {
                var selected: usize = @backingInt(button);
                if (context.select("##mouse button", &mouse_labels, &selected)) next.mouse = @fromBackingInt(@intCast(selected));
                restyle(context, .{ .width = SettingRows.control_width });
            },
            .controller => |controller| {
                context.begin(.row);
                var selected: usize = @backingInt(controller.button);
                if (context.select("##controller button", &button_labels, &selected)) next.controller.button = @fromBackingInt(@intCast(selected));
                restyle(context, .{ .grow = 1 });
                const lit = capturing_here and self.capture.?.part == .controller;
                if (page_style.iconButton(context, gamepad_glyph, "Capture a controller button", lit)) self.capture = .{ .binding = b, .part = .controller };
                page_style.endRow(context);
                restyle(context, .{ .width = SettingRows.control_width });
            },
            .controller_axis => |axis| {
                var selected: usize = @intCast(@backingInt(axis.axis));
                if (context.select("##controller axis", &axis_labels, &selected)) next.controller_axis.axis = @fromBackingInt(@intCast(selected));
                restyle(context, .{ .width = SettingRows.control_width });
            },
            .controller_stick => |stick| {
                var selected: usize = @backingInt(stick.stick);
                if (context.select("##stick", &stick_labels, &selected)) next.controller_stick.stick = @fromBackingInt(@intCast(selected));
                restyle(context, .{ .width = SettingRows.control_width });
            },
            .key_axis, .keys_2d, .mouse_delta, .mouse_wheel => {},
        }
        const remove = rows.endWithButton(context, "", .{ .glyph = remove_glyph, .label = "Remove binding", .id = std.fmt.allocPrint(arena, "remove binding {d}", .{b}) catch "remove binding" });

        // The binding's keys, then its numbers.
        var numbers_changed = false;
        switch (binding) {
            .key_axis => |axis| {
                rows.begin(context, "Keys", "");
                context.begin(.row);
                context.muted("-");
                self.keyButton(context, b, .negative, axis.negative, null);
                context.muted("+");
                self.keyButton(context, b, .positive, axis.positive, null);
                page_style.endRow(context);
                _ = rows.endWithButton(context, "", null);
                numbers_changed = self.numberRow(context, &rows, "Scale", b, &.{0}, .scale);
            },
            .keys_2d => |keys| {
                rows.begin(context, "Keys", "");
                self.keyCross(context, b, keys.keys);
                _ = rows.endWithButton(context, "", null);
                rows.begin(context, "Normalize diagonals", "");
                _ = context.toggle("##normalize diagonals", &next.keys_2d.normalize);
                _ = rows.endWithButton(context, "", null);
                numbers_changed = self.numberRow(context, &rows, "Scale", b, &.{ 0, 1 }, .scale);
            },
            .controller_axis => {
                numbers_changed = self.numberRow(context, &rows, "Scale", b, &.{0}, .scale);
                numbers_changed = self.numberRow(context, &rows, "Dead zone", b, &.{1}, .dead_zone) or numbers_changed;
            },
            .controller_stick => {
                numbers_changed = self.numberRow(context, &rows, "Scale", b, &.{ 0, 1 }, .scale);
                numbers_changed = self.numberRow(context, &rows, "Dead zone", b, &.{2}, .dead_zone) or numbers_changed;
            },
            .mouse_delta => numbers_changed = self.numberRow(context, &rows, "Scale", b, &.{ 0, 1 }, .scale),
            .mouse_wheel => numbers_changed = self.numberRow(context, &rows, "Scale", b, &.{0}, .scale),
            .key, .mouse, .controller => {},
        }
        setting_rows.endGroup(context);

        if (remove) {
            var kept: std.ArrayList(t.Binding) = .empty;
            for (bindings, 0..) |kept_binding, i| if (i != b) kept.append(arena, kept_binding) catch return;
            self.report(document.setBindings(index, kept.items));
            self.filled = null;
            return;
        }
        // Typed numbers apply once every field of the binding reads; until then the row says why.
        if (numbers_changed) {
            next = self.withNumbers(next, b) orelse return;
            document.setBindings(index, replaced(arena, bindings, b, next) orelse return) catch {};
            return;
        }
        if (!std.meta.eql(next, binding)) self.report(document.setBindings(index, replaced(arena, bindings, b, next) orelse return));
    }

    const NumberMeaning = enum { scale, dead_zone };

    /// A row of number fields `slots` of binding `b`, an X and Y when two. Returns whether one
    /// changed. A field that can't be used says so under the row.
    fn numberRow(self: *ControlPage, context: *ui.Context, rows: *SettingRows, title: []const u8, b: usize, slots: []const usize, meaning: NumberMeaning) bool {
        rows.begin(context, title, "");
        context.begin(.row);
        var changed = false;
        var usable = true;
        for (slots, 0..) |slot, i| {
            if (slots.len == 2) context.muted(if (i == 0) "X" else "Y");
            if (context.textInput("##number", &self.numbers[b][slot], "")) changed = true;
            restyle(context, .{ .width = field_width });
            usable = usable and parseNumber(self.numbers[b][slot].text(), meaning) != null;
        }
        page_style.endRow(context);
        _ = rows.endWithButton(context, if (usable) "" else switch (meaning) {
            .scale => "Not a number.",
            .dead_zone => "0 to under 1.",
        }, null);
        return changed;
    }

    /// `binding` with binding `b`'s number fields read into it, or null when one can't be used.
    fn withNumbers(self: *const ControlPage, binding: t.Binding, b: usize) ?t.Binding {
        const fields = &self.numbers[b];
        var next = binding;
        switch (next) {
            .key, .mouse, .controller => {},
            .key_axis => |*value| value.scale = parseNumber(fields[0].text(), .scale) orelse return null,
            .keys_2d => |*value| value.scale = .{ parseNumber(fields[0].text(), .scale) orelse return null, parseNumber(fields[1].text(), .scale) orelse return null },
            .controller_axis => |*value| {
                value.scale = parseNumber(fields[0].text(), .scale) orelse return null;
                value.dead_zone = parseNumber(fields[1].text(), .dead_zone) orelse return null;
            },
            .controller_stick => |*value| {
                value.scale = .{ parseNumber(fields[0].text(), .scale) orelse return null, parseNumber(fields[1].text(), .scale) orelse return null };
                value.dead_zone = parseNumber(fields[2].text(), .dead_zone) orelse return null;
            },
            .mouse_delta => |*value| value.scale = .{ parseNumber(fields[0].text(), .scale) orelse return null, parseNumber(fields[1].text(), .scale) orelse return null },
            .mouse_wheel => |*value| value.scale = parseNumber(fields[0].text(), .scale) orelse return null,
        }
        return next;
    }

    /// A key binding's key as a button; pressed, it waits for the next key.
    fn keyButton(self: *ControlPage, context: *ui.Context, b: usize, part: Part, key: t.Key, width: ?f32) void {
        const arena = context.builder().allocator;
        const waiting = if (self.capture) |capture| capture.binding == b and capture.part == part else false;
        const text = if (waiting) "Press a key\u{2026}" else keyLabel(arena, key);
        const label = std.fmt.allocPrint(arena, "{s}##{t}", .{ text, part }) catch return;
        if (context.buttonVariant(label, if (waiting) .default else .outline)) self.capture = .{ .binding = b, .part = part };
        if (width) |value| restyle(context, .{ .width = value });
        if (part != .key) context.tooltip(switch (part) {
            .negative => "Negative key",
            .positive => "Positive key",
            .left => "Left key",
            .right => "Right key",
            .up => "Up key",
            .down => "Down key",
            .key, .controller => "",
        });
    }

    /// Four keys laid out as on a keyboard: up above left, down and right.
    fn keyCross(self: *ControlPage, context: *ui.Context, b: usize, keys: t.DirectionKeys) void {
        context.beginGrid(3);
        context.element(context.builder().node(0, .{}, .none, &.{}) catch return);
        self.keyButton(context, b, .up, keys.up, null);
        context.element(context.builder().node(0, .{}, .none, &.{}) catch return);
        self.keyButton(context, b, .left, keys.left, null);
        self.keyButton(context, b, .down, keys.down, null);
        self.keyButton(context, b, .right, keys.right, null);
        context.end();
        restyle(context, .{ .gap = 4 });
    }

    /// Put the next key or controller button pressed into the binding being captured, in
    /// control `index` of `document`. Escape cancels; other events return false.
    ///
    /// ```zig
    /// if (page.captureEvent(event, &document, index)) return true;
    /// ```
    pub fn captureEvent(self: *ControlPage, event: eggy.Event, document: *Document, index: usize) bool {
        const target = self.capture orelse return false;
        if (event == .key_down and event.key_down.scancode == .escape) {
            self.capture = null;
            return true;
        }
        const controls = document.controls();
        if (index >= controls.len or target.binding >= controls[index].defaults.len) {
            self.capture = null;
            return false;
        }
        const bindings = controls[index].defaults;
        var next = bindings[target.binding];
        if (target.part == .controller) {
            if (event != .gamepad_button_down) return false;
            next.controller.button = eggy.input_backend.buttonFromSdl(event.gamepad_button_down.button);
        } else {
            if (event != .key_down or event.key_down.repeat) return false;
            const key = event.key_down.scancode orelse return false;
            switch (target.part) {
                .key => next.key = key,
                .negative => next.key_axis.negative = key,
                .positive => next.key_axis.positive = key,
                .left => next.keys_2d.keys.left = key,
                .right => next.keys_2d.keys.right = key,
                .up => next.keys_2d.keys.up = key,
                .down => next.keys_2d.keys.down = key,
                .controller => unreachable,
            }
        }
        self.capture = null;
        const copy = document.gpa.dupe(t.Binding, bindings) catch |err| {
            self.message = describe(err);
            return true;
        };
        defer document.gpa.free(copy);
        copy[target.binding] = next;
        self.report(document.setBindings(index, copy));
        return true;
    }

    fn rename(self: *ControlPage, document: *Document, index: usize) void {
        const name = self.name.text();
        if (name.len == 0) {
            self.name_problem = "Can't be empty.";
            return;
        }
        document.renameControl(index, name) catch |err| {
            self.name_problem = if (err == error.DuplicateControls) "Another control has this name." else describe(err);
            return;
        };
        self.name_problem = null;
    }

    /// Show why an edit from a button or menu was refused, or clear the last refusal.
    fn report(self: *ControlPage, result: anyerror!void) void {
        result catch |err| {
            self.message = describe(err);
            return;
        };
        self.message = null;
    }

    fn fill(self: *ControlPage, document: *const Document, index: usize) !void {
        const control = document.controls()[index];
        try self.name.set(control.name);
        var buffer: [32]u8 = undefined;
        try self.seconds.set(try std.fmt.bufPrint(&buffer, "{d}", .{switch (control.trigger) {
            .hold, .tap => |seconds| seconds,
            else => @as(f32, 0.25),
        }}));
        for (control.defaults[0..@min(control.defaults.len, max_bindings)], 0..) |binding, b| try self.fillNumbers(b, binding);
        self.filled = index;
        self.name_problem = null;
    }

    fn fillNumbers(self: *ControlPage, b: usize, binding: t.Binding) !void {
        const values: []const f32 = switch (binding) {
            .key, .mouse, .controller => &.{},
            .key_axis => |value| &.{value.scale},
            .keys_2d => |value| &value.scale,
            .controller_axis => |value| &.{ value.scale, value.dead_zone },
            .controller_stick => |value| &.{ value.scale[0], value.scale[1], value.dead_zone },
            .mouse_delta => |value| &value.scale,
            .mouse_wheel => |value| &.{value.scale},
        };
        for (values, 0..) |value, slot| {
            var buffer: [32]u8 = undefined;
            try self.numbers[b][slot].set(try std.fmt.bufPrint(&buffer, "{d}", .{value}));
        }
    }
};

/// What can make a control's value: its name on the page and the binding it adds.
const Source = struct { name: []const u8, binding: t.Binding };

fn sources(kind: t.Kind) []const Source {
    return switch (kind) {
        .button => &.{
            .{ .name = "Keyboard key", .binding = .{ .key = .space } },
            .{ .name = "Mouse button", .binding = .{ .mouse = .left } },
            .{ .name = "Controller button", .binding = .{ .controller = .{ .button = .south } } },
        },
        .axis => &.{
            .{ .name = "Two keys", .binding = .{ .key_axis = .{ .negative = .a, .positive = .d } } },
            .{ .name = "Controller axis", .binding = .{ .controller_axis = .{ .axis = .left_x } } },
            .{ .name = "Mouse wheel", .binding = .{ .mouse_wheel = .{} } },
        },
        .vector => &.{
            .{ .name = "Four keys", .binding = .{ .keys_2d = .{} } },
            .{ .name = "Controller stick", .binding = .{ .controller_stick = .{} } },
            .{ .name = "Mouse movement", .binding = .{ .mouse_delta = .{} } },
        },
    };
}

fn sourceName(binding: t.Binding) []const u8 {
    return switch (binding) {
        .key => "Keyboard key",
        .mouse => "Mouse button",
        .controller => "Controller button",
        .key_axis => "Two keys",
        .controller_axis => "Controller axis",
        .mouse_wheel => "Mouse wheel",
        .keys_2d => "Four keys",
        .controller_stick => "Controller stick",
        .mouse_delta => "Mouse movement",
    };
}

fn parseNumber(text: []const u8, meaning: ControlPage.NumberMeaning) ?f32 {
    const value = std.fmt.parseFloat(f32, std.mem.trim(u8, text, " ")) catch return null;
    if (!std.math.isFinite(value)) return null;
    return switch (meaning) {
        .scale => value,
        .dead_zone => if (value >= 0 and value < 1) value else null,
    };
}

/// `bindings` with `b` set to `binding`, in `arena`.
fn replaced(arena: std.mem.Allocator, bindings: []const t.Binding, b: usize, binding: t.Binding) ?[]const t.Binding {
    const copy = arena.dupe(t.Binding, bindings) catch return null;
    copy[b] = binding;
    return copy;
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidTrigger => "A chord needs another button control, and chords can't go in a circle.",
        error.OutOfMemory => "Out of memory.",
        else => @errorName(err),
    };
}

/// A key's name for its button: "W", "Left shift".
fn keyLabel(arena: std.mem.Allocator, key: t.Key) []const u8 {
    const name = std.fmt.allocPrint(arena, "{t}", .{key}) catch return "?";
    if (name.len == 0) return name;
    for (name) |*c| if (c.* == '_') {
        c.* = ' ';
    };
    name[0] = std.ascii.toUpper(name[0]);
    return name;
}

/// Enum field names as labels: "left_shoulder" becomes "Left shoulder".
fn displayNames(comptime names: []const []const u8) [names.len][]const u8 {
    var labels: [names.len][]const u8 = undefined;
    inline for (names, &labels) |name, *label| {
        const shown = comptime blk: {
            var text: [name.len]u8 = name[0..name.len].*;
            for (&text) |*c| if (c.* == '_') {
                c.* = ' ';
            };
            text[0] = std.ascii.toUpper(text[0]);
            const final = text;
            break :blk final;
        };
        label.* = &shown;
    }
    return labels;
}

test "key names and enum labels read as words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("W", keyLabel(arena.allocator(), .w));
    try std.testing.expectEqualStrings("Left shift", keyLabel(arena.allocator(), .left_shift));
    try std.testing.expectEqualStrings("Button", kind_labels[0]);
    try std.testing.expectEqualStrings("Hold", trigger_labels[1]);
}

test "typed numbers apply only once every field of the binding reads" {
    var page = ControlPage{};
    try page.fillNumbers(0, .{ .controller_stick = .{} });
    try std.testing.expectEqual(@as(f32, 0.15), page.withNumbers(.{ .controller_stick = .{} }, 0).?.controller_stick.dead_zone);
    try page.numbers[0][2].set("1.5");
    try std.testing.expect(page.withNumbers(.{ .controller_stick = .{} }, 0) == null);
    try page.numbers[0][2].set("0.3");
    try page.numbers[0][1].set("-1");
    const stick = page.withNumbers(.{ .controller_stick = .{} }, 0).?.controller_stick;
    try std.testing.expectEqual(@as(f32, 0.3), stick.dead_zone);
    try std.testing.expectEqual(@as(f32, -1), stick.scale[1]);
}
