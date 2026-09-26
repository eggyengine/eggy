const std = @import("std");
const builtin = @import("builtin");
const sdl_adapter = @import("vitellus_sdl3");
const sdl3 = sdl_adapter.sdl;

const graphics = @import("graphics.zig");

const fps = 60;
const width = 640;
const height = 480;

pub const Game = struct {
    window: sdl_adapter.Sdl3Window,
    init_flags: sdl3.InitFlags,
    m_graphics: graphics.Graphics,
    fps_capper: sdl3.extras.FramerateCapper(f32),

    pub fn init(i: sdl3.Init) !Game {
        if (builtin.abi.isAndroid()) {
            try sdl3.hints.set(.orientations, "LandscapeLeft LandscapeRight");
        }

        const init_flags = sdl3.InitFlags{ .video = true };
        try sdl3.init(init_flags);
        errdefer sdl3.quit(init_flags);

        const window_w: usize = if (builtin.abi.isAndroid()) 1280 else width;
        const window_h: usize = if (builtin.abi.isAndroid()) 720 else height;
        const window: sdl_adapter.Sdl3Window = .init(try sdl3.video.Window.init("eggy", window_w, window_h, .{
            .vulkan = true,
            .resizable = true,
            .fullscreen = builtin.abi.isAndroid(),
        }));

        const m_graphics = try graphics.Graphics.init(i.gpa, window);

        return .{
            .window = window,
            .init_flags = init_flags,
            .m_graphics = m_graphics,
            .fps_capper = .{ .mode = .{ .limited = fps } },
        };
    }

    pub fn deinit(self: *Game) void {
        self.m_graphics.deinit();
        self.window.window.deinit();
        sdl3.quit(self.init_flags);
        sdl3.shutdown();
    }

    pub fn iterate(self: *Game) !sdl3.AppResult {
        try self.m_graphics.syncSize(self.window);
        const dt = self.fps_capper.delay();
        try self.m_graphics.frame(dt);
        return .run;
    }

    pub fn event(self: *Game, curr_event: sdl3.events.Event) !sdl3.AppResult {
        switch (curr_event) {
            .quit, .terminating => return .success,
            .window_resized, .window_pixel_size_changed, .window_display_scale_changed => {
                try self.m_graphics.syncSize(self.window);
            },
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
