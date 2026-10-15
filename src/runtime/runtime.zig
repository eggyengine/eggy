//! The `eggy_runtime` module: the game as players run it, with its plugins and nothing else.
const builtin = @import("builtin");
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;

const web = builtin.os.tag == .emscripten;
const fps = 340000;

/// The runtime for `project`, which declares `name` (the window title) and `plugins` (a tuple of
/// plugin types, the game first). `addGame` generates it from the game's build.
pub fn Runtime(comptime project: type) type {
    const Plugins = eggy.plugins.Set(project.plugins, &project.plugin_keys);
    return struct {
        gpa: std.mem.Allocator,
        app: eggy.App,
        plugins: Plugins,
        fps_capper: sdl3.extras.FramerateCapper(f32),
        /// The meshes drawn each frame, gathered from the world.
        drawables: []eggy.mesh.Drawable,

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator, args: []const [*:0]const u8) !Self {
            _ = args;
            var app = try eggy.App.init(gpa, project.name);
            errdefer app.deinit();
            // The project's preferences, baked in by `addGame`, before the plugins start.
            if (@hasDecl(project, "preference_files")) for (project.preference_files) |file| {
                app.preference_values.read(.project, file.key, file.zon) catch |err| std.log.warn("the preferences for {s} don't parse ({t}): they are ignored", .{ file.key, err });
            };
            // The plugins the project turned off (`eggy.plugins.registry_file`), also baked in.
            var off_arena = std.heap.ArenaAllocator.init(gpa);
            defer off_arena.deinit();
            const off: []const []const u8 = if (@hasDecl(project, "plugin_registry")) eggy.plugins.parseOff(off_arena.allocator(), project.plugin_registry) catch |err| blk: {
                std.log.warn("{s} doesn't parse ({t}): every plugin runs", .{ eggy.plugins.registry_file, err });
                break :blk &.{};
            } else &.{};
            var plugins = try Plugins.init(gpa, &app, Plugins.enabledExcept(off));
            errdefer plugins.deinit();
            try app.startWorld();
            const drawables = try gpa.alloc(eggy.mesh.Drawable, eggy.max_drawables);
            return .{
                .gpa = gpa,
                .drawables = drawables,
                .plugins = plugins,
                .app = app,
                .fps_capper = .{ .mode = .{ .limited = fps } },
            };
        }

        pub fn deinit(self: *Self) void {
            self.plugins.deinit();
            self.app.deinit();
            self.gpa.free(self.drawables);
        }

        pub fn iterate(self: *Self) !sdl3.AppResult {
            try self.app.graphics.syncSize(self.app.window);
            // The browser already paces frames to the display.
            if (!web) _ = self.fps_capper.delay();
            try self.plugins.update(&self.app);
            try self.app.updateWorld();
            const frame = try self.app.graphics.beginFrame();
            const drawn = eggy.mesh.gather(&self.app.world, self.drawables);
            try self.app.graphics.drawScene(frame, self.drawables[0..drawn]);
            try self.app.graphics.endFrame(frame);
            return .run;
        }

        pub fn event(self: *Self, curr_event: sdl3.events.Event) !sdl3.AppResult {
            try self.plugins.event(&self.app, curr_event);
            return self.app.event(curr_event);
        }
    };
}

test "the runtime compiles for a project" {
    const project = struct {
        pub const name = "test";
        pub const plugins = .{struct {}};
        pub const plugin_keys = [_][:0]const u8{"game"};
    };
    std.testing.refAllDecls(Runtime(project));
}
