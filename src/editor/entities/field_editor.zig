//! The Inspector's control for each part of a component field's value, by what the part is
//! (`eggy.components.PartKind`): numbers are boxes to drag sideways or click and type into,
//! vectors a box per axis tagged X, Y, Z and W in red, green, blue and purple, colours a swatch
//! (which opens weeoui's colour picker, `color_popup.zig`) and R, G, B and A boxes, turns
//! (quaternions, and rotations kept as turns about x, y and z) a dropdown of formats to show them
//! in (Euler degrees or radians, quaternion, axis and angle), enums and unions dropdowns, structs,
//! arrays and optionals rows of their parts, and references slots to drop an entity or a file
//! on. A union with a reference variant (a `Mesh`'s shape takes a model) takes a drop on its
//! dropdown too. A change comes back as the field's whole new ZON, the rest of it kept as it was.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const Part = eggy.components.Part;
const page_style = @import("../page_style.zig");
const restyle = page_style.restyle;
const Dragged = @import("../dragged.zig").Dragged;
const ProjectAssets = @import("../assets/project_assets.zig").ProjectAssets;
const field_value = @import("field_value.zig");
const ColorPopup = @import("color_popup.zig").ColorPopup;
const Value = field_value.Value;
const Node = field_value.Node;

const NumberEdit = ui.TextEdit(64);
/// How far nested rows sit in from the row holding them.
const indent: f32 = 12;
/// A dropdown's text size, and the room its padding and chevron take beside the text.
const select_text_size: f32 = 14;
const select_chrome: f32 = 48;
/// How far the pointer must move before a press on a number box drags it rather than types.
const drag_threshold: f32 = 2;

/// An axis's or channel's letter and colour, on the left of its number box.
const Tag = struct { letter: []const u8, color: ui.Color };
const axis_tags = [_]Tag{
    .{ .letter = "X", .color = .{ 0.86, 0.27, 0.27 } },
    .{ .letter = "Y", .color = .{ 0.38, 0.72, 0.25 } },
    .{ .letter = "Z", .color = .{ 0.27, 0.49, 0.9 } },
    .{ .letter = "W", .color = .{ 0.63, 0.45, 0.86 } },
};
const channel_tags = [_]Tag{
    .{ .letter = "R", .color = .{ 0.86, 0.27, 0.27 } },
    .{ .letter = "G", .color = .{ 0.38, 0.72, 0.25 } },
    .{ .letter = "B", .color = .{ 0.27, 0.49, 0.9 } },
    .{ .letter = "A", .color = .{ 0.55, 0.55, 0.55 } },
};

/// How the Inspector shows something that turns.
const RotationFormat = enum(u8) {
    euler_deg,
    euler_rad,
    quaternion,
    axis_angle,

    fn label(self: RotationFormat) []const u8 {
        return switch (self) {
            .euler_deg => "Euler (degrees)",
            .euler_rad => "Euler (radians)",
            .quaternion => "Quaternion",
            .axis_angle => "Axis and angle",
        };
    }

    /// How many numbers it shows.
    fn len(self: RotationFormat) usize {
        return if (self == .euler_deg or self == .euler_rad) 3 else 4;
    }

    /// `turn`'s numbers in this format.
    fn show(self: RotationFormat, turn: Turn) [4]f64 {
        return switch (self) {
            .euler_deg => blk: {
                const turns = turn.toEulerDeg();
                break :blk .{ turns[0], turns[1], turns[2], 0 };
            },
            .euler_rad => blk: {
                const turns = turn.toEulerDeg();
                break :blk .{ turns[0] * std.math.rad_per_deg, turns[1] * std.math.rad_per_deg, turns[2] * std.math.rad_per_deg, 0 };
            },
            .quaternion => turn.toQuaternion(),
            .axis_angle => axisAngleOf(turn.toQuaternion()),
        };
    }

    /// The turn `numbers` (in this format) say. Euler turns stay euler, so editing one doesn't
    /// wobble the others through a quaternion.
    fn read(self: RotationFormat, numbers: [4]f64) Turn {
        return switch (self) {
            .euler_deg => .{ .euler_deg = numbers[0..3].* },
            .euler_rad => .{ .euler_deg = .{ numbers[0] * std.math.deg_per_rad, numbers[1] * std.math.deg_per_rad, numbers[2] * std.math.deg_per_rad } },
            .quaternion => .{ .quaternion = normalized(numbers) },
            .axis_angle => .{ .quaternion = quaternionOfAxisAngle(numbers) },
        };
    }
};
const rotation_formats = std.enums.values(RotationFormat);
/// An axis and angle's angle, after the axis's X, Y and Z.
const angle_tag = Tag{ .letter = "°", .color = .{ 0.55, 0.55, 0.55 } };

/// A turn, as a format gives it.
const Turn = union(enum) {
    /// About x, then y, then z, in degrees.
    euler_deg: [3]f64,
    /// x, y, z, w.
    quaternion: [4]f64,

    fn toQuaternion(self: Turn) [4]f64 {
        return switch (self) {
            .euler_deg => |turns| quaternionOf(turns),
            .quaternion => |q| q,
        };
    }

    fn toEulerDeg(self: Turn) [3]f64 {
        return switch (self) {
            .euler_deg => |turns| turns,
            .quaternion => |q| eulerOf(q),
        };
    }
};

/// What a drop on a slot sets: the field, and its whole new text around what was dropped.
pub const Slot = struct {
    id: u32,
    component: usize,
    field: usize,
    /// The reference part that takes the drop.
    target: Part,
    /// The field's text before and after the dropped value; `variant` wraps it in a union's
    /// variant (`.{ .model = ... }`) when not empty.
    before: []const u8,
    after: []const u8,
    variant: []const u8 = "",

    /// The field's new text with `dragged` dropped on it, in `arena`.
    /// Editor-only: check `dragged.fits(self.target)` first. Serializes the reference and
    /// preserves the surrounding field text; formatting/allocation errors propagate.
    ///
    /// ```zig
    /// // Given a drop Slot, Dragged value and arena allocator:
    /// if (dragged.fits(slot.target)) {
    ///     const zon = try slot.text(arena, dragged);
    ///     _ = zon; // Write the field through the loaded game's access API.
    /// }
    /// ```
    pub fn text(self: Slot, arena: std.mem.Allocator, dragged: Dragged) ![]const u8 {
        var buffer: [512]u8 = undefined;
        const dropped = try dragged.zon(&buffer);
        if (self.variant.len == 0) return std.mem.concat(arena, u8, &.{ self.before, dropped, self.after });
        return std.mem.concat(arena, u8, &.{ self.before, ".{ .", self.variant, " = ", dropped, " }", self.after });
    }
};

pub const FieldEditor = struct {
    gpa: std.mem.Allocator,
    /// The focused number box's key and text, kept while typing.
    typing: ?struct { key: u64, edit: NumberEdit } = null,
    /// The number box being dragged: its key, where the pointer and the number were when pressed,
    /// and whether it has moved enough to count as a drag.
    scrub: ?struct { key: u64, from_x: f32, from: f64, moved: bool = false } = null,
    /// The colour picker open, if one is.
    color: ?ColorPopup = null,
    /// The format each turning field is shown in, by its key, once one is picked.
    rotation_formats: std.AutoHashMapUnmanaged(u64, RotationFormat) = .empty,
    /// The drop targets built last frame, with what each sets; in `slot_arena`.
    slots: std.ArrayList(Slot) = .empty,
    slot_arena: std.heap.ArenaAllocator,

    /// Create editor field interaction state; later allocations use `gpa`. Pair with `deinit`.
    ///
    /// ```zig
    /// var fields = FieldEditor.init(gpa); // Existing allocator.
    /// defer fields.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator) FieldEditor {
        return .{ .gpa = gpa, .slot_arena = .init(gpa) };
    }

    /// Release editor-owned format/slot storage and invalidate every borrowed Slot string.
    /// Call once after UI builds and drop handling have stopped.
    ///
    /// ```zig
    /// var fields = FieldEditor.init(gpa); // Existing allocator.
    /// defer fields.deinit();
    /// ```
    pub fn deinit(self: *FieldEditor) void {
        self.rotation_formats.deinit(self.gpa);
        self.slots.deinit(self.gpa);
        self.slot_arena.deinit();
    }

    /// Forget last frame's slots, before building the next.
    /// Editor-only: invalidates prior Slot text; handle drops against the old layout first.
    ///
    /// ```zig
    /// fields.newFrame(); // Existing FieldEditor, before this frame's fieldRows calls.
    /// ```
    pub fn newFrame(self: *FieldEditor) void {
        self.slots.clearRetainingCapacity();
        _ = self.slot_arena.reset(.retain_capacity);
    }

    /// Forget what is being typed or dragged: another entity is shown.
    /// Editor-only: also closes a color picker; preserves display formats and slot storage.
    ///
    /// ```zig
    /// fields.reset(); // Existing FieldEditor after changing the selected entity.
    /// ```
    pub fn reset(self: *FieldEditor) void {
        self.typing = null;
        self.scrub = null;
        self.color = null;
    }

    /// Whether a number box is being dragged: its changes aren't an undo step until let go.
    /// Editor-only: also true while a color popup is open, including a press before movement.
    ///
    /// ```zig
    /// const coalesce_edits = fields.scrubbing(); // Existing FieldEditor.
    /// ```
    pub fn scrubbing(self: *const FieldEditor) bool {
        return self.scrub != null or self.color != null;
    }

    /// The slot under `at` in last frame's layout.
    /// Editor-only: `at` uses UI coordinates; call before `newFrame` clears old slots.
    /// The returned value's text borrows the slot arena until the next `newFrame`.
    ///
    /// ```zig
    /// // Given fields, last-layout context and a UI-space drop position:
    /// const slot = fields.slotAt(context, at);
    /// ```
    pub fn slotAt(self: *const FieldEditor, context: *const ui.Context, at: ui.Vec2) ?Slot {
        for (self.slots.items) |slot| {
            const bounds = context.last_bounds.get(slot.id) orelse continue;
            if (bounds.rect.contains(at.x, at.y)) return slot;
        }
        return null;
    }

    /// Field `field` of component `component`: a row with its `label` and the control for its
    /// type `parts` (`parts[0]`) showing `text` (its value as ZON), then rows for what it holds.
    /// `shown` names what a reference points at. Returns the field's new ZON when changed.
    /// Editor-only: call after `newFrame`, during UI construction. Indices identify the game
    /// component/field, `parts` must be a nonempty valid tree, and `control_width` is UI points.
    /// New text lives in the UI frame arena; null also covers unchanged/unparseable values
    /// or an allocation failure. The host must apply successful changes through the game ABI.
    ///
    /// ```zig
    /// // Given fields, context, a component field's parts and current ZON:
    /// const changed = fields.fieldRows(context, .{
    ///     .component = 0, .field = 0, .label = "Position", .parts = parts,
    ///     .text = zon, .shown = null, .control_width = 160, .dragging = null,
    /// });
    /// ```
    pub fn fieldRows(self: *FieldEditor, context: *ui.Context, request: struct {
        component: usize,
        field: usize,
        label: []const u8,
        parts: []const Part,
        text: []const u8,
        shown: ?[]const u8,
        control_width: f32,
        dragging: ?Dragged,
        /// Names the assets a nested reference holds; their keys are shown as they are without.
        assets: ?*ProjectAssets = null,
    }) ?[]const u8 {
        const arena = context.builder().allocator;
        const value = Value.parse(arena, request.text) orelse {
            // Not ZON (cut off, or unreadable): shown as it is.
            labelledRow(context, request.label, 0);
            context.muted(request.text);
            page_style.noteText(context);
            endRow(context, request.control_width);
            return null;
        };
        var draw = Draw{
            .editor = self,
            .context = context,
            .parts = request.parts,
            .value = &value,
            .component = request.component,
            .field = request.field,
            .control_width = request.control_width,
            .dragging = request.dragging,
            .shown = request.shown orelse "",
            .assets = request.assets,
        };
        const seed = std.hash.Wyhash.hash(request.component, std.mem.asBytes(&request.field));
        draw.part(0, .root, request.label, seed, 0);
        return draw.changed;
    }
};

/// One field's drawing, part by part.
const Draw = struct {
    editor: *FieldEditor,
    context: *ui.Context,
    parts: []const Part,
    value: *const Value,
    component: usize,
    field: usize,
    control_width: f32,
    dragging: ?Dragged,
    /// What the field's reference points at, as people read it (top-level references only).
    shown: []const u8,
    assets: ?*ProjectAssets,
    /// The field's new text, once a control changed it.
    changed: ?[]const u8 = null,

    fn scratch(self: *Draw) std.mem.Allocator {
        return self.context.builder().allocator;
    }

    /// Set the field to its text with `node` replaced by `text`.
    fn set(self: *Draw, node: Node, text: []const u8) void {
        self.changed = self.value.replace(self.scratch(), node, text) catch return;
    }

    /// Part `index`, its value at `node`: a row named `label` with its control, then rows for
    /// what it holds, `depth` in. `key` names it among every part shown.
    fn part(self: *Draw, index: usize, node: Node, label: []const u8, key: u64, depth: u32) void {
        const context = self.context;
        const this = self.parts[index];
        const width = self.control_width;
        labelledRow(context, label, depth);
        switch (this.kind) {
            .bool => {
                var on = std.mem.eql(u8, self.value.text(node), "true");
                if (context.toggle(hiddenLabel(self.scratch(), key), &on)) self.set(node, if (on) "true" else "false");
            },
            .int, .float => {
                const number = self.value.number(node) orelse 0;
                if (self.numberBox(key, number, this, null, null, width)) |new| self.set(node, field_value.numberText(self.scratch(), new, this));
            },
            .@"enum" => {
                const current = switch (self.value.get(node)) {
                    .enum_literal => |tag| tag.get(&self.value.zoir),
                    else => "",
                };
                var names: [64][]const u8 = undefined;
                const count = @min(this.option_count, names.len);
                for (names[0..count], this.optionNames()[0..count]) |*name, option| name.* = std.mem.span(option);
                if (self.dropdown(key, names[0..count], current)) |picked| self.set(node, std.fmt.allocPrint(self.scratch(), ".{s}", .{names[picked]}) catch return);
            },
            .vector, .color => self.numbers(node, this, key, width),
            .quaternion, .euler => self.rotation(node, this, key, width),
            .entity, .asset => self.slot(key, node, this, if (depth == 0) self.shown else self.referenceText(node), width, ""),
            .@"union" => self.unionControl(index, node, key, width),
            .optional => {
                const set_now = self.value.get(node) != .null;
                var on = set_now;
                if (context.toggle(hiddenLabel(self.scratch(), key), &on) and on != set_now) {
                    self.set(node, if (on) field_value.defaultText(self.scratch(), self.parts, this.first) catch return else "null");
                }
            },
            .@"struct", .array => {},
            .none => context.muted("-"),
            .other => {
                context.muted(self.value.text(node));
                page_style.noteText(context);
                if (context.last_added) |text| text.paint_kind.text.wrap = true;
            },
        }
        endRow(context, width);

        // What it holds, a row each, further in.
        switch (this.kind) {
            .@"struct" => for (this.children(self.parts), 0..) |inner, i| {
                const name = std.mem.span(inner.name);
                const inner_node = self.value.field(node, name) orelse continue;
                self.part(this.first + i, inner_node, displayName(self.scratch(), name), childKey(key, i), depth + 1);
            },
            .array => for (0..this.len) |i| {
                const inner_node = self.value.child(node, i) orelse break;
                self.part(this.first, inner_node, std.fmt.allocPrint(self.scratch(), "Element {d}", .{i}) catch "", childKey(key, i), depth + 1);
            },
            .optional => if (self.value.get(node) != .null) self.part(this.first, node, "Value", childKey(key, 0), depth + 1),
            .@"union" => self.unionPayload(index, node, key, depth),
            else => {},
        }
    }

    /// A union: a dropdown of its variants (taking a drop when a variant is a reference), then
    /// the chosen variant's own rows.
    fn unionControl(self: *Draw, index: usize, node: Node, key: u64, width: f32) void {
        const this = self.parts[index];
        const variants = this.children(self.parts);
        const current = self.value.variant(node) orelse return self.context.muted(self.value.text(node));

        // While something that a reference variant takes is dragged, the dropdown is a slot for it.
        if (self.dragging) |dragged| for (variants) |variant| {
            if ((variant.kind == .entity or variant.kind == .asset) and dragged.fits(variant)) {
                return self.slot(key, node, variant, "", width, std.mem.span(variant.name));
            }
        };

        var names: [64][]const u8 = undefined;
        const count = @min(variants.len, names.len);
        for (names[0..count], variants[0..count]) |*name, variant| name.* = std.mem.span(variant.name);
        // A reference variant takes a drop even while not dragged over: the slot is the dropdown.
        if (self.dropdown(key, names[0..count], current.tag)) |picked| {
            self.set(node, field_value.variantText(self.scratch(), self.parts, index, picked) catch return);
        }
        if (self.context.last_added) |trigger| for (variants) |variant| {
            if (variant.kind != .entity and variant.kind != .asset) continue;
            self.addSlot(trigger.id, node, variant, std.mem.span(variant.name));
            break;
        };
    }

    /// A union's chosen variant's own rows, under its dropdown.
    fn unionPayload(self: *Draw, index: usize, node: Node, key: u64, depth: u32) void {
        const this = self.parts[index];
        const current = self.value.variant(node) orelse return;
        const payload = current.payload orelse return;
        for (this.children(self.parts), 0..) |variant, i| {
            if (!std.mem.eql(u8, std.mem.span(variant.name), current.tag)) continue;
            if (variant.kind != .none) self.part(this.first + i, payload, displayName(self.scratch(), current.tag), childKey(key, i), depth + 1);
            return;
        }
    }

    /// A dropdown over `names` (shown as people read them), on `current`. Returns the one picked.
    fn dropdown(self: *Draw, key: u64, names: []const []const u8, current: []const u8) ?usize {
        const context = self.context;
        const options = self.scratch().alloc([]const u8, names.len) catch return null;
        var selected: usize = 0;
        for (options, names, 0..) |*option, name, i| {
            option.* = page_style.fitText(self.scratch(), context.font, displayName(self.scratch(), name), select_text_size, self.control_width - select_chrome);
            if (std.mem.eql(u8, name, current)) selected = i;
        }
        const before = selected;
        const changed = context.select(hiddenLabel(self.scratch(), key), options, &selected);
        // The dropdown keeps to the column rather than its own minimum width.
        if (context.last_added) |trigger| if (trigger.id != 0 and trigger.overlay == null) {
            trigger.style.min_width = 0;
        };
        return if (changed and selected != before) selected else null;
    }

    /// A vector's or colour's numbers in a row, each with its axis or channel tag; a colour
    /// starts with a swatch of itself, and its channels show how full they are.
    fn numbers(self: *Draw, node: Node, this: Part, key: u64, width: f32) void {
        const context = self.context;
        var nodes: [4]Node = undefined;
        const found = self.value.numbers(node, nodes[0..@min(this.len, 4)]);
        const number_part = self.parts[this.first];
        const is_color = this.kind == .color;
        // Channels go from 0 to 1, or to 255 for whole numbers.
        const range: ?[2]f64 = if (is_color) .{ 0, if (number_part.kind == .int) 255 else 1 } else null;
        const swatch_width: f32 = if (is_color) 22 else 0;
        const gap: f32 = 3;
        const box_width = (width - swatch_width - gap * @as(f32, @floatFromInt(found))) / @as(f32, @floatFromInt(@max(found, 1)));

        context.begin(.row);
        if (is_color) self.colorSwatch(nodes[0..found], number_part, range.?[1], key, swatch_width);
        for (nodes[0..found], 0..) |inner, i| {
            const tag = if (is_color) channel_tags[i] else axis_tags[i];
            const number = self.value.number(inner) orelse 0;
            if (self.numberBox(childKey(key, i), number, number_part, tag, range, box_width)) |new| self.set(inner, field_value.numberText(self.scratch(), new, number_part));
        }
        context.end();
        restyle(context, .{ .direction = .row, .gap = gap, .align_items = .center, .width = width });
    }

    /// A colour's swatch, which opens its picker (`color_popup.zig`) when pressed; `nodes` are its
    /// channels, each `full` at most.
    fn colorSwatch(self: *Draw, nodes: []const Node, number_part: Part, full: f64, key: u64, width: f32) void {
        const context = self.context;
        const editor = self.editor;
        var rgba: [4]f32 = .{ 0, 0, 0, 1 };
        for (nodes, rgba[0..nodes.len]) |inner, *channel| channel.* = @floatCast(std.math.clamp((self.value.number(inner) orelse 0) / full, 0, 1));

        const id = context.idFor(std.fmt.allocPrint(self.scratch(), "##swatch {x}", .{key}) catch return);
        const open = if (editor.color) |popup| popup.key == key and context.open_popup == id else false;
        if (context.activated(id)) {
            if (open) {
                editor.color = null;
                context.open_popup = 0;
            } else {
                editor.color = .open(key, rgba);
                context.open_popup = id;
            }
        } else if (editor.color != null and editor.color.?.key == key and !open) {
            // Something else took the page's popup (a dropdown, a press in another panel).
            editor.color = null;
        }
        const look = self.scratch().create(SwatchPaint) catch return;
        look.* = .{ .color = .{ rgba[0], rgba[1], rgba[2] } };
        const swatch = context.builder().node(id, .{ .width = width, .height = 22 }, .{ .custom = .{ .context = look, .draw = SwatchPaint.draw } }, &.{}) catch return;
        swatch.cursor = .pointer;
        swatch.accessibility = .{ .role = .button, .label = "Pick a colour", .expanded = editor.color != null and editor.color.?.key == key };
        context.element(swatch);

        // The picker, while open: its colour goes straight into the field.
        const popup = if (editor.color) |*popup| (if (popup.key == key) popup else return) else return;
        const result = popup.build(context, swatch, @as(u32, @truncate(key)) & ~@as(u32, 63) | 0x8000_0000);
        if (result.color) |color| {
            var texts: [4][]const u8 = undefined;
            for (texts[0..nodes.len], color[0..nodes.len]) |*text, channel| text.* = field_value.numberText(self.scratch(), channel * full, number_part);
            self.changed = self.value.replaceAll(self.scratch(), nodes, texts[0..nodes.len]) catch return;
        }
        if (result.closed) {
            editor.color = null;
            context.open_popup = 0;
        }
    }

    /// Something that turns (a quaternion, or turns about x, y and z): a dropdown of the formats
    /// it can be shown in, then its numbers in the one picked. Whatever the format, it is kept
    /// as its own type.
    fn rotation(self: *Draw, node: Node, this: Part, key: u64, width: f32) void {
        const context = self.context;
        const editor = self.editor;
        const stored_len: usize = if (this.kind == .quaternion) 4 else 3;
        var nodes: [4]Node = undefined;
        if (self.value.numbers(node, nodes[0..stored_len]) < stored_len) return context.muted(self.value.text(node));
        var stored: [4]f64 = .{ 0, 0, 0, 1 };
        for (stored[0..stored_len], nodes[0..stored_len]) |*number, inner| number.* = self.value.number(inner) orelse 0;
        const unit: f64 = if (this.radians) std.math.deg_per_rad else 1;
        const turned: Turn = if (this.kind == .quaternion) .{ .quaternion = stored } else .{ .euler_deg = .{ stored[0] * unit, stored[1] * unit, stored[2] * unit } };

        // The format, remembered per field, picked from a dropdown above the numbers.
        const format = editor.rotation_formats.get(key) orelse if (this.kind == .quaternion) RotationFormat.quaternion else .euler_deg;
        var names: [rotation_formats.len][]const u8 = undefined;
        for (&names, rotation_formats) |*name, option| name.* = page_style.fitText(self.scratch(), context.font, option.label(), select_text_size, width - select_chrome);
        var picked: usize = @backingInt(format);
        if (context.select(hiddenLabel(self.scratch(), childKey(key, 99)), &names, &picked)) editor.rotation_formats.put(editor.gpa, key, @fromBackingInt(@intCast(picked))) catch {};
        if (context.last_added) |trigger| if (trigger.overlay == null) {
            trigger.style.min_width = 0;
            trigger.style.width = width;
        };

        // Its numbers in that format; a change goes back into the field as its own type.
        const shown = format.show(turned);
        const count = format.len();
        const gap: f32 = 3;
        const box_width = (width - gap * @as(f32, @floatFromInt(count - 1))) / @as(f32, @floatFromInt(count));
        context.begin(.row);
        for (0..count) |i| {
            const tag = if (format == .axis_angle and i == 3) angle_tag else axis_tags[i];
            const new = self.numberBox(childKey(key, i), shown[i], .{ .kind = .float }, tag, null, box_width) orelse continue;
            var edited = shown;
            edited[i] = new;
            const back = format.read(edited);
            var texts: [4][]const u8 = undefined;
            const kept: [4]f64 = if (this.kind == .quaternion) back.toQuaternion() else blk: {
                const turns = back.toEulerDeg();
                break :blk .{ turns[0] / unit, turns[1] / unit, turns[2] / unit, 0 };
            };
            for (texts[0..stored_len], kept[0..stored_len]) |*text, number| text.* = field_value.numberText(self.scratch(), number, .{ .kind = .float });
            self.changed = self.value.replaceAll(self.scratch(), nodes[0..stored_len], texts[0..stored_len]) catch return;
        }
        context.end();
        restyle(context, .{ .direction = .row, .gap = gap, .align_items = .center, .width = width });
    }

    /// A number box showing `number`: drag it sideways to change it, or click it to type.
    /// `tag` labels an axis or channel; with `range` it shows how full it is and keeps inside.
    /// Returns the new number while it changes.
    fn numberBox(self: *Draw, key: u64, number: f64, this: Part, tag: ?Tag, range: ?[2]f64, width: f32) ?f64 {
        const context = self.context;
        const editor = self.editor;
        const arena = self.scratch();

        // One widget identity keeps Tab/Shift+Tab editable, including text arriving this frame.
        const continuing = if (editor.typing) |typing| typing.key == key else false;
        var initial = NumberEdit.init(field_value.numberText(arena, number, this)) catch return null;
        initial.selectAll();
        const edit = if (continuing) &editor.typing.?.edit else &initial;
        const changed = context.textInput(std.fmt.allocPrint(arena, "##number {x}", .{key}) catch return null, edit, "");
        const box = context.last_added orelse return null;
        const id = box.id;
        box.style.min_width = 0;
        box.style.width = width;
        box.style.height = 22;

        // A press takes the pointer; moving sideways drags the number, letting go without
        // moving types into it.
        if (!continuing and pressedOn(context, id)) {
            context.active = id;
            editor.scrub = .{ .key = key, .from_x = context.pointer.x, .from = number };
        }
        var result: ?f64 = null;
        if (editor.scrub) |*scrub| if (scrub.key == key) {
            if (context.active == id) {
                const moved = context.pointer.x - scrub.from_x;
                if (@abs(moved) >= drag_threshold) scrub.moved = true;
                if (scrub.moved) {
                    const step: f64 = if (range) |limits|
                        (limits[1] - limits[0]) / @max(width, 1)
                    else if (this.kind == .int) 0.2 else @max(@abs(scrub.from), 1) * 0.01;
                    var new = scrub.from + moved * step;
                    if (range) |limits| new = std.math.clamp(new, limits[0], limits[1]);
                    if (new != number) result = new;
                }
            } else {
                if (!scrub.moved) {
                    context.focus = id;
                } else if (context.focus == id) context.focus = 0;
                editor.scrub = null;
            }
        };

        if (context.focus == id and editor.scrub == null) {
            if (!continuing) {
                initial.selectAll();
                editor.typing = .{ .key = key, .edit = initial };
            }
            const typing = &editor.typing.?;
            context.wants_text = true;
            box.paint_kind.input.value = typing.edit.text();
            box.paint_kind.input.focused = true;
            box.paint_kind.input.cursor = typing.edit.cursor;
            box.paint_kind.input.selection = typing.edit.selection();
            if (changed) {
                if (std.fmt.parseFloat(f64, std.mem.trim(u8, typing.edit.text(), " "))) |typed| {
                    result = if (range) |limits| std.math.clamp(typed, limits[0], limits[1]) else typed;
                } else |_| {}
            }
            for (context.pending.items) |item| if (item == .key) switch (item.key.key) {
                .enter, .escape => {
                    context.focus = 0;
                },
                else => {},
            };
            if (context.focus == id) {
                return result;
            }
        }
        if (editor.typing) |typing| if (typing.key == key) {
            editor.typing = null;
        };

        const look = arena.create(NumberPaint) catch return null;
        look.* = .{
            .id = id,
            .text = shortNumber(arena, number, this),
            .tag = tag,
            .fill = if (range) |limits| @floatCast(std.math.clamp((number - limits[0]) / (limits[1] - limits[0]), 0, 1)) else null,
            .dragging = context.active == id,
        };
        box.paint_kind = .{ .custom = .{ .context = look, .draw = NumberPaint.draw } };
        box.cursor = .ew_resize;
        box.accessibility = .{ .role = .slider, .label = if (tag) |t| t.letter else "Number", .numeric_value = @floatCast(number) };
        return result;
    }

    /// A reference slot: what it points at (`shown`, empty for nothing) and an x to clear it.
    /// Lit while `dragging` would fit it, dimmed while something that wouldn't is. `variant`
    /// names the union variant a drop sets, if any.
    fn slot(self: *Draw, key: u64, node: Node, target: Part, shown: []const u8, width: f32, variant: []const u8) void {
        const context = self.context;
        const b = context.builder();
        const arena = b.allocator;
        const id = context.idFor(std.fmt.allocPrint(arena, "##slot {x}", .{key}) catch return);
        self.addSlot(id, node, target, variant);

        const empty = shown.len == 0;
        const requires = std.mem.span(target.requires);
        const hint: []const u8 = switch (target.kind) {
            .entity => if (requires.len > 0) std.fmt.allocPrint(arena, "Drop an entity with {s}", .{requires}) catch "Drop an entity" else "Drop an entity",
            else => if (target.accepts == .any) "Drop a file" else std.fmt.allocPrint(arena, "Drop a {s} file", .{@tagName(target.accepts)}) catch "Drop a file",
        };
        const clearable = !empty and variant.len == 0;
        const clear_room: f32 = if (clearable) 28 else 0;
        const label = page_style.fitText(arena, context.font, if (empty) hint else shown, 12, width - 20 - clear_room);
        const look = arena.create(SlotPaint) catch return;
        look.* = .{ .id = id, .fits = if (self.dragging) |dragged| dragged.fits(target) else null };
        context.begin(.row);
        const box = b.node(id, .{ .height = 26, .grow = 1, .padding = .{ .left = 8, .right = 8 }, .align_items = .center, .direction = .row }, .{ .custom = .{ .context = look, .draw = SlotPaint.draw } }, &.{
            b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = label, .size = 12, .tone = if (empty) .muted else .foreground } }, &.{}) catch return,
        }) catch return;
        box.accessibility = .{ .role = .button, .label = if (empty) hint else shown };
        context.element(box);
        if (clearable) {
            const clear_id = context.idFor(std.fmt.allocPrint(arena, "##clear {x}", .{key}) catch return);
            if (context.activated(clear_id)) self.set(node, if (target.kind == .entity) "null" else "\"\"");
            const clear = b.node(clear_id, .{ .width = 24, .height = 24, .padding = .{ .left = 6, .right = 6, .top = 6, .bottom = 6 } }, .none, &.{
                b.node(0, .{ .width = 12, .height = 12 }, .{ .icon = .x }, &.{}) catch return,
            }) catch return;
            clear.cursor = .pointer;
            clear.accessibility = .{ .role = .button, .label = "Clear" };
            context.element(clear);
        }
        context.end();
        restyle(context, .{ .direction = .row, .gap = 4, .align_items = .center, .width = width });
    }

    /// Remember element `id` as a drop target setting `node` to what `target` takes.
    fn addSlot(self: *Draw, id: u32, node: Node, target: Part, variant: []const u8) void {
        const editor = self.editor;
        const keep = editor.slot_arena.allocator();
        const old = self.value.text(node);
        const start = @intFromPtr(old.ptr) - @intFromPtr(self.value.source.ptr);
        var copied = target;
        copied.requires = (keep.dupeSentinel(u8, std.mem.span(target.requires), 0) catch return).ptr;
        editor.slots.append(editor.gpa, .{
            .id = id,
            .component = self.component,
            .field = self.field,
            .target = copied,
            .before = keep.dupe(u8, self.value.source[0..start]) catch return,
            .after = keep.dupe(u8, self.value.source[start + old.len ..]) catch return,
            .variant = keep.dupe(u8, variant) catch return,
        }) catch {};
    }

    /// A nested reference's value as people read it: an asset's path, or the entity's number.
    fn referenceText(self: *Draw, node: Node) []const u8 {
        return switch (self.value.get(node)) {
            .string_literal => |key| if (self.assets) |assets| assets.label(self.scratch(), key) else key,
            .null => "",
            else => self.value.text(node),
        };
    }
};

/// Open a row for a part: its label, `depth` in, then its control's column (`endRow` closes both).
pub fn labelledRow(context: *ui.Context, label: []const u8, depth: u32) void {
    context.begin(.row);
    context.text(label);
    page_style.smallText(context, 13);
    restyle(context, .{ .grow = 1, .padding = .{ .left = indent * @as(f32, @floatFromInt(depth)) } });
    context.begin(.column);
}

/// Close the row `labelledRow` opened.
pub fn endRow(context: *ui.Context, width: f32) void {
    context.end();
    restyle(context, .{ .width = width, .align_items = .end });
    context.end();
    restyle(context, .{ .direction = .row, .gap = 10, .align_items = .center });
}

/// Whether the left button went down on element `id` since the last frame, with nothing on a
/// layer above it there. By its own bounds: a container the same size as it would tie with it
/// for the widget under the pointer.
fn pressedOn(context: *const ui.Context, id: u32) bool {
    if (!context.pressed_down) return false;
    const press = context.press orelse return false;
    const mine = context.last_bounds.get(id) orelse return false;
    if (!mine.rect.contains(press.at.x, press.at.y)) return false;
    const top = context.last_bounds.get(press.widget) orelse return true;
    return top.z <= mine.z;
}

/// The key of part `index` inside the part keyed `parent`.
fn childKey(parent: u64, index: usize) u64 {
    return std.hash.Wyhash.hash(parent, std.mem.asBytes(&index));
}

fn hiddenLabel(arena: std.mem.Allocator, key: u64) []const u8 {
    return std.fmt.allocPrint(arena, "##part {x}", .{key}) catch "##part";
}

/// `number` as a box shows it: whole for an int, at most three decimals for a float.
fn shortNumber(arena: std.mem.Allocator, number: f64, this: Part) []const u8 {
    if (this.kind == .int) return field_value.numberText(arena, number, this);
    const text = std.fmt.allocPrint(arena, "{d:.3}", .{number}) catch return "";
    // Without trailing zeros: 1.500 reads 1.5, and 2.000 reads 2.
    if (std.mem.indexOfScalar(u8, text, '.') == null) return text;
    var end = text.len;
    while (text[end - 1] == '0') end -= 1;
    if (text[end - 1] == '.') end -= 1;
    return if (std.mem.eql(u8, text[0..end], "-0")) "0" else text[0..end];
}

/// `turns_per_second` as "Turns per second". In `arena`.
/// Editor label helper: replaces underscores and capitalizes the first ASCII letter.
/// Allocation failure returns the original borrowed name unchanged.
///
/// ```zig
/// const label = displayName(arena, "turns_per_second"); // Existing arena allocator.
/// ```
pub fn displayName(arena: std.mem.Allocator, name: []const u8) []const u8 {
    const label = arena.dupe(u8, name) catch return name;
    for (label) |*char| if (char.* == '_') {
        char.* = ' ';
    };
    if (label.len > 0) label[0] = std.ascii.toUpper(label[0]);
    return label;
}

/// Quaternion `q` (x, y, z, w) as turns about x, then y, then z, in degrees.
fn eulerOf(q: [4]f64) [3]f64 {
    const x, const y, const z, const w = q;
    const about_x = std.math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y));
    const about_y = std.math.asin(std.math.clamp(2 * (w * y - z * x), -1, 1));
    const about_z = std.math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z));
    return .{ about_x * std.math.deg_per_rad, about_y * std.math.deg_per_rad, about_z * std.math.deg_per_rad };
}

/// Turns about x, then y, then z (in degrees) as a quaternion (x, y, z, w).
fn quaternionOf(turns_deg: [3]f64) [4]f64 {
    const half = [3]f64{ turns_deg[0] * std.math.rad_per_deg / 2, turns_deg[1] * std.math.rad_per_deg / 2, turns_deg[2] * std.math.rad_per_deg / 2 };
    const cx, const sx = .{ @cos(half[0]), @sin(half[0]) };
    const cy, const sy = .{ @cos(half[1]), @sin(half[1]) };
    const cz, const sz = .{ @cos(half[2]), @sin(half[2]) };
    return .{
        sx * cy * cz - cx * sy * sz,
        cx * sy * cz + sx * cy * sz,
        cx * cy * sz - sx * sy * cz,
        cx * cy * cz + sx * sy * sz,
    };
}

/// `q` scaled to length 1; no turn at all for one of length 0.
fn normalized(q: [4]f64) [4]f64 {
    const length = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (length < 1e-9) return .{ 0, 0, 0, 1 };
    return .{ q[0] / length, q[1] / length, q[2] / length, q[3] / length };
}

/// Quaternion `q` as an axis (x, y, z) and an angle about it in degrees; about x for no turn.
fn axisAngleOf(q: [4]f64) [4]f64 {
    const unit = normalized(q);
    const angle = 2 * std.math.acos(std.math.clamp(unit[3], -1, 1));
    const s = @sqrt(@max(1 - unit[3] * unit[3], 0));
    if (s < 1e-6) return .{ 1, 0, 0, angle * std.math.deg_per_rad };
    return .{ unit[0] / s, unit[1] / s, unit[2] / s, angle * std.math.deg_per_rad };
}

/// An axis (x, y, z) and an angle about it in degrees as a quaternion.
fn quaternionOfAxisAngle(axis_angle: [4]f64) [4]f64 {
    const length = @sqrt(axis_angle[0] * axis_angle[0] + axis_angle[1] * axis_angle[1] + axis_angle[2] * axis_angle[2]);
    if (length < 1e-9) return .{ 0, 0, 0, 1 };
    const half = axis_angle[3] * std.math.rad_per_deg / 2;
    const s = @sin(half) / length;
    return .{ axis_angle[0] * s, axis_angle[1] * s, axis_angle[2] * s, @cos(half) };
}

/// How a number box is drawn: a field's box (filled as far as its value goes, if it has a
/// range), its tag on the left, and the number.
const NumberPaint = struct {
    id: u32,
    text: []const u8,
    tag: ?Tag,
    fill: ?f32,
    dragging: bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const NumberPaint = @ptrCast(@alignCast(context));
        const t = c.theme;
        try c.roundRect(r, t.muted, t.radiusSm());
        if (self.fill) |fill| try c.roundRectAlpha(.{ .x = r.x, .y = r.y, .w = r.w * fill, .h = r.h }, t.primary, t.radiusSm(), 0.35);
        try c.roundRectStroke(r, if (self.dragging or c.hot_id == self.id) t.ring else t.border, t.radiusSm(), 1);
        var text_area = ui.Rect{ .x = r.x + 6, .y = r.y, .w = r.w - 12, .h = r.h };
        if (self.tag) |tag| {
            const pill = ui.Rect{ .x = r.x + 2, .y = r.y + 2, .w = 14, .h = r.h - 4 };
            try c.roundRect(pill, tag.color, t.radiusSm() * 0.6);
            try c.textIn(pill, tag.letter, 10, .{ 1, 1, 1 }, .center);
            text_area.x = pill.x + pill.w + 4;
            text_area.w = r.x + r.w - 4 - text_area.x;
        }
        try c.textIn(text_area, self.text, 12, t.foreground, .start);
    }
};

/// A colour's swatch: the colour, outlined.
const SwatchPaint = struct {
    color: ui.Color,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const SwatchPaint = @ptrCast(@alignCast(context));
        try c.roundRect(r, self.color, c.theme.radiusSm());
        try c.roundRectStroke(r, c.theme.border, c.theme.radiusSm(), 1);
    }
};

/// How a reference slot is drawn: a field's box, outlined while a drag would fit it.
const SlotPaint = struct {
    id: u32,
    /// Whether what is being dragged would fit; null while nothing is.
    fits: ?bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const SlotPaint = @ptrCast(@alignCast(context));
        const t = c.theme;
        const hovered = c.hot_id == self.id;
        if (self.fits) |fits| {
            if (fits) {
                try c.roundRectAlpha(r, t.primary, t.radiusSm(), if (hovered) 0.25 else 0.1);
                try c.roundRectStroke(r, t.primary, t.radiusSm(), 1.5);
            } else try c.roundRectAlpha(r, t.muted, t.radiusSm(), 0.6);
            return;
        }
        try c.roundRect(r, t.muted, t.radiusSm());
        try c.roundRectStroke(r, t.border, t.radiusSm(), 1);
    }
};

test "turns go to a quaternion and back" {
    const turns = [3]f64{ 30, -45, 80 };
    const back = eulerOf(quaternionOf(turns));
    for (back, turns) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
}

test "numbers are shown short" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("1.5", shortNumber(arena.allocator(), 1.5, .{ .kind = .float }));
    try std.testing.expectEqualStrings("2", shortNumber(arena.allocator(), 2.0004, .{ .kind = .float }));
    try std.testing.expectEqualStrings("0", shortNumber(arena.allocator(), -0.0001, .{ .kind = .float }));
}

test "a turn reads back the same in every format" {
    const turn = Turn{ .euler_deg = .{ 30, -45, 80 } };
    for (rotation_formats) |format| {
        const back = format.read(format.show(turn)).toEulerDeg();
        for (back, [_]f64{ 30, -45, 80 }) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
    }
}

test "Tab and Shift+Tab select numeric values for typing without a mouse click" {
    const Fixture = struct {
        fn frame(context: *ui.Context, editor: *FieldEditor, text: []const u8) !?[]const u8 {
            context.newFrame(.{ .x = 0, .y = 0, .w = 400, .h = 200 });
            editor.newFrame();
            const changed = editor.fieldRows(context, .{
                .component = 0,
                .field = 0,
                .label = "Position",
                .parts = &.{ .{ .kind = .vector, .first = 1, .count = 1, .len = 3 }, .{ .kind = .float } },
                .text = text,
                .shown = null,
                .control_width = 240,
                .dragging = null,
            });
            _ = try context.render();
            return changed;
        }
    };
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var editor = FieldEditor.init(std.testing.allocator);
    defer editor.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var text: []const u8 = ".{ 1, 2, 3 }";
    _ = try Fixture.frame(&context, &editor, text);
    const ids = context.last_focusables.items[0..3].*;
    const cases = [_]struct { backward: bool, input: []const u8, axis: usize, expected: [3]f64 }{
        .{ .backward = false, .input = "12", .axis = 0, .expected = .{ 12, 2, 3 } },
        .{ .backward = false, .input = "34", .axis = 1, .expected = .{ 12, 34, 3 } },
        .{ .backward = false, .input = "56", .axis = 2, .expected = .{ 12, 34, 56 } },
        .{ .backward = true, .input = "78", .axis = 1, .expected = .{ 12, 78, 56 } },
        .{ .backward = true, .input = "90", .axis = 0, .expected = .{ 90, 78, 56 } },
    };
    for (cases) |case| {
        context.handle(.{ .key_down = .{ .key = .tab, .modifiers = .{ .shift = case.backward }, .repeat = false } });
        context.handle(.{ .text = case.input });
        const changed = (try Fixture.frame(&context, &editor, text)).?;
        const value = Value.parse(context.builder().allocator, changed).?;
        var nodes: [3]Node = undefined;
        try std.testing.expectEqual(@as(usize, 3), value.numbers(.root, &nodes));
        for (nodes, case.expected) |node, expected| try std.testing.expectEqual(expected, value.number(node).?);
        try std.testing.expectEqual(ids[case.axis], context.focus);
        try std.testing.expectEqualSlices(u32, &ids, context.last_focusables.items);
        try std.testing.expect(context.wants_text);
        text = try arena.allocator().dupe(u8, changed);
    }
}
