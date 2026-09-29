const std = @import("std");
const vit = @import("vitellus");
const sdl_adapter = @import("vitellus_sdl3");
const ui = @import("weeoui");
const ui_demo = @import("ui_demo.zig");
const viewport3d = @import("viewport3d.zig");
const weeoui_vitellus = @import("weeoui_vitellus");
const weeoui_sdl3 = @import("weeoui_sdl3");

/// Vertex budget per frame; DevTools and the gallery together need well over 30k.
const max_vertices = 250_000;
const window_vertices = 120_000;
const sdl3 = sdl_adapter.sdl;

/// An OS window holding a popped-out dock panel: its own swapchain, UI renderer and 3D preview
/// on the shared device.
const PanelWindow = struct {
    window: sdl_adapter.Sdl3Window,
    id: sdl3.video.WindowId,
    swapchain: vit.Swapchain,
    commands: vit.CommandPool,
    renderer: weeoui_vitellus.Renderer,
    preview: viewport3d.Preview,
    extent: vit.Extent2D,
    format: vit.Format,
    vertices: []ui.Vertex,
    title: [64:0]u8 = @splat(0),
};
pub const Graphics = struct {
    allocator: std.mem.Allocator,
    viewport: ui.Rect,
    instance: vit.Instance,
    adapter: vit.Adapter,
    device: vit.Device,
    queue: vit.Queue,
    swapchain: vit.Swapchain,
    commands: vit.CommandPool,
    color_format: vit.Format,
    window_extent: vit.Extent2D,
    ui_renderer: weeoui_vitellus.Renderer,
    preview: viewport3d.Preview,
    theme: ui.Theme = .{},
    system_theme: ui.Theme = .{},
    /// On the heap: Demo is large, and Debug builds keep several copies of anything returned
    /// by value on the stack.
    demo: *ui_demo.Demo,
    font: ui.Font,
    vertex_data: []ui.Vertex,
    /// OS windows of popped-out dock panels, by dock window index.
    windows: [ui.dock.max_windows]?*PanelWindow = @splat(null),
    main_window: sdl3.video.Window,
    /// Title bar geometry for the OS hit test: slot 0 the main window, i + 1 panel window i.
    /// On the heap because SDL keeps pointers to them.
    frames: *[ui.dock.max_windows + 1]weeoui_sdl3.Frame,

    pub fn init(allocator: std.mem.Allocator, window: sdl_adapter.Sdl3Window) !@This() {
        const instance = try vit.Instance.init(allocator, .{ .backend = .{ .vulkan = true }, .validation = .core });
        errdefer instance.deinit();
        const adapter = try vit.Adapter.init(instance, .{ .label = "vitellus adapter" });
        errdefer adapter.deinit();
        const device = try vit.Device.init(adapter, .{ .label = "vitellus device" });
        errdefer device.deinit();
        const queue = try vit.Queue.init(device, .{ .label = "graphics queue", .kind = .graphics });
        errdefer queue.deinit();
        const commands = try vit.CommandPool.init(device, .{ .kind = .graphics });
        errdefer commands.deinit();
        const caps = try adapter.surfaceCapabilities(instance.allocator, try window.asWindow());
        defer caps.deinit();
        if (caps.formats.len == 0 or caps.present_modes.len == 0 or caps.composite_alpha.len == 0) return error.NoSurfaceCapabilities;
        const size = try window.window.getSizeInPixels();
        const logical = try window.window.getSize();
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = @floatFromInt(logical.@"0"), .h = @floatFromInt(logical.@"1") };
        const extent = vit.Extent2D{ .width = @intCast(size.@"0"), .height = @intCast(size.@"1") };
        const swapchain = try vit.Swapchain.init(adapter, .{
            .label = "swapchain",
            .window = try window.asWindow(),
            .queue = queue,
            .extent = extent,
            .format = caps.formats[0],
            .present_mode = pickPresentMode(caps.present_modes),
            .image_count = 2,
            .composite_alpha = caps.composite_alpha[0],
        });
        errdefer swapchain.deinit();
        var font = try ui.Font.init(allocator, ui.default_font);
        errdefer font.deinit();
        if (!font.loadSystemEmoji(std.Io.Threaded.global_single_threaded.io())) std.log.info("No color emoji font found; emoji draw as '?'", .{});
        if (viewport.w > 0) font.dpi_scale = @as(f32, @floatFromInt(extent.width)) / viewport.w;
        var ui_renderer = try weeoui_vitellus.Renderer.init(device, colorFormat(caps.formats[0]), &font);
        errdefer ui_renderer.deinit();
        var preview = try viewport3d.Preview.init(device, colorFormat(caps.formats[0]), extent);
        errdefer preview.deinit();
        const vertex_data = try allocator.alloc(ui.Vertex, max_vertices);
        errdefer allocator.free(vertex_data);
        const demo = try allocator.create(ui_demo.Demo);
        errdefer allocator.destroy(demo);
        demo.* = .{ .docked = true, .custom_frame = true };
        demo.frame_layout = weeoui_sdl3.buttonLayout(allocator, std.Io.Threaded.global_single_threaded.io());
        demo.dock.buttons = demo.frame_layout;
        const frames = try allocator.create([ui.dock.max_windows + 1]weeoui_sdl3.Frame);
        errdefer allocator.destroy(frames);
        frames.* = @splat(.{});
        weeoui_sdl3.useCustomFrame(window.window, &frames[0]) catch |err| {
            // Keep the OS frame if the desktop won't let us draw our own.
            std.log.warn("Custom title bar unavailable: {s}", .{@errorName(err)});
            demo.custom_frame = false;
        };
        var result: @This() = .{ .main_window = window.window, .frames = frames, .demo = demo, .vertex_data = vertex_data, .allocator = allocator, .viewport = viewport, .instance = instance, .adapter = adapter, .device = device, .queue = queue, .swapchain = swapchain, .commands = commands, .color_format = colorFormat(caps.formats[0]), .window_extent = extent, .ui_renderer = ui_renderer, .preview = preview, .font = font };
        try result.demo.relayout(allocator, viewport, &result.font);
        return result;
    }

    pub fn syncSize(self: *@This(), window: sdl_adapter.Sdl3Window) !void {
        const pixels = try window.window.getSizeInPixels();
        const logical = try window.window.getSize();
        if (pixels.@"0" == 0 or pixels.@"1" == 0 or logical.@"0" == 0 or logical.@"1" == 0) return;
        const requested = vit.Extent2D{ .width = @intCast(pixels.@"0"), .height = @intCast(pixels.@"1") };
        if (requested.width != self.window_extent.width or requested.height != self.window_extent.height) {
            try self.queue.waitIdle();
            try self.preview.resize(self.device, requested);
            try self.swapchain.resize(requested);
            self.window_extent = requested;
        }
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = @as(f32, @floatFromInt(logical.@"0")) / self.demo.ui_scale, .h = @as(f32, @floatFromInt(logical.@"1")) / self.demo.ui_scale };
        const dpi_scale = @as(f32, @floatFromInt(requested.width)) / viewport.w;
        if (viewport.w != self.viewport.w or viewport.h != self.viewport.h or dpi_scale != self.font.dpi_scale) {
            self.viewport = viewport;
            self.font.dpi_scale = dpi_scale;
            try self.relayoutDemo();
            self.demo.scroll.ensureVisible(self.demo.controls[self.demo.focus]);
            try self.relayoutDemo();
        }
    }

    pub fn relayoutDemo(self: *@This()) !void {
        try self.demo.relayout(self.allocator, self.viewport, &self.font);
    }

    pub fn deinit(self: *@This()) void {
        self.queue.waitIdle() catch {};
        for (&self.windows) |*slot| if (slot.*) |w| {
            self.closeWindow(w);
            slot.* = null;
        };
        self.preview.deinit();
        self.ui_renderer.deinit();
        self.font.deinit();
        self.demo.deinit();
        self.allocator.destroy(self.demo);
        self.allocator.destroy(self.frames);
        self.allocator.free(self.vertex_data);
        self.swapchain.deinit();
        self.commands.deinit();
        self.queue.deinit();
        self.device.deinit();
        self.adapter.deinit();
        self.instance.deinit();
    }

    /// Which panel window (if any) owns SDL window `id`, and where its slice of the demo's
    /// coordinate space starts.
    pub fn windowFor(self: *const @This(), id: sdl3.video.WindowId) ?usize {
        for (self.windows, 0..) |w, i| if (w) |window| if (window.id == id) return i;
        return null;
    }

    fn openWindow(self: *@This(), index: usize, size: [2]f32) !*PanelWindow {
        const w = try self.allocator.create(PanelWindow);
        errdefer self.allocator.destroy(w);
        w.* = undefined;
        w.title = @splat(0);
        const root = self.demo.dock.windows[index].?.root;
        const node = self.demo.dock.nodes[root];
        const name = if (node.count > 0) ui_demo.panelTitle(node.panels[node.active]) else "Panel";
        const title = std.fmt.bufPrintZ(&w.title, "{s} - eggy", .{name}) catch "eggy";
        var sdl_window = sdl_adapter.Sdl3Window.init(try sdl3.video.Window.init(title, @intFromFloat(size[0]), @intFromFloat(size[1]), .{ .vulkan = true, .resizable = true, .high_pixel_density = true }));
        errdefer sdl_window.deinit();
        const caps = try self.adapter.surfaceCapabilities(self.instance.allocator, try sdl_window.asWindow());
        defer caps.deinit();
        if (caps.formats.len == 0 or caps.present_modes.len == 0 or caps.composite_alpha.len == 0) return error.NoSurfaceCapabilities;
        const pixels = try sdl_window.window.getSizeInPixels();
        const extent = vit.Extent2D{ .width = @intCast(@max(1, pixels.@"0")), .height = @intCast(@max(1, pixels.@"1")) };
        const swapchain = try vit.Swapchain.init(self.adapter, .{
            .label = "panel swapchain",
            .window = try sdl_window.asWindow(),
            .queue = self.queue,
            .extent = extent,
            .format = caps.formats[0],
            .present_mode = pickPresentMode(caps.present_modes),
            .image_count = 2,
            .composite_alpha = caps.composite_alpha[0],
        });
        errdefer swapchain.deinit();
        const format = colorFormat(caps.formats[0]);
        const commands = try vit.CommandPool.init(self.device, .{ .kind = .graphics });
        errdefer commands.deinit();
        var renderer = try weeoui_vitellus.Renderer.init(self.device, format, &self.font);
        errdefer renderer.deinit();
        var preview = try viewport3d.Preview.init(self.device, format, extent);
        errdefer preview.deinit();
        const vertices = try self.allocator.alloc(ui.Vertex, window_vertices);
        if (self.demo.custom_frame) weeoui_sdl3.useCustomFrame(sdl_window.window, &self.frames[index + 1]) catch {};
        w.window = sdl_window;
        w.id = try sdl_window.window.getId();
        w.swapchain = swapchain;
        w.commands = commands;
        w.renderer = renderer;
        w.preview = preview;
        w.extent = extent;
        w.format = format;
        w.vertices = vertices;
        return w;
    }

    fn closeWindow(self: *@This(), w: *PanelWindow) void {
        self.queue.waitIdle() catch {};
        self.allocator.free(w.vertices);
        w.preview.deinit();
        w.renderer.deinit();
        w.commands.deinit();
        w.swapchain.deinit();
        w.window.deinit();
        self.allocator.destroy(w);
    }

    /// Open and close OS windows to match the dock's popped-out panels, and record their sizes.
    fn syncWindows(self: *@This()) !void {
        const demo = self.demo;
        for (&self.windows, 0..) |*slot, i| {
            const wanted = demo.dock.windows[i];
            if (wanted == null) {
                if (slot.*) |w| {
                    self.closeWindow(w);
                    slot.* = null;
                }
                demo.window_sizes[i] = null;
                continue;
            }
            if (slot.* == null) slot.* = self.openWindow(i, wanted.?.size) catch |err| {
                std.log.err("Cannot open a window for the panel: {s}", .{@errorName(err)});
                demo.dock.redock(.{ .window = @intCast(i) });
                continue;
            };
            const w = slot.*.?;
            const logical = try w.window.window.getSize();
            const pixels = try w.window.window.getSizeInPixels();
            if (logical.@"0" == 0 or logical.@"1" == 0 or pixels.@"0" == 0 or pixels.@"1" == 0) {
                demo.window_sizes[i] = null; // minimized
                continue;
            }
            const extent = vit.Extent2D{ .width = @intCast(pixels.@"0"), .height = @intCast(pixels.@"1") };
            if (extent.width != w.extent.width or extent.height != w.extent.height) {
                try self.queue.waitIdle();
                try w.swapchain.resize(extent);
                try w.preview.resize(self.device, extent);
                w.extent = extent;
            }
            demo.window_sizes[i] = .{ @as(f32, @floatFromInt(logical.@"0")) / demo.ui_scale, @as(f32, @floatFromInt(logical.@"1")) / demo.ui_scale };
        }
    }

    /// Hand the title bar layout to the OS hit test and read back each window's state.
    fn syncFrames(self: *@This()) void {
        const scale = 1 / self.demo.ui_scale;
        for (self.frames, self.demo.frames, 0..) |*target, rects, slot| {
            target.* = .{ .bar = rects.bar, .buttons = rects.buttons, .button_count = rects.count, .scale = scale };
            const window = if (slot == 0) self.main_window else if (self.windows[slot - 1]) |w| w.window.window else continue;
            const flags = window.getFlags();
            self.demo.window_state[slot] = .{ .maximized = flags.maximized, .focused = flags.input_focus };
        }
    }

    pub fn frame(self: *@This()) !void {
        try self.syncWindows();
        self.theme = switch (self.demo.appearance) {
            .system => self.system_theme,
            .light => .{},
            .dark => ui.Theme.dark,
        };
        if (self.demo.custom_accent) {
            const accent = self.demo.color.rgb();
            self.theme.primary = accent;
            self.theme.primary_foreground = ui.onColor(accent);
            self.theme.ring = accent;
        }
        const info = self.swapchain.info();
        const vertex_data = self.vertex_data;
        var canvas = ui.Canvas.init(vertex_data, &self.font);
        canvas.theme = self.theme;
        canvas.srgb_target = weeoui_vitellus.isSrgb(self.color_format);
        canvas.pixel_scale = .{ @as(f32, @floatFromInt(info.extent.width)) / self.viewport.w, @as(f32, @floatFromInt(info.extent.height)) / self.viewport.h };
        var canvases: [ui.dock.max_windows]ui.Canvas = undefined;
        var targets: [ui.dock.max_windows]ui_demo.Demo.WindowTarget = undefined;
        var target_count: usize = 0;
        for (self.windows, 0..) |slot, i| if (slot) |w| if (self.demo.window_sizes[i]) |size| {
            canvases[target_count] = ui.Canvas.init(w.vertices, &self.font);
            const c = &canvases[target_count];
            c.theme = self.theme;
            c.srgb_target = weeoui_vitellus.isSrgb(w.format);
            c.pixel_scale = .{ @as(f32, @floatFromInt(w.extent.width)) / size[0], @as(f32, @floatFromInt(w.extent.height)) / size[1] };
            targets[target_count] = .{ .index = @intCast(i), .canvas = c };
            target_count += 1;
        };
        const base_vertices = try self.demo.drawWindows(self.allocator, &canvas, self.viewport, targets[0..target_count]);
        self.syncFrames();
        try self.commands.reset();
        const acquired = try self.swapchain.acquireNextImage(null);
        const cmd = try vit.CommandBuffer.init(self.commands, .{});
        defer cmd.deinit();
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .present, .after = .color_attachment } }});
        try self.ui_renderer.upload(cmd, &self.font, vertex_data[0..canvas.len], self.viewport);
        try cmd.beginRenderPass(.{ .color_attachments = &.{.{
            .view = acquired.view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{
                .r = if (canvas.srgb_target) ui.linearChannel(self.theme.background[0]) else self.theme.background[0],
                .g = if (canvas.srgb_target) ui.linearChannel(self.theme.background[1]) else self.theme.background[1],
                .b = if (canvas.srgb_target) ui.linearChannel(self.theme.background[2]) else self.theme.background[2],
                .a = 1,
            },
        }} });
        self.ui_renderer.draw(cmd, info.extent, 0, base_vertices);
        cmd.endRenderPass();
        try self.preview.draw(cmd, acquired.view, self.demo.scene_viewport, self.demo.scene_clip, self.viewport, info.extent, canvas.srgb_target);
        if (canvas.len > base_vertices) {
            try cmd.beginRenderPass(.{ .color_attachments = &.{.{ .view = acquired.view, .load_op = .load, .store_op = .store }} });
            self.ui_renderer.draw(cmd, info.extent, base_vertices, canvas.len - base_vertices);
            cmd.endRenderPass();
        }
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .color_attachment, .after = .present } }});
        try cmd.finish();
        try self.queue.submit(.{ .command_buffers = &.{cmd} });
        _ = try self.swapchain.present(&.{});
        for (targets[0..target_count]) |target| try self.presentWindow(self.windows[target.index].?, target);
    }

    /// Draw one popped-out panel window: UI, then the 3D scene if the Scene panel lives there.
    fn presentWindow(self: *@This(), w: *PanelWindow, target: ui_demo.Demo.WindowTarget) !void {
        const c = target.canvas;
        const size = self.demo.window_sizes[target.index].?;
        const origin = ui_demo.windowOrigin(target.index);
        const viewport = ui.Rect{ .x = origin, .y = 0, .w = size[0], .h = size[1] };
        // ponytail: waits for the GPU so this window's single vertex buffer and pool are free; add frames in flight if many windows stutter.
        try self.queue.waitIdle();
        try w.commands.reset();
        const acquired = try w.swapchain.acquireNextImage(null);
        const cmd = try vit.CommandBuffer.init(w.commands, .{});
        defer cmd.deinit();
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .present, .after = .color_attachment } }});
        try w.renderer.upload(cmd, &self.font, w.vertices[0..c.len], viewport);
        const bg = self.theme.background;
        try cmd.beginRenderPass(.{ .color_attachments = &.{.{
            .view = acquired.view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{
                .r = if (c.srgb_target) ui.linearChannel(bg[0]) else bg[0],
                .g = if (c.srgb_target) ui.linearChannel(bg[1]) else bg[1],
                .b = if (c.srgb_target) ui.linearChannel(bg[2]) else bg[2],
                .a = 1,
            },
        }} });
        w.renderer.draw(cmd, w.extent, 0, target.base);
        cmd.endRenderPass();
        const scene = self.demo.scene_viewport;
        if (scene.x >= origin and scene.x < origin + ui_demo.window_stride) {
            // The scene lives in this window: draw it in the window's own coordinates.
            const shift = struct {
                fn f(r: ui.Rect, dx: f32) ui.Rect {
                    return .{ .x = r.x - dx, .y = r.y, .w = r.w, .h = r.h };
                }
            }.f;
            try w.preview.draw(cmd, acquired.view, shift(scene, origin), shift(self.demo.scene_clip, origin), .{ .x = 0, .y = 0, .w = size[0], .h = size[1] }, w.extent, c.srgb_target);
        }
        if (c.len > target.base) {
            try cmd.beginRenderPass(.{ .color_attachments = &.{.{ .view = acquired.view, .load_op = .load, .store_op = .store }} });
            w.renderer.draw(cmd, w.extent, target.base, c.len - target.base);
            cmd.endRenderPass();
        }
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .color_attachment, .after = .present } }});
        try cmd.finish();
        try self.queue.submit(.{ .command_buffers = &.{cmd} });
        _ = try w.swapchain.present(&.{});
    }
};

fn colorFormat(format: vit.SwapchainFormat) vit.Format {
    return switch (format) {
        .bgra8_unorm => .bgra8_unorm,
        .bgra8_unorm_srgb => .bgra8_unorm_srgb,
        .rgba8_unorm => .rgba8_unorm,
        .rgba8_unorm_srgb => .rgba8_unorm_srgb,
        .rgba16_float => .rgba16_float,
    };
}
fn pickPresentMode(modes: []const vit.PresentMode) vit.PresentMode {
    for (modes) |mode| if (mode == .mailbox) return mode;
    for (modes) |mode| if (mode == .immediate) return mode;
    return modes[0];
}
