//! The window and renderer every Eggy program opens.
const builtin = @import("builtin");
const std = @import("std");
const sdl_adapter = @import("vitellus_sdl3");
const sdl3 = sdl_adapter.sdl;
const Graphics = @import("graphics.zig").Graphics;

const web = builtin.os.tag == .emscripten;
const width = 900;
const height = 675;

/// Owns SDL, one window, and the `Graphics` that draws into it.
pub const App = struct {
    window: sdl_adapter.Sdl3Window,
    init_flags: sdl3.InitFlags,
    graphics: Graphics,

    pub fn init(gpa: std.mem.Allocator, title: [:0]const u8) !App {
        const init_flags = sdl3.InitFlags{ .video = true };
        try sdl3.init(init_flags);
        errdefer sdl3.quit(init_flags);

        // On Windows the window stays hidden until the renderer is ready.
        var window: sdl_adapter.Sdl3Window = .init(try sdl3.video.Window.init(title, width, height, .{
            .vulkan = !web,
            .resizable = true,
            .high_pixel_density = true,
            .hidden = builtin.os.tag == .windows,
        }));
        errdefer window.deinit();
        var graphics = try Graphics.init(gpa, window);
        errdefer graphics.deinit();
        if (builtin.os.tag == .windows) try window.window.show();

        return .{ .window = window, .init_flags = init_flags, .graphics = graphics };
    }

    pub fn deinit(self: *App) void {
        self.graphics.deinit();
        self.window.deinit();
        sdl3.quit(self.init_flags);
        sdl3.shutdown();
    }

    /// Window lifecycle every program shares: quit requests end the app (`.success`), and size
    /// or scale changes resize the swapchain.
    pub fn event(self: *App, curr_event: sdl3.events.Event) !sdl3.AppResult {
        switch (curr_event) {
            .quit, .terminating, .window_close_requested => return .success,
            .window_resized, .window_pixel_size_changed, .window_display_scale_changed => try self.graphics.syncSize(self.window),
            else => {},
        }
        return .run;
    }
};
