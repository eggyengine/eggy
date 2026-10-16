//! The window, renderer and ECS world every Eggy program opens.
const builtin = @import("builtin");
const std = @import("std");
const sdl_adapter = @import("vitellus_sdl3");
const sdl3 = sdl_adapter.sdl;
const Graphics = @import("graphics.zig").Graphics;
const clutch = @import("clutch");
const preferences_zig = @import("preferences.zig");
const Input = @import("input.zig").Input;
const Time = @import("time.zig").Time;

const web = builtin.os.tag == .emscripten;
const width = 900;
const height = 675;

/// Owns SDL, one window, the `Graphics` that draws into it, and the game's ECS `world`.
pub const App = struct {
    window: sdl_adapter.Sdl3Window,
    init_flags: sdl3.InitFlags,
    graphics: Graphics,
    /// Entities, components, resources and schedules. Plugins register schedules in `init`;
    /// `startWorld`, `updateWorld` and `deinit` run clutch's stages.
    world: clutch.World,
    /// Plugins' preference values (see `preferences`): the editor fills it from the user's and
    /// the project's files, the runtime from the project's, baked in.
    preference_values: preferences_zig.Store,
    /// The keyboard and mouse as they are this frame (see `eggy.Input`).
    input: Input = .{},
    /// How long the last frame took, and how long the game has run (see `eggy.Time`).
    time: Time = .{},

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

        return .{ .window = window, .init_flags = init_flags, .graphics = graphics, .world = .init(gpa), .preference_values = .init(gpa) };
    }

    /// Run the world's PreDeinit, Deinit and PostDeinit stages, then free everything.
    pub fn deinit(self: *App) void {
        self.stopWorld();
        self.world.deinit();
        self.preference_values.deinit();
        self.graphics.deinit();
        self.window.deinit();
        sdl3.quit(self.init_flags);
        sdl3.shutdown();
    }

    /// The values of `T`, a plugin's `Preferences` struct (see `eggy.preferences`): its defaults,
    /// overridden by what the user and the project set. Cheap enough to call every frame, which
    /// follows changes made in the Preferences window as they happen.
    pub fn preferences(self: *const App, comptime T: type) T {
        return self.preference_values.get(T);
    }

    /// Start over with an empty world: run the old one's PreDeinit, Deinit and PostDeinit
    /// stages and free it. The editor does this before swapping in a rebuilt game, while the old
    /// game's code, which the world's schedules and storages point into, is still loaded. Run
    /// `startWorld` once the new game's plugins have registered their schedules.
    pub fn resetWorld(self: *App) void {
        self.stopWorld();
        const allocator = self.world.allocator;
        self.world.deinit();
        self.world = .init(allocator);
    }

    fn stopWorld(self: *App) void {
        inline for (.{ .PreDeinit, .Deinit, .PostDeinit }) |stage| {
            self.world.runStage(stage) catch |err| std.log.err("{s} schedule failed: {t}", .{ @tagName(stage), err });
        }
    }

    /// Run the world's PreInit, Init and PostInit stages. Call once, after plugins' `init`, so
    /// the schedules they registered run.
    pub fn startWorld(self: *App) !void {
        inline for (.{ .PreInit, .Init, .PostInit }) |stage| try self.world.runStage(stage);
    }

    /// Run the world's PreUpdate, Update and PostUpdate stages, then end the tick: `Added`,
    /// `Changed` and `Removed` filters and this frame's events reset. Systems see this frame's
    /// `input` and `time` as the resources `eggy.Input` and `eggy.Time`.
    pub fn updateWorld(self: *App) !void {
        try self.world.insertResource(self.input);
        try self.world.insertResource(self.time);
        inline for (.{ .PreUpdate, .Update, .PostUpdate }) |stage| try self.world.runStage(stage);
        self.world.tick();
    }

    /// Window lifecycle every program shares: quit requests and closing the main window end the
    /// app (`.success`), and size or scale changes resize the main window's swapchain. Closing
    /// another window (an editor pop-out) is left to whoever opened it.
    pub fn event(self: *App, curr_event: sdl3.events.Event) !sdl3.AppResult {
        switch (curr_event) {
            .quit, .terminating => return .success,
            .window_close_requested => |window| if (window.id == try self.window.window.getId()) return .success,
            .window_resized, .window_pixel_size_changed, .window_display_scale_changed => try self.graphics.syncSize(self.window),
            else => {},
        }
        return .run;
    }
};
