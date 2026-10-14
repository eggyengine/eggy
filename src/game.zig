const std = @import("std");
const sdl_adapter = @import("vitellus_sdl3");
const sdl3 = sdl_adapter.sdl;

const Graphics = @import("graphics.zig").Graphics;
const builtin = @import("builtin");
const web = builtin.os.tag == .emscripten;

const fps = 340000;
const width = 900;
const height = 675;

pub const Game = struct {
    window: sdl_adapter.Sdl3Window,
    init_flags: sdl3.InitFlags,
    graphics: Graphics,
    fps_capper: sdl3.extras.FramerateCapper(f32),

    pub fn init(gpa: std.mem.Allocator) !Game {
        const init_flags = sdl3.InitFlags{ .video = true };
        try sdl3.init(init_flags);
        errdefer sdl3.quit(init_flags);

        var window: sdl_adapter.Sdl3Window = .init(try sdl3.video.Window.init("eggy", width, height, .{
            .vulkan = !web,
            .resizable = true,
            .high_pixel_density = true,
            .hidden = builtin.os.tag == .windows,
        }));
        errdefer window.deinit();

        var graphics = try Graphics.init(gpa, window);
        errdefer graphics.deinit();
        if (builtin.os.tag == .windows) try window.window.show();

        return .{
            .window = window,
            .init_flags = init_flags,
            .graphics = graphics,
            .fps_capper = .{ .mode = .{ .limited = fps } },
        };
    }

    pub fn deinit(self: *Game) void {
        self.graphics.deinit();
        self.window.deinit();
        sdl3.quit(self.init_flags);
        sdl3.shutdown();
    }

    pub fn iterate(self: *Game) !sdl3.AppResult {
        try self.graphics.syncSize(self.window);
        // The browser already paces frames to the display.
        if (!web) _ = self.fps_capper.delay();
        try self.graphics.frame();
        return .run;
    }

    pub fn event(self: *Game, curr_event: sdl3.events.Event) !sdl3.AppResult {
        switch (curr_event) {
            .quit, .terminating, .window_close_requested => return .success,
            .window_resized, .window_pixel_size_changed, .window_display_scale_changed => try self.graphics.syncSize(self.window),
            else => {},
        }
        return .run;
    }
};
