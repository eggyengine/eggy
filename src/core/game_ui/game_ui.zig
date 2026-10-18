//! Customizable game UI drawn into an engine-owned frame or scene target.
const std = @import("std");
const vit = @import("vitellus");
const ui = @import("weeoui");
const adapter = @import("weeoui_sdl3");
const renderer = @import("weeoui_vitellus");
const sdl = @import("vitellus_sdl3").sdl;
const hit_test = @import("../ui_hit_test.zig");
const input_types = @import("../input/types.zig");
const input_state = @import("../input/state.zig");

/// Borrowed only during `draw`. Starts outside a render pass, with the target in
/// color-attachment state. Leave it in that state, outside a pass; never submit/present it.
pub const DrawContext = struct {
    cmd: vit.CommandBuffer,
    target: vit.TextureView,
    extent_px: vit.Extent2D,
    viewport: ui.Rect,
    color_format: vit.Format,
    /// The engine's frame-in-flight owner, compared only for identity.
    frame_owner: *const anyopaque,
    /// This owner's reusable CPU/GPU slot, already waited by `Surface.beginFrame`.
    frame_slot: usize,

    /// Begin a pass that preserves the scene and earlier custom drawing.
    pub fn beginPass(self: DrawContext) !void {
        try self.cmd.beginRenderPass(.{ .label = "game ui", .color_attachments = &.{.{ .view = self.target, .load_op = .load, .store_op = .store }} });
    }
    pub fn endPass(self: DrawContext) void {
        self.cmd.endRenderPass();
    }
};

/// Heap-owned by App, destroyed before world/library reset. No plugin callbacks are retained.
pub const Overlay = struct {
    gpa: std.mem.Allocator,
    queue: vit.Queue,
    device: vit.Device,
    color_format: vit.Format,
    context: ui.Context,
    renderer: renderer.Renderer,
    font_bytes: ?[]u8 = null,
    last_owner: ?*const anyopaque = null,
    pointer_active: bool = false,
    captured_keys: std.StaticBitSet(512) = .initEmpty(),
    keyboard_owned: bool = false,
    touch_owners: std.AutoHashMapUnmanaged(input_types.TouchKey, void) = .empty,
    primary_touch: ?input_types.TouchKey = null,
    finger_lifted: bool = false,

    pub fn init(gpa: std.mem.Allocator, device: vit.Device, queue: vit.Queue, color_format: vit.Format) !Overlay {
        var context = try ui.Context.init(gpa);
        errdefer context.deinit();
        const painter = try renderer.Renderer.init(device, color_format, context.font);
        return .{ .gpa = gpa, .queue = queue, .device = device, .color_format = color_format, .context = context, .renderer = painter };
    }

    pub fn deinit(self: *Overlay) void {
        self.queue.waitIdle() catch |err| std.log.err("cannot finish game UI GPU work: {t}", .{err});
        self.renderer.deinit();
        self.touch_owners.deinit(self.gpa);
        self.context.deinit();
        if (self.font_bytes) |bytes| self.gpa.free(bytes);
    }

    /// Copy a TTF/OTF and replace the default font safely. Bytes may come from a temporary
    /// resource read or game library. Call once when selecting a font, not every frame.
    pub fn setFont(self: *Overlay, bytes: []const u8) !void {
        const owned = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(owned);
        const font = try self.gpa.create(ui.Font);
        errdefer self.gpa.destroy(font);
        font.* = try ui.Font.init(self.gpa, owned);
        errdefer font.deinit();
        var painter = try renderer.Renderer.init(self.device, self.color_format, font);
        errdefer painter.deinit();
        try self.queue.waitIdle();
        self.renderer.deinit();
        if (self.context.owns_font) {
            self.context.font.deinit();
            self.gpa.destroy(self.context.font);
        }
        if (self.font_bytes) |old| self.gpa.free(old);
        self.font_bytes = owned;
        self.context.font = font;
        self.context.owns_font = true;
        self.renderer = painter;
    }

    pub fn begin(self: *Overlay, draw: DrawContext, time_ms: u64) void {
        self.context.pixel_scale = .{ @as(f32, @floatFromInt(draw.extent_px.width)) / draw.viewport.w, @as(f32, @floatFromInt(draw.extent_px.height)) / draw.viewport.h };
        self.context.font.dpi_scale = self.context.pixel_scale[0];
        self.context.srgb_target = renderer.isSrgb(draw.color_format);
        self.context.newFrame(draw.viewport);
        self.context.time_ms = time_ms;
    }

    /// Upload outside a pass, then draw over the target. True means UI newly acquired
    /// keyboard focus: cancel gameplay holds before the next update. Moving between surfaces
    /// waits once so their frame slots cannot overwrite another surface's pending vertices.
    pub fn render(self: *Overlay, draw: DrawContext) !bool {
        if (self.last_owner) |owner| if (owner != draw.frame_owner) try self.queue.waitIdle();
        self.last_owner = draw.frame_owner;
        const vertices = try self.context.render();
        const owns_keyboard = self.context.focus != 0 or self.context.open_popup != 0;
        const gained_keyboard = owns_keyboard and !self.keyboard_owned;
        self.keyboard_owned = owns_keyboard;
        if (self.pointer_active) adapter.setCursor(self.context.cursor);
        try self.renderer.upload(draw.cmd, self.context.font, vertices, draw.viewport);
        try draw.beginPass();
        self.renderer.draw(draw.cmd, draw.extent_px, 0, vertices.len);
        draw.endPass();
        if (self.finger_lifted) {
            self.context.handle(.{ .pointer_move = .init(-1, -1) });
            self.pointer_active = false;
            self.finger_lifted = false;
        }
        return gained_keyboard;
    }

    /// Route an already viewport-local SDL event. Standalone UIs use the SDL accessibility
    /// adapter; embedded UIs leave the host window's accessibility adapter in charge.
    pub fn handle(self: *Overlay, event: sdl.events.Event, embedded: bool) bool {
        if (syntheticTouchMouse(event)) return true;
        if (isTouchInput(event)) return self.handleTouch(event);
        switch (event) {
            .mouse_motion, .mouse_button_down, .mouse_button_up, .mouse_wheel => self.pointer_active = true,
            .window_mouse_leave => self.pointer_active = false,
            else => {},
        }
        var consumed = captures(&self.context, event);
        switch (event) {
            .key_down => |key| if (key.scancode) |code| {
                const index = @intFromEnum(code);
                if (index < 512) {
                    if (consumed) self.captured_keys.set(index) else self.captured_keys.unset(index);
                }
            },
            .key_up => |key| if (key.scancode) |code| {
                const index = @intFromEnum(code);
                if (index < 512) {
                    consumed = consumed or self.captured_keys.isSet(index);
                    self.captured_keys.unset(index);
                }
            },
            else => {},
        }
        const keyboard = switch (event) {
            .key_down, .key_up, .text_input, .text_editing => true,
            else => false,
        };
        if (!keyboard or consumed) {
            if (embedded) {
                // ponytail: embedded widgets are not merged into the editor's accessibility tree, add multi-context tree integration first.
                if (adapter.translate(event)) |input| self.context.handle(input);
            } else adapter.handleEvent(&self.context, event);
        }
        if (event == .window_focus_lost) self.cancel();
        return consumed;
    }

    fn handleTouch(self: *Overlay, event: sdl.events.Event) bool {
        const finger = switch (event) {
            .finger_down, .finger_up, .finger_motion, .finger_canceled => |finger| finger,
            else => unreachable,
        };
        const key = input_state.touchKey(finger);
        const point = ui.Vec2.init(self.context.viewport.x + finger.x * self.context.viewport.w, self.context.viewport.y + finger.y * self.context.viewport.h);
        if (event == .finger_down) {
            const root = self.context.last_root;
            const over_ui = self.context.open_popup != 0 or (if (root) |tree| hit_test.controlAt(tree, point.x, point.y) != 0 or scrollableAt(tree, point.x, point.y) else false);
            if (!over_ui) {
                if (self.primary_touch == null) {
                    self.context.focus = 0;
                    self.context.wants_text = false;
                }
                return false;
            }
            self.touch_owners.put(self.gpa, key, {}) catch |err| {
                self.context.err = err;
                return true;
            };
            if (self.primary_touch == null) {
                self.primary_touch = key;
                self.pointer_active = true;
                self.context.handle(.{ .pointer_down = .{ .position = point, .button = .left, .clicks = 1 } });
            }
            return true;
        }
        if (!self.touch_owners.contains(key)) return false;
        if (self.primary_touch) |primary| if (std.meta.eql(primary, key)) {
            if (event == .finger_motion) {
                self.context.handle(.{ .pointer_move = point });
            } else {
                if (event == .finger_canceled) {
                    self.context.press = null;
                    self.context.active = 0;
                }
                self.context.handle(.{ .pointer_up = .{ .position = point, .button = .left } });
                self.primary_touch = null;
                self.finger_lifted = true;
            }
        };
        if (event == .finger_up or event == .finger_canceled) _ = self.touch_owners.remove(key);
        return true;
    }

    /// Clear transient capture without retaining references into a previous game frame.
    pub fn cancel(self: *Overlay) void {
        self.pointer_active = false;
        self.keyboard_owned = false;
        self.touch_owners.clearRetainingCapacity();
        self.primary_touch = null;
        self.finger_lifted = false;
        self.context.focus = 0;
        self.context.active = 0;
        self.context.press = null;
        self.context.pointer_held = false;
        self.context.scroll_drag = null;
        self.context.open_popup = 0;
        self.context.wants_text = false;
    }

    /// Synchronize this UI's clipboard requests; text input ownership is managed by the host.
    pub fn syncClipboard(self: *Overlay) !void {
        if (self.context.copied) |text| {
            const copy = try self.gpa.dupeZ(u8, text);
            defer self.gpa.free(copy);
            try sdl.clipboard.setText(copy);
        }
        if (self.context.paste_requested) {
            self.context.paste_requested = false;
            if (!sdl.clipboard.hasText()) return;
            const text = try sdl.clipboard.getText();
            defer sdl.free(text);
            self.context.handle(.{ .text = text });
        }
    }
};

/// Decide consumption from the last laid-out tree, focus and captured drags. Labels alone
/// do not capture the viewport. Keyboard releases stay with the focused keyboard consumer.
pub fn captures(context: *const ui.Context, event: sdl.events.Event) bool {
    return switch (event) {
        .key_down => |key| context.focus != 0 or context.open_popup != 0 or (key.scancode == .tab and context.last_focusables.items.len != 0),
        .key_up, .text_input, .text_editing => context.focus != 0 or context.open_popup != 0,
        .mouse_motion => |e| pointerCaptured(context, e.x, e.y),
        .mouse_button_down, .mouse_button_up => |e| pointerCaptured(context, e.x, e.y),
        .mouse_wheel => |e| pointerCaptured(context, e.x, e.y) or (if (context.last_root) |root| scrollableAt(root, e.x, e.y) else false),
        else => false,
    };
}

fn pointerCaptured(context: *const ui.Context, x: f32, y: f32) bool {
    if (context.open_popup != 0 or context.active != 0 or context.scroll_drag != null) return true;
    if (context.press) |press| if (press.widget != 0) return true;
    const root = context.last_root orelse return false;
    return hit_test.controlAt(root, x, y) != 0;
}

fn scrollableAt(element: *const ui.Layout.Element, x: f32, y: f32) bool {
    if (!element.bounds.intersection(element.clip).contains(x, y)) return false;
    if (element.scroll) |scroll| if (scroll.content.x > scroll.viewport.w or scroll.content.y > scroll.viewport.h) return true;
    for (element.children) |child| if (scrollableAt(child, x, y)) return true;
    return false;
}

pub fn isInput(event: sdl.events.Event) bool {
    return switch (event) {
        .key_down, .key_up, .text_input, .text_editing, .mouse_motion, .mouse_button_down, .mouse_button_up, .mouse_wheel => true,
        .gamepad_axis_motion, .gamepad_button_down, .gamepad_button_up, .finger_down, .finger_up, .finger_motion, .finger_canceled => true,
        else => false,
    };
}

pub fn isControllerInput(event: sdl.events.Event) bool {
    return event == .gamepad_axis_motion or event == .gamepad_button_down or event == .gamepad_button_up;
}
pub fn isTouchInput(event: sdl.events.Event) bool {
    return event == .finger_down or event == .finger_up or event == .finger_motion or event == .finger_canceled;
}
/// Game touch input uses real contacts, not a second mouse action synthesized by SDL.
pub fn syntheticTouchMouse(event: sdl.events.Event) bool {
    return adapter.fromTouch(event);
}

/// Translate window logical coordinates to game-viewport logical coordinates.
pub fn localEvent(event: sdl.events.Event, viewport: ui.Rect, window_points: [2]f32) sdl.events.Event {
    var result = event;
    switch (result) {
        .mouse_motion => |*e| {
            e.x -= viewport.x;
            e.y -= viewport.y;
        },
        .mouse_button_down, .mouse_button_up => |*e| {
            e.x -= viewport.x;
            e.y -= viewport.y;
        },
        .mouse_wheel => |*e| {
            e.x -= viewport.x;
            e.y -= viewport.y;
        },
        .finger_down, .finger_up, .finger_motion, .finger_canceled => |*e| {
            e.x = (e.x * window_points[0] - viewport.x) / viewport.w;
            e.y = (e.y * window_points[1] - viewport.y) / viewport.h;
            e.dx *= window_points[0] / viewport.w;
            e.dy *= window_points[1] / viewport.h;
        },
        else => {},
    }
    return result;
}

/// A logical rectangle in pixels of the actual target window, including pop-out DPI.
pub fn pixelRect(rect: ui.Rect, viewport: ui.Rect, extent_px: vit.Extent2D) ui.Rect {
    const sx = @as(f32, @floatFromInt(extent_px.width)) / viewport.w;
    const sy = @as(f32, @floatFromInt(extent_px.height)) / viewport.h;
    return .{ .x = (rect.x - viewport.x) * sx, .y = (rect.y - viewport.y) * sy, .w = rect.w * sx, .h = rect.h * sy };
}

test "labels do not capture gameplay, buttons and focus do" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    context.newFrame(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    context.label("HUD", .{});
    _ = try context.render();
    const down = sdl.events.Event{ .mouse_button_down = .{ .common = undefined, .button = .left, .down = true, .clicks = 1, .x = 200, .y = 200 } };
    try std.testing.expect(!captures(&context, down));
    context.handle(adapter.translate(down).?);
    var up = down.mouse_button_down;
    up.down = false;
    try std.testing.expect(!captures(&context, .{ .mouse_button_up = up }));
    context.handle(adapter.translate(.{ .mouse_button_up = up }).?);
    const key = sdl.events.Event{ .key_down = .{ .common = undefined, .id = null, .scancode = .space, .key = .space, .mod = .{}, .raw = 0, .down = true, .repeat = false } };
    try std.testing.expect(!captures(&context, key));
    context.newFrame(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    _ = context.button("Pause");
    _ = try context.render();
    try std.testing.expect(!captures(&context, key));
    context.focus = 1;
    try std.testing.expect(captures(&context, key));
    context.focus = 0;
    context.open_popup = 1;
    try std.testing.expect(pointerCaptured(&context, 500, 500));
}

test "viewport pixels use the actual window scale" {
    const pixels = pixelRect(.{ .x = 10, .y = 20, .w = 100, .h = 50 }, .{ .x = 0, .y = 0, .w = 400, .h = 300 }, .{ .width = 800, .height = 600 });
    try std.testing.expectEqual(ui.Rect{ .x = 20, .y = 40, .w = 200, .h = 100 }, pixels);
    std.testing.refAllDecls(Overlay);
}

test "UI owns touch drags but leaves other contacts to gameplay" {
    const gpa = std.testing.allocator;
    var overlay = Overlay{
        .gpa = gpa,
        .queue = undefined,
        .device = undefined,
        .color_format = undefined,
        .renderer = undefined,
        .context = try ui.Context.init(gpa),
    };
    defer overlay.context.deinit();
    defer overlay.touch_owners.deinit(gpa);
    overlay.context.newFrame(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    _ = overlay.context.button("Pause");
    _ = try overlay.context.render();
    var finger = sdl.events.TouchFinger{ .common = undefined, .id = .{ .value = 1 }, .finger_id = .{ .value = 2 }, .x = 0.1, .y = 0.1, .dx = 0, .dy = 0, .pressure = 1 };
    try std.testing.expect(overlay.handle(.{ .finger_down = finger }, true));
    finger.x = 2;
    try std.testing.expect(overlay.handle(.{ .finger_motion = finger }, true));
    var other = finger;
    other.finger_id.value = 3;
    try std.testing.expect(!overlay.handle(.{ .finger_down = other }, true));
    try std.testing.expect(overlay.handle(.{ .finger_up = finger }, true));
    try std.testing.expect(overlay.primary_touch == null);
    try std.testing.expectEqual(@as(usize, 0), overlay.touch_owners.count());
    const local = localEvent(.{ .finger_motion = .{ .common = undefined, .id = .{ .value = 1 }, .finger_id = .{ .value = 2 }, .x = 0.5, .y = 0.5, .dx = 0.1, .dy = 0.1, .pressure = 1 } }, .{ .x = 100, .y = 50, .w = 300, .h = 200 }, .{ 500, 300 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), local.finger_motion.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), local.finger_motion.y, 1e-6);
}
