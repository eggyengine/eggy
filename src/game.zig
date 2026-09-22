const std = @import("std");
const builtin = @import("builtin");
const vit = @import("vitellus");
const sdl3 = vit.windowing.sdl3.sdl;

const graphics = @import("graphics.zig");

const fps = 60;
const width = 640;
const height = 480;

pub const Game = struct {
    window: vit.windowing.sdl3.Sdl3Window,
    init_flags: sdl3.InitFlags,
    m_graphics: graphics.Graphics,
    fps_capper: sdl3.extras.FramerateCapper(f32),

    pub fn init(i: sdl3.Init) !Game {
        const init_flags = sdl3.InitFlags{ .video = true };
        try sdl3.init(init_flags);
        errdefer sdl3.quit(init_flags);

        const window: vit.windowing.sdl3.Sdl3Window = .init(try sdl3.video.Window.init("eggy", width, height, .{
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
        const dt = self.fps_capper.delay();
        try self.m_graphics.frame(dt);
        return .run;
    }

    pub fn event(self: *Game, curr_event: sdl3.events.Event) !sdl3.AppResult {
        switch (curr_event) {
            .quit, .terminating => return .success,
            .window_resized => try self.m_graphics.onResize(self.window),
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
