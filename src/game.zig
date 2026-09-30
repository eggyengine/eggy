const std = @import("std");
const sdl_adapter = @import("vitellus_sdl3");
const sdl3 = sdl_adapter.sdl;

const graphics = @import("graphics.zig");
const builtin = @import("builtin");

const fps = 340000;
const width = 900;
const height = 675;

pub const Game = struct {
    window: sdl_adapter.Sdl3Window,
    init_flags: sdl3.InitFlags,
    m_graphics: graphics.Graphics,
    fps_capper: sdl3.extras.FramerateCapper(f32),

    pub fn init(i: sdl3.Init) !Game {
        const init_flags = sdl3.InitFlags{ .video = true };
        try sdl3.init(init_flags);
        errdefer sdl3.quit(init_flags);

        var window: sdl_adapter.Sdl3Window = .init(try sdl3.video.Window.init("eggy", width, height, .{
            .vulkan = true,
            .resizable = true,
            .high_pixel_density = true,
            .hidden = builtin.os.tag == .windows,
        }));
        errdefer window.deinit();

        var m_graphics = try graphics.Graphics.init(i.gpa, window);
        errdefer m_graphics.deinit();
        if (builtin.os.tag == .windows) try window.window.show();

        return .{
            .window = window,
            .init_flags = init_flags,
            .m_graphics = m_graphics,
            .fps_capper = .{ .mode = .{ .limited = fps } },
        };
    }

    pub fn deinit(self: *Game) void {
        self.m_graphics.deinit();
        self.window.deinit();
        sdl3.quit(self.init_flags);
        sdl3.shutdown();
    }

    pub fn iterate(self: *Game) !sdl3.AppResult {
        try self.m_graphics.syncSize(self.window);
        _ = self.fps_capper.delay();
        try self.m_graphics.frame();
        return .run;
    }

    pub fn event(self: *Game, curr_event: sdl3.events.Event) !sdl3.AppResult {
        switch (curr_event) {
            .quit, .terminating, .window_close_requested => return .success,
            .window_resized, .window_pixel_size_changed, .window_display_scale_changed => try self.m_graphics.syncSize(self.window),
            else => {},
        }
        return .run;
    }

    pub fn run(self: *Game) !void {
        while (true) {
            while (sdl3.events.poll()) |curr_event| {
                switch (try self.event(curr_event)) {
                    .run => {},
                    .success, .failure => return,
                }
            }
            switch (try self.iterate()) {
                .run => {},
                .success, .failure => return,
            }
        }
    }
};
