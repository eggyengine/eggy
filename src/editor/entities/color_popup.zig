//! A colour field's picker: weeoui's colour editor (hue wheel, saturation and value bars, RGB,
//! alpha and HSV sliders, hex fields, old and new swatches, presets), floating over the
//! Inspector from the field's swatch. Not a dialog: the page stays usable, and it closes on a
//! press anywhere else (keeping the colour), on OK, or on Cancel or Escape (putting it back).
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const L = ui.Layout;

const HexEdit = ui.TextEdit(16);
/// The presets under the picker.
const swatches = [_]ui.Color{
    .{ 1, 1, 1 },          .{ 0.5, 0.5, 0.5 },   .{ 0, 0, 0 },        .{ 0.86, 0.2, 0.2 },
    .{ 0.95, 0.55, 0.15 }, .{ 0.95, 0.85, 0.2 }, .{ 0.3, 0.75, 0.3 }, .{ 0.2, 0.55, 0.9 },
    .{ 0.55, 0.35, 0.85 },
};
/// The widget's ids from its first: the channels, hex fields, buttons, the old swatch, presets.
const hex_linear = 10;
const hex_srgb = 11;
const ok = 12;
const cancel = 13;
const old_swatch = 14;
const first_preset = 15;
/// How many ids the picker takes from its first, its own surface's last.
const id_count = 32;

pub const ColorPopup = struct {
    /// The field part it edits (see `FieldEditor`).
    key: u64,
    editor: ui.ColorEditor,
    /// The hex field being typed into (`hex_linear` or `hex_srgb`), and its text.
    hex: ?struct { which: u32, edit: HexEdit } = null,

    pub const Result = struct {
        /// The colour (sRGB, 0 to 1) and alpha, whenever they changed this frame.
        color: ?[4]f32 = null,
        closed: bool = false,
    };

    /// Create an editor picker for field-part `key`, copying sRGB RGBA channels in [0, 1].
    /// The original color is retained for cancellation; no allocation or ownership transfer.
    ///
    /// ```zig
    /// var popup = ColorPopup.open(1, .{ 0.2, 0.4, 0.6, 1 });
    /// ```
    pub fn open(key: u64, color: [4]f32) ColorPopup {
        return .{ .key = key, .editor = .init(.{ color[0], color[1], color[2] }, color[3]) };
    }

    /// Draw the picker over everything in `context`'s page, under the swatch `anchor`, taking ids
    /// from `first_id`, and handle this frame's input on it.
    /// Editor-only: `anchor` belongs to this frame and 32 ids starting at `first_id` must be
    /// reserved. Apply `result.color` even when closed (Cancel returns the original RGBA),
    /// then discard the popup if `closed`. UI allocation failures leave a partial/no overlay.
    ///
    /// ```zig
    /// // Given popup, a building UI context and this frame's swatch element:
    /// const result = popup.build(context, anchor, 0x4000_0000);
    /// _ = result; // Apply any color, then close the owning optional when requested.
    /// ```
    pub fn build(self: *ColorPopup, context: *ui.Context, anchor: *const L.Element, first_id: u32) Result {
        var result: Result = .{};
        const before = self.editor;

        // Presses: on a channel, it takes the pointer; on a hex field, it takes the keyboard.
        if (context.pressed_down) if (context.press) |press| {
            const surface = context.last_bounds.get(first_id + id_count - 1);
            const inside = if (surface) |bounds| bounds.rect.contains(press.at.x, press.at.y) else true;
            const on_anchor = if (context.last_bounds.get(anchor.id)) |bounds| bounds.rect.contains(press.at.x, press.at.y) else false;
            if (!inside and !on_anchor) return .{ .closed = true };
            for (0..10) |channel| {
                const id = first_id + @as(u32, @intCast(channel));
                const bounds = context.last_bounds.get(id) orelse continue;
                if (!bounds.rect.contains(press.at.x, press.at.y)) continue;
                context.active = id;
                self.editor.press(@enumFromInt(channel), bounds.rect, press.at.x, press.at.y);
                self.hex = null;
            }
            for ([_]u32{ hex_linear, hex_srgb }) |which| {
                const bounds = context.last_bounds.get(first_id + which) orelse continue;
                if (bounds.rect.contains(press.at.x, press.at.y)) self.startHex(which);
            }
        };
        if (context.active >= first_id and context.active < first_id + 10) self.editor.dragTo(context.pointer.x, context.pointer.y);
        if (context.released >= first_id and context.released < first_id + 10) self.editor.release();

        // Clicks: OK keeps the colour, Cancel and the old swatch put it back, presets pick.
        if (context.activated(first_id + ok)) {
            self.editor.commit();
            return .{ .closed = true };
        }
        if (context.activated(first_id + cancel) or context.escape) {
            context.escape = false;
            self.editor.revert();
            return .{ .color = self.rgba(), .closed = true };
        }
        if (context.activated(first_id + old_swatch)) self.editor.revert();
        for (swatches, 0..) |preset, i| if (context.activated(first_id + first_preset + @as(u32, @intCast(i)))) {
            self.editor.hsv = .fromRgb(preset, self.editor.hsv.h);
        };
        self.typeHex(context);

        // The picker, on a surface of its own floating under the swatch, above the page.
        const b = context.builder();
        var linear_buffer: [8]u8 = undefined;
        var srgb_buffer: [8]u8 = undefined;
        const typing = self.hex;
        const linear_text = if (typing != null and typing.?.which == hex_linear) typing.?.edit.text() else self.editor.hex(&linear_buffer, .linear);
        const srgb_text = if (typing != null and typing.?.which == hex_srgb) typing.?.edit.text() else self.editor.hex(&srgb_buffer, .srgb);
        const picker = ui.widgets.colorEditor(b, first_id, self.editor, .{ .value = b.allocator.dupe(u8, linear_text) catch "", .focused = typing != null and typing.?.which == hex_linear }, .{ .value = b.allocator.dupe(u8, srgb_text) catch "", .focused = typing != null and typing.?.which == hex_srgb }, &swatches) catch return result;
        const surface = b.node(first_id + id_count - 1, .{ .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 }, .z_index = 120 }, .card, &.{picker}) catch return result;
        surface.overlay = .{ .anchor = .{ .target = anchor, .side = .bottom } };
        surface.accessibility = .{ .role = .group, .label = "Colour picker" };
        // On the page itself, so the row it was opened from doesn't clip it.
        context.stack.items[0].children.append(b.allocator, surface) catch return result;

        if (!std.meta.eql(before.hsv, self.editor.hsv) or before.alpha != self.editor.alpha) result.color = self.rgba();
        return result;
    }

    fn rgba(self: *const ColorPopup) [4]f32 {
        const color = self.editor.rgb();
        return .{ color[0], color[1], color[2], self.editor.alpha };
    }

    fn startHex(self: *ColorPopup, which: u32) void {
        var buffer: [8]u8 = undefined;
        const text = self.editor.hex(&buffer, if (which == hex_linear) .linear else .srgb);
        self.hex = .{ .which = which, .edit = HexEdit.init(text) catch return };
        self.hex.?.edit.selectAll();
    }

    /// Typing into a hex field: the colour follows once the text is a whole colour; Enter leaves it.
    fn typeHex(self: *ColorPopup, context: *ui.Context) void {
        const typing = if (self.hex) |*hex| hex else return;
        context.wants_text = true;
        for (context.pending.items) |item| switch (item) {
            .text => |range| _ = typing.edit.insertFitting(context.typed.items[range.start..][0..range.len]) catch false,
            .key => |key| switch (key.key) {
                .backspace => typing.edit.backspace(),
                .delete => typing.edit.delete(),
                .left => typing.edit.moveLeft(key.modifiers.shift, false),
                .right => typing.edit.moveRight(key.modifiers.shift, false),
                .enter => {
                    self.hex = null;
                    return;
                },
                else => {},
            },
        };
        self.editor.setHex(typing.edit.text(), if (typing.which == hex_linear) .linear else .srgb) catch {};
    }
};

test "a picked preset comes back as the colour, and Cancel puts the old one back" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 600, .h = 800 };
    var popup = ColorPopup.open(1, .{ 0.2, 0.4, 0.6, 1 });
    const first_id: u32 = 0x4000_0000;

    // A frame to lay it out, then a click on the first preset (white).
    context.newFrame(viewport);
    try std.testing.expect(popup.build(&context, try testAnchor(&context), first_id).color == null);
    _ = try context.render();
    const preset = context.last_bounds.get(first_id + first_preset).?.rect;
    const at = ui.Vec2{ .x = preset.x + 5, .y = preset.y + 5 };
    context.handle(.{ .pointer_move = at });
    context.handle(.{ .pointer_down = .{ .position = at, .button = .left, .clicks = 1 } });
    context.handle(.{ .pointer_up = .{ .position = at, .button = .left } });
    context.newFrame(viewport);
    const picked = popup.build(&context, try testAnchor(&context), first_id);
    _ = try context.render();
    try std.testing.expectApproxEqAbs(@as(f32, 1), picked.color.?[0], 0.01);
    try std.testing.expect(!picked.closed);

    // Escape: back to where it started, and closed.
    context.handle(.{ .key_down = .{ .key = .escape, .modifiers = .{}, .repeat = false } });
    context.newFrame(viewport);
    const cancelled = popup.build(&context, try testAnchor(&context), first_id);
    try std.testing.expect(cancelled.closed);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), cancelled.color.?[0], 0.01);
}

/// A swatch for the test's picker to float under, made anew each frame (frames own their elements).
fn testAnchor(context: *ui.Context) !*L.Element {
    const anchor = try context.builder().node(77, .{ .width = 20, .height = 20 }, .none, &.{});
    context.element(anchor);
    return anchor;
}
