const sdl_adapter = @import("vitellus_sdl3");
const sdl3 = sdl_adapter.sdl;

const graphics = @import("graphics.zig");

const fps = 60;
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

        const window: sdl_adapter.Sdl3Window = .init(try sdl3.video.Window.init("eggy", width, height, .{
            .vulkan = true,
            .resizable = true,
            .high_pixel_density = true,
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
        self.window.deinit();
        sdl3.quit(self.init_flags);
        sdl3.shutdown();
    }

    pub fn iterate(self: *Game) !sdl3.AppResult {
        try self.m_graphics.syncSize(self.window);
        const dt = self.fps_capper.delay();
        _ = dt;
        try self.m_graphics.frame();
        return .run;
    }

    pub fn event(self: *Game, curr_event: sdl3.events.Event) !sdl3.AppResult {
        switch (curr_event) {
            .quit, .terminating => return .success,
            .window_resized, .window_pixel_size_changed, .window_display_scale_changed => {
                try self.m_graphics.syncSize(self.window);
            },
            .mouse_motion => |motion| {
                const scale = self.m_graphics.demo.ui_scale;
                self.m_graphics.demo.pointerMove(motion.x / scale, motion.y / scale);
                if (self.m_graphics.demo.dragging_slider) try self.m_graphics.syncSize(self.window) else if (self.m_graphics.demo.scroll.dragging != .none) try self.m_graphics.relayoutDemo();
            },
            .mouse_button_down => |button| {
                if (button.button == .left) {
                    const scale = self.m_graphics.demo.ui_scale;
                    self.m_graphics.demo.pointerDown(button.x / scale, button.y / scale);
                    try self.m_graphics.syncSize(self.window);
                    try self.m_graphics.relayoutDemo();
                }
            },
            .mouse_button_up => |button| if (button.button == .left) self.m_graphics.demo.pointerUp(),
            .mouse_wheel => |wheel| {
                self.m_graphics.demo.scroll.wheel(wheel.scroll_x, wheel.scroll_y);
                try self.m_graphics.relayoutDemo();
            },
            .key_down => |key| {
                if (!key.repeat) if (key.key) |code| {
                    switch (code) {
                        .tab => self.m_graphics.demo.next(),
                        .left => self.m_graphics.demo.nudgeScale(-1),
                        .right => self.m_graphics.demo.nudgeScale(1),
                        .space, .return_key, .kp_enter => self.m_graphics.demo.activate(),
                        .page_down => self.m_graphics.demo.scroll.wheel(0, -self.m_graphics.viewport.h / 40),
                        .page_up => self.m_graphics.demo.scroll.wheel(0, self.m_graphics.viewport.h / 40),
                        .home => self.m_graphics.demo.scroll.offset.y = 0,
                        .end => self.m_graphics.demo.scroll.offset.y = self.m_graphics.demo.scroll.content.y,
                        else => {},
                    }
                    try self.m_graphics.syncSize(self.window);
                    try self.m_graphics.relayoutDemo();
                };
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
