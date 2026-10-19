//! Validated graphics preferences shared by projects, executable hosts and rendering.
const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum { auto, vulkan, dx12, webgpu };
pub const PresentMode = enum { auto, fifo, fifo_relaxed, mailbox, immediate };
pub const AntiAliasing = enum {
    off,
    msaa_2x,
    msaa_4x,
    msaa_8x,
    fxaa,

    pub fn samples(self: AntiAliasing) u32 {
        return switch (self) {
            .off, .fxaa => 1,
            .msaa_2x => 2,
            .msaa_4x => 4,
            .msaa_8x => 8,
        };
    }
};
pub const TextureFilter = enum { nearest, linear };
pub const WindowMode = enum { windowed, borderless };
pub const ApplyResult = enum { queued, restart_required };
pub const Scope = enum { editor, runtime };

/// Read device-independent settings from a baked project value or an external configuration.
pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !Settings {
    const settings = try std.zon.parse.fromSlice(Settings, gpa, source, null, .{});
    try settings.validateValues();
    return settings;
}

pub const AdapterChoice = struct {
    name: [256]u8 = @splat(0),
    name_len: usize = 0,

    pub fn nameSlice(self: *const AdapterChoice) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Snapshot of usable choices on the current platform, GPU and main window.
pub const Capabilities = struct {
    backends: std.enums.EnumSet(Backend) = .initOne(.auto),
    present_modes: std.enums.EnumSet(PresentMode) = .initOne(.auto),
    anti_aliasing: std.enums.EnumSet(AntiAliasing) = .initMany(&.{ .off, .fxaa }),
    max_anisotropy: u16 = 1,
    window_settings: bool = false,
    frame_limit: bool = false,
    adapters: [16]AdapterChoice = @splat(.{}),
    adapter_count: usize = 0,
};

/// Project defaults or a complete user override. Backend, GPU and presentation changes need a restart.
pub const Settings = struct {
    backend: Backend = .auto,
    adapter_index: ?u16 = null,
    present_mode: PresentMode = .auto,
    frame_limit: u16 = 0,
    window_mode: WindowMode = .windowed,
    width: u32 = 900,
    height: u32 = 675,
    render_scale: f32 = 1,
    anti_aliasing: AntiAliasing = .msaa_4x,
    mipmaps: bool = true,
    texture_filter: TextureFilter = .linear,
    anisotropy: u16 = 1,

    /// Reject invalid values before allocating resources, writing preferences or changing windows.
    pub fn validate(self: Settings, caps: Capabilities) !void {
        try self.validateValues();
        if (!caps.backends.contains(self.backend)) return error.UnsupportedBackend;
        if (self.adapter_index) |index| if (index >= caps.adapter_count) return error.InvalidGraphicsAdapter;
        if (!caps.present_modes.contains(self.present_mode)) return error.UnsupportedPresentMode;
        if (!caps.anti_aliasing.contains(self.anti_aliasing)) return error.UnsupportedAntialiasing;
        if (self.anisotropy > caps.max_anisotropy) return error.UnsupportedAnisotropy;
        if (!caps.frame_limit and self.frame_limit != 0) return error.UnsupportedFrameLimit;
        if (!caps.window_settings and (self.window_mode != .windowed or self.width != 900 or self.height != 675))
            return error.UnsupportedWindowSettings;
    }

    /// Validate serialized values without needing a graphics device.
    pub fn validateValues(self: Settings) !void {
        if (self.width < 320 or self.width > 16384 or self.height < 240 or self.height > 16384)
            return error.InvalidWindowSize;
        if (self.frame_limit > 1000) return error.InvalidFrameLimit;
        if (!std.math.isFinite(self.render_scale) or self.render_scale < 0.25 or self.render_scale > 2)
            return error.InvalidRenderScale;
        if (self.anisotropy == 0 or self.anisotropy > 16 or !std.math.isPowerOfTwo(self.anisotropy))
            return error.InvalidAnisotropy;
        if (self.anisotropy > 1 and self.texture_filter != .linear) return error.AnisotropyRequiresLinearFiltering;
    }

    pub fn requiresRestart(self: Settings, other: Settings) bool {
        return self.backend != other.backend or self.adapter_index != other.adapter_index or self.present_mode != other.present_mode;
    }

    /// Shipped defaults are portable; personal overrides are instead validated strictly.
    pub fn forPlatform(self: Settings) Settings {
        var supported = self;
        const backend_available = switch (self.backend) {
            .auto => true,
            .webgpu => builtin.os.tag == .emscripten,
            .dx12 => builtin.os.tag == .windows,
            .vulkan => builtin.os.tag != .emscripten,
        };
        if (!backend_available) {
            supported.backend = .auto;
            supported.adapter_index = null;
        }
        if (builtin.os.tag == .emscripten or builtin.abi.isAndroid()) {
            supported.window_mode = .windowed;
            supported.width = 900;
            supported.height = 675;
        }
        if (builtin.os.tag == .emscripten) supported.frame_limit = 0;
        return supported;
    }

    /// Choose usable project defaults without changing or silently accepting a user override.
    pub fn supportedDefaults(self: Settings, caps: Capabilities) Settings {
        var supported = self;
        if (!caps.backends.contains(supported.backend)) {
            supported.backend = .auto;
            supported.adapter_index = null;
        }
        if (supported.adapter_index) |index| if (index >= caps.adapter_count) {
            supported.adapter_index = null;
        };
        if (!caps.present_modes.contains(supported.present_mode)) supported.present_mode = .auto;
        if (!caps.anti_aliasing.contains(supported.anti_aliasing)) {
            supported.anti_aliasing = .fxaa;
            for ([_]AntiAliasing{ .msaa_8x, .msaa_4x, .msaa_2x }) |mode| {
                if (mode.samples() <= self.anti_aliasing.samples() and caps.anti_aliasing.contains(mode)) {
                    supported.anti_aliasing = mode;
                    break;
                }
            }
        }
        while (supported.anisotropy > caps.max_anisotropy) supported.anisotropy /= 2;
        if (!caps.frame_limit) supported.frame_limit = 0;
        if (!caps.window_settings) {
            supported.window_mode = .windowed;
            supported.width = 900;
            supported.height = 675;
        }
        return supported;
    }
};

test "graphics settings reject unsupported choices and invalid quality values" {
    var caps = Capabilities{
        .window_settings = true,
        .frame_limit = true,
        .max_anisotropy = 8,
    };
    caps.anti_aliasing.insert(.msaa_4x);
    try (Settings{}).validate(caps);
    try std.testing.expectError(error.UnsupportedAntialiasing, (Settings{ .anti_aliasing = .msaa_8x }).validate(caps));
    try std.testing.expectError(error.UnsupportedBackend, (Settings{ .backend = .dx12 }).validate(caps));
    try std.testing.expectError(error.InvalidGraphicsAdapter, (Settings{ .adapter_index = 0 }).validate(caps));
    try std.testing.expectError(error.UnsupportedAnisotropy, (Settings{ .anisotropy = 16 }).validate(caps));
    try std.testing.expectError(error.AnisotropyRequiresLinearFiltering, (Settings{ .anisotropy = 2, .texture_filter = .nearest }).validate(caps));
    try std.testing.expectError(error.InvalidRenderScale, (Settings{ .render_scale = std.math.nan(f32) }).validate(caps));
    try std.testing.expectError(error.InvalidRenderScale, (Settings{ .render_scale = 0.1 }).validate(caps));
    try std.testing.expectError(error.InvalidWindowSize, (Settings{ .width = 0 }).validate(caps));
    try std.testing.expectError(error.InvalidFrameLimit, (Settings{ .frame_limit = 1001 }).validate(caps));
}

test "backend GPU and presentation choices require restarting graphics" {
    const original = Settings{};
    try std.testing.expect(!original.requiresRestart(.{ .anti_aliasing = .fxaa, .mipmaps = false }));
    try std.testing.expect(original.requiresRestart(.{ .backend = .vulkan }));
    try std.testing.expect(original.requiresRestart(.{ .adapter_index = 0 }));
    try std.testing.expect(original.requiresRestart(.{ .present_mode = .fifo }));
}

test "portable project defaults select supported options without weakening override validation" {
    var caps = Capabilities{};
    caps.anti_aliasing.insert(.msaa_4x);
    const authored = Settings{
        .backend = .dx12,
        .adapter_index = 7,
        .present_mode = .immediate,
        .anti_aliasing = .msaa_8x,
        .anisotropy = 16,
        .frame_limit = 144,
        .window_mode = .borderless,
        .width = 1920,
        .height = 1080,
    };
    const supported = authored.supportedDefaults(caps);
    try supported.validate(caps);
    try std.testing.expectEqual(AntiAliasing.msaa_4x, supported.anti_aliasing);
    try std.testing.expectEqual(Backend.auto, supported.backend);
    try std.testing.expectEqual(@as(?u16, null), supported.adapter_index);
    try std.testing.expectEqual(@as(u16, 1), supported.anisotropy);
    try std.testing.expectError(error.UnsupportedBackend, authored.validate(caps));
}
