const std = @import("std");
const vit = @import("vitellus");
const sdl3 = vit.windowing.sdl3.sdl; // easier to re-export the type than to deal wtih c files

const graphics = @import("graphics.zig");

const fps = 60;
const width = 640;
const height = 480;

pub var quit = false;

pub const Game = struct {
    window: vit.windowing.sdl3.Sdl3Window,
    init_flags: sdl3.InitFlags,

    m_graphics: graphics.Graphics,

    pub fn init(i: std.process.Init) !Game {
        const init_flags = sdl3.InitFlags{ .video = true };
        try sdl3.init(init_flags);
        errdefer sdl3.quit(init_flags);

        const window: vit.windowing.sdl3.Sdl3Window = .init(try sdl3.video.Window.init("a bullshit rpg game", width, height, .{
            .vulkan = true,
            .resizable = true,
        }));

        const m_graphics = try graphics.Graphics.init(i, window);

        return .{
            .window = window,
            .init_flags = init_flags,
            .m_graphics = m_graphics,
        };
    }

    pub fn deinit(self: *Game) void {
        self.m_graphics.deinit();
        self.window.window.deinit();
        sdl3.quit(self.init_flags);
        sdl3.shutdown();
    }

    pub fn run(self: *Game) !void {
        var capper = sdl3.extras.FramerateCapper(f32){ .mode = .{ .limited = fps } };
        while (!quit) {
            while (sdl3.events.poll()) |event| switch (event) {
                .quit, .terminating => quit = true,
                .window_resized => try self.m_graphics.onResize(self.window),
                else => {},
            };
            if (quit) break;

            _ = capper.delay();
            try self.m_graphics.frame();
        }
    }
};
