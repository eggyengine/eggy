//! Customizable game UI drawn into an engine-owned frame or scene target.
const std = @import("std");
const vit = @import("vitellus");
const ui = @import("weeoui");
const adapter = @import("weeoui_sdl3");
const renderer = @import("weeoui_vitellus");
const sdl = @import("vitellus_sdl3").sdl;
const hit_test = @import("../ui_hit_test.zig");

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

    pub fn init(gpa: std.mem.Allocator, device: vit.Device, queue: vit.Queue, color_format: vit.Format) !Overlay {
        var context = try ui.Context.init(gpa);
        errdefer context.deinit();
        const painter = try renderer.Renderer.init(device, color_format, context.font);
        return .{ .gpa = gpa, .queue = queue, .device = device, .color_format = color_format, .context = context, .renderer = painter };
    }

    pub fn deinit(self: *Overlay) void {
        self.queue.waitIdle() catch |err| std.log.err("cannot finish game UI GPU work: {t}", .{err});
        self.renderer.deinit();
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
        return gained_keyboard;
    }

    /// Route an already viewport-local SDL event. Standalone UIs use the SDL accessibility
    /// adapter; embedded UIs leave the host window's accessibility adapter in charge.
    pub fn handle(self: *Overlay, event: sdl.events.Event, embedded: bool) bool {
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

    /// Clear transient capture without retaining references into a previous game frame.
    pub fn cancel(self: *Overlay) void {
        self.pointer_active = false;
        self.keyboard_owned = false;
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
    if (context.open_popup != 0 or context.active != 0 or context.press != null or context.scroll_drag != null) return true;
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
        else => false,
    };
}

/// Translate window logical coordinates to game-viewport logical coordinates.
pub fn localEvent(event: sdl.events.Event, viewport: ui.Rect) sdl.events.Event {
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
