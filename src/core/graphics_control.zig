//! Deferred application of per-user graphics preferences at a host frame boundary.
const std = @import("std");
const builtin = @import("builtin");
const render = @import("render_settings.zig");
const preferences = @import("graphics_preferences.zig");
const Graphics = @import("graphics.zig").Graphics;
const adapter = @import("vitellus_sdl3");
const sdl = adapter.sdl;

pub const State = struct {
    defaults: render.Settings = .{},
    requested: render.Settings = .{},
    pending: ?render.Settings = null,
    warning: bool = false,
    store: ?preferences.Store = null,
    capper: sdl.extras.FramerateCapper(f32) = .{ .mode = .unlimited },

    pub fn init(gpa: std.mem.Allocator, io: std.Io, project_name: []const u8, scope: render.Scope, defaults: render.Settings) !State {
        try defaults.validateValues();
        const portable = defaults.forPlatform();
        if (!std.meta.eql(defaults, portable)) std.log.warn("project graphics defaults adjusted for this platform", .{});
        var self = State{ .defaults = portable, .requested = portable };
        self.store = try preferences.Store.init(gpa, io, project_name, scope);
        errdefer self.deinit();
        const saved = self.store.?.load() catch |err| blk: {
            self.recover(err);
            break :blk null;
        };

        if (saved) |settings| self.requested = settings;
        self.configureCapper();
        return self;
    }

    pub fn deinit(self: *State) void {
        if (self.store) |*store| store.deinit();
    }

    /// Explicit startup recovery; the built-in settings surface also displays `warning`.
    pub fn recover(self: *State, err: anyerror) void {
        std.log.warn("saved graphics settings cannot be applied ({t}); using project defaults", .{err});
        self.warning = true;
        self.requested = self.defaults;
        self.configureCapper();
    }

    pub fn request(self: *State, settings: render.Settings, graphics: *const Graphics, persist: bool) !render.ApplyResult {
        try settings.validate(graphics.capabilities());
        if (persist) {
            const store = if (self.store) |*store| store else return error.GraphicsPreferencesNotInitialized;
            try store.save(settings);
            self.warning = false;
        }
        self.requested = settings;
        self.pending = settings;
        return if (graphics.render_settings.requiresRestart(settings)) .restart_required else .queued;
    }

    pub fn setDefaults(self: *State, settings: render.Settings, graphics: *const Graphics) !render.ApplyResult {
        try settings.validateValues();
        self.defaults = settings.forPlatform().supportedDefaults(graphics.capabilities());
        if (!std.meta.eql(settings, self.defaults))
            std.log.warn("project graphics defaults adjusted to this device's supported options", .{});
        if (self.store) |store| if (store.has_override) return .queued;
        return self.request(self.defaults, graphics, false);
    }

    /// Apply live fields only before any surface begins recording; leave restart fields staged.
    pub fn apply(self: *State, graphics: *Graphics, window: adapter.Sdl3Window) !void {
        if (self.pending) |settings| {
            var live = settings;
            const before = graphics.render_settings;
            live.backend = before.backend;
            live.adapter_index = before.adapter_index;
            live.present_mode = before.present_mode;
            if (graphics.capabilities().window_settings) {
                if (live.window_mode != before.window_mode)
                    try window.window.setFullscreen(live.window_mode == .borderless);
                if (live.window_mode == .windowed and
                    (live.window_mode != before.window_mode or live.width != before.width or live.height != before.height))
                    try window.window.setSize(live.width, live.height);
            }
            try graphics.setRenderSettings(live);
            self.pending = null;
            self.configureCapper();
        }
        if (comptime builtin.os.tag != .emscripten) _ = self.capper.delay();
    }

    fn configureCapper(self: *State) void {
        self.capper.mode = if (self.requested.frame_limit == 0) .unlimited else .{ .limited = @floatFromInt(self.requested.frame_limit) };
    }
};

test "requests are validated and queued without changing active restart fields" {
    var graphics: Graphics = undefined;
    graphics.cached_caps = .{};
    graphics.cached_caps.backends.insert(.vulkan);
    graphics.cached_caps.anti_aliasing.insert(.msaa_4x);
    graphics.render_settings = .{};
    var state = State{};
    const requested = render.Settings{ .backend = .vulkan, .anti_aliasing = .fxaa };
    try std.testing.expectEqual(render.ApplyResult.restart_required, try state.request(requested, &graphics, false));
    try std.testing.expectEqualDeep(requested, state.pending.?);
    try std.testing.expectEqual(render.Backend.auto, graphics.render_settings.backend);
    try std.testing.expectError(error.InvalidRenderScale, state.request(.{ .render_scale = 0 }, &graphics, false));
    try std.testing.expectEqualDeep(requested, state.pending.?);
    try std.testing.expectError(error.GraphicsPreferencesNotInitialized, state.request(.{}, &graphics, true));
    try std.testing.expectEqualDeep(requested, state.requested);
}
