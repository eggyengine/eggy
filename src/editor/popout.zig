//! A dock panel popped out into its own OS window: the window, its swapchain, and the renderer
//! that draws the editor's UI into it.
const std = @import("std");
const eggy = @import("eggy");
const sdl_adapter = eggy.sdl_adapter;
const sdl3 = sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_vitellus = @import("weeoui_vitellus");

pub const PopOut = struct {
    window: sdl_adapter.Sdl3Window,
    id: sdl3.video.WindowId,
    surface: eggy.Surface,
    overlay: weeoui_vitellus.Renderer,

    /// Open a `size` (in points) window titled `title`, rendering in `graphics`' color format.
    /// `flags` are SDL's (Vulkan and high pixel density are always on).
    /// Editor-host only: clamps size to at least 160×120 points. Borrowed graphics/font
    /// must outlive the returned caller-owned value; SDL/surface/renderer errors propagate.
    ///
    /// ```zig
    /// var popout = try PopOut.open(graphics, font, "Inspector", .{ 360, 600 }, .{ .resizable = true });
    /// defer popout.close(graphics);
    /// ```
    pub fn open(graphics: *const eggy.Graphics, font: *const ui.Font, title: [:0]const u8, size: [2]f32, flags: sdl3.video.Window.Flags) !PopOut {
        const width: usize = @intFromFloat(@max(160, size[0]));
        const height: usize = @intFromFloat(@max(120, size[1]));
        var window_flags = flags;
        window_flags.vulkan = true;
        window_flags.high_pixel_density = true;
        var window: sdl_adapter.Sdl3Window = .init(try sdl3.video.Window.init(title, width, height, window_flags));
        errdefer window.deinit();
        var surface = try graphics.addSurface(window);
        errdefer surface.deinit();
        const overlay = try weeoui_vitellus.Renderer.init(graphics.device, graphics.color_format, font);
        return .{ .window = window, .id = try window.window.getId(), .surface = surface, .overlay = overlay };
    }

    /// Close the window once the GPU is done with everything that drew into it.
    /// Waits the original graphics queue idle (ignoring wait failure), destroys owned GPU/SDL
    /// state, but not the struct or font. Do not use the value afterward.
    ///
    /// ```zig
    /// popout.close(graphics); // Before shared font/device teardown.
    /// ```
    pub fn close(self: *PopOut, graphics: *eggy.Graphics) void {
        graphics.queue.waitIdle() catch {};
        self.overlay.deinit();
        self.surface.deinit();
        self.window.deinit();
    }

    /// The window's area in points, where its pointer events are; null for zero width/height.
    /// Returns origin-zero logical geometry, not pixel dimensions; SDL query errors propagate.
    ///
    /// ```zig
    /// const area = try popout.viewport() orelse return;
    /// context.newFrame(area);
    /// ```
    pub fn viewport(self: *const PopOut) !?ui.Rect {
        const width, const height = try self.window.window.getSize();
        if (width == 0 or height == 0) return null;
        return .{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) };
    }
};
