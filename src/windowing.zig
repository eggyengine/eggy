pub const sdl = @import("sdl3");
const eggy = @import("eggy.zig");
const input = @import("input.zig");
const std = @import("std");

pub const WindowingModuleOptions = struct {
    init_flags: sdl.InitFlags = .{
        .video = true,
        .gamepad = true,
    },
    title: [:0]const u8 = "eggyengine app",
    size: eggy.math.Vec2 = .{ .x = 800, .y = 600 },
    window_flags: WindowFlags = .{
        .resizable = true,
    },
    frame_rate: FrameRateMode = .unlimited,
};

pub const WindowResizedEvent = struct {
    width: u32,
    height: u32,
};

pub fn WindowingModule(comptime options: WindowingModuleOptions, comptime sdl_backend: eggy.module.rendering.SdlBackend) type {
    const FramerateCapper = sdl.extras.FramerateCapper(f32);

    return struct {
        window: sdl.video.Window = undefined,
        fps_capper: FramerateCapper = .{
            .mode = switch (options.frame_rate) {
                .unlimited => .unlimited,
                .limited => |fps| .{ .limited = fps },
            },
        },

        pub const schedules = .{
            .init = &.{init},
            .pre_update = &.{pollEvents},
            .post_render = &.{tickFramerate},
            .deinit = &.{deinit},
        };

        fn init(self: *@This(), ctx: *eggy.Context) !void {
            const init_flags = sdl.InitFlags{
                .video = true,
            };
            try sdl.init(init_flags);
            std.log.debug("SDL initialised", .{});

            const window = try sdl.video.Window.init(options.title, options.size.x, options.size.y, .{
                .fullscreen = options.window_flags.fullscreen,
                .occluded = options.window_flags.occluded,
                .hidden = options.window_flags.hidden,
                .borderless = options.window_flags.borderless,
                .resizable = options.window_flags.resizable,
                .minimized = options.window_flags.minimized,
                .maximized = options.window_flags.maximized,
                .mouse_grabbed = options.window_flags.mouse_grabbed,
                .input_focus = options.window_flags.input_focus,
                .mouse_focus = options.window_flags.mouse_focus,
                .external = options.window_flags.external,
                .modal = options.window_flags.modal,
                .high_pixel_density = options.window_flags.high_pixel_density,
                .mouse_capture = options.window_flags.mouse_capture,
                .mouse_relative_mode = options.window_flags.mouse_relative_mode,
                .always_on_top = options.window_flags.always_on_top,
                .utility = options.window_flags.utility,
                .tooltip = options.window_flags.tooltip,
                .popup_menu = options.window_flags.popup_menu,
                .keyboard_grabbed = options.window_flags.keyboard_grabbed,
                .transparent = options.window_flags.transparent,
                .not_focusable = options.window_flags.not_focusable,
                .vulkan = sdl_backend == .vulkan,
                .open_gl = sdl_backend == .opengl,
            });
            self.window = window;
            try ctx.world.insertResource(window);
            std.log.debug("Window initialised", .{});
        }

        fn deinit(this: *@This(), _: *eggy.Context) void {
            // since defer is done in reverse order, might as well add defer to make it more accurate.
            defer sdl.quit(options.init_flags);
            defer this.window.deinit();
        }

        fn pollEvents(self: *@This(), ctx: *eggy.Context) !void {
            if (ctx.world.getResource(eggy.ecs.Events(WindowResizedEvent))) |events| {
                events.drain();
            }

            // non-gpu backends cannot use the standard `Window.updateSurface` function otherwise it crashes the app
            if (sdl_backend != .vulkan and sdl_backend != .opengl) {
                _ = try self.window.getSurface();
                try self.window.updateSurface();
            }

            const keyboard = ctx.world.getResource(input.KeyboardInput);
            const mouse = ctx.world.getResource(input.MouseInput);
            const gamepad = ctx.world.getResource(input.GamepadInput);

            while (sdl.events.poll()) |event| {
                switch (event) {
                    .quit, .terminating => {
                        ctx.quit();
                    },

                    .window_resized => |wev| {
                        try ctx.world.insertResource(eggy.ecs.Events(WindowResizedEvent).init(ctx.proc_init.gpa));
                        if (ctx.world.getResource(eggy.ecs.Events(WindowResizedEvent))) |events| {
                            events.send(.{ .width = @intCast(wev.width), .height = @intCast(wev.height) });
                        }
                    },

                    .key_down => |kev| {
                        if (keyboard) |kb| {
                            if (kev.scancode) |sca| {
                                kb.onKeyDown(sca);
                            }
                        }
                    },
                    .key_up => |kev| {
                        if (keyboard) |kb| {
                            if (kev.scancode) |sca| {
                                kb.onKeyUp(sca);
                            }
                        }
                    },

                    .mouse_motion => |mev| {
                        if (mouse) |m| {
                            m.onMotion(mev.x, mev.y, mev.x_rel, mev.y_rel);
                        }
                    },
                    .mouse_button_down => |mev| {
                        if (mouse) |m| {
                            if (sdlMouseButtonToEnum(mev.button)) |btn| {
                                m.onButtonDown(btn);
                            }
                        }
                    },
                    .mouse_button_up => |mev| {
                        if (mouse) |m| {
                            if (sdlMouseButtonToEnum(mev.button)) |btn| {
                                m.onButtonUp(btn);
                            }
                        }
                    },
                    .mouse_wheel => |wev| {
                        if (mouse) |m| {
                            m.onScroll(wev.x, wev.y);
                        }
                    },

                    .gamepad_added => |gev| {
                        if (gamepad) |gp| {
                            gp.onConnected(gev.id);
                        }
                    },
                    .gamepad_removed => |gev| {
                        if (gamepad) |gp| {
                            gp.onDisconnected(gev.id);
                        }
                    },
                    .gamepad_button_down => |gev| {
                        if (gamepad) |gp| {
                            if (gp.getGamepad(gev.id)) |state| {
                                state.onButtonDown(sdlGamepadButtonToEnum(gev.button));
                            }
                        }
                    },
                    .gamepad_button_up => |gev| {
                        if (gamepad) |gp| {
                            if (gp.getGamepad(gev.id)) |state| {
                                state.onButtonUp(sdlGamepadButtonToEnum(gev.button));
                            }
                        }
                    },
                    .gamepad_axis_motion => |gev| {
                        if (gamepad) |gp| {
                            if (gp.getGamepad(gev.id)) |state| {
                                // convert from i16 (-32768 to 32767) to f32 (-1.0 to 1.0)
                                const value: f32 = @as(f32, @floatFromInt(gev.value)) / 32767.0;
                                state.onAxisMotion(sdlGamepadAxisToEnum(gev.axis), value);
                            }
                        }
                    },

                    else => {},
                }
            }
        }

        fn tickFramerate(self: *@This(), _: *eggy.Context) void {
            _ = self.fps_capper.delay();
        }
    };
}

pub const FrameRateMode = union(enum) {
    /// No frame rate limiting
    unlimited,
    /// Limit to specific FPS
    limited: f32,
};

pub const WindowFlags = struct {
    /// Window is in fullscreen mode.
    fullscreen: bool = false,
    /// Window is occluded.
    occluded: bool = false,
    /// Window is neither mapped onto the desktop nor shown in the taskbar/dock/window list.
    /// The `video.Window.show()` function must be called for the window.
    hidden: bool = false,
    /// No window decoration.
    borderless: bool = false,
    /// Window can be resized.
    resizable: bool = false,
    /// Window is minimized.
    minimized: bool = false,
    /// Window is maximized.
    maximized: bool = false,
    /// Window has grabbed mouse input.
    mouse_grabbed: bool = false,
    /// Window has input focus.
    input_focus: bool = false,
    /// Window has mouse focus.
    mouse_focus: bool = false,
    /// Window not created by SDL.
    external: bool = false,
    /// Window is modal.
    modal: bool = false,
    /// Window uses high pixel density back buffer if possible.
    high_pixel_density: bool = false,
    /// Window has mouse captured (unrelated to `video.Window.Flags.mouse_grabbed`)
    mouse_capture: bool = false,
    /// Window has relative mode enabled.
    mouse_relative_mode: bool = false,
    /// Window should always be above others.
    always_on_top: bool = false,
    /// Window should be treated as a utility window, not showing in the task bar and window list.
    utility: bool = false,
    /// Window should be treated as a tooltip and does not get mouse or keyboard focus, requires a parent window.
    tooltip: bool = false,
    /// Window should be treated as a popup menu, requires a parent window.
    popup_menu: bool = false,
    /// Window has grabbed keyboard input.
    keyboard_grabbed: bool = false,
    /// Window is in fill-document mode (Emscripten only), since SDL 3.4.0.
    fill_document: bool = false,
    /// Window with transparent buffer.
    transparent: bool = false,
    /// Window should not be focusable.
    not_focusable: bool = false,
};

// ------------------------------------ sdl helpers ------------------------------------

fn sdlMouseButtonToEnum(button: sdl.mouse.Button) ?input.MouseButton {
    return switch (button) {
        .left => input.MouseButton.left,
        .middle => input.MouseButton.middle,
        .right => input.MouseButton.right,
        .x1 => input.MouseButton.x1,
        .x2 => input.MouseButton.x2,
        else => null,
    };
}

fn sdlGamepadButtonToEnum(button: sdl.gamepad.Button) input.GamepadButton {
    return switch (button) {
        .south => .south,
        .east => .east,
        .west => .west,
        .north => .north,
        .back => .back,
        .guide => .guide,
        .start => .start,
        .left_stick => .left_stick,
        .right_stick => .right_stick,
        .left_shoulder => .left_shoulder,
        .right_shoulder => .right_shoulder,
        .dpad_up => .dpad_up,
        .dpad_down => .dpad_down,
        .dpad_left => .dpad_left,
        .dpad_right => .dpad_right,
        .misc1 => .misc1,
        .right_paddle1 => .right_paddle1,
        .left_paddle1 => .left_paddle1,
        .right_paddle2 => .right_paddle2,
        .left_paddle2 => .left_paddle2,
        .touchpad => .touchpad,
        .misc2 => .misc2,
        .misc3 => .misc3,
        .misc4 => .misc4,
        .misc5 => .misc5,
        .misc6 => .misc6,
    };
}

fn sdlGamepadAxisToEnum(axis: sdl.gamepad.Axis) input.GamepadAxis {
    return switch (axis) {
        .left_x => .left_x,
        .left_y => .left_y,
        .right_x => .right_x,
        .right_y => .right_y,
        .left_trigger => .left_trigger,
        .right_trigger => .right_trigger,
    };
}
