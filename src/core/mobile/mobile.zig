//! Phone and tablet features a game asks the device for, through `app.mobile()`: the screen's
//! safe area and orientation, keeping it awake, vibration, the device's motion, its battery,
//! opening links, and toasts. SDL provides most of them on Android and iOS alike; what it
//! doesn't is in `android.zig` and `ios.zig`.
const std = @import("std");
const builtin = @import("builtin");
const sdl3 = @import("vitellus_sdl3").sdl;
const ui = @import("weeoui");
const math = @import("eggenvector");
const api = @import("../support.zig");

/// The platform the game was built for.
pub const Platform = enum { android, ios, desktop, web };
pub const platform: Platform = if (builtin.abi.isAndroid())
    .android
else if (builtin.os.tag == .ios)
    .ios
else if (builtin.os.tag == .emscripten)
    .web
else
    .desktop;
/// Whether the game runs on a phone or tablet.
pub const is_mobile = platform == .android or platform == .ios;

/// What each platform's own features are: Android's (`android.zig`), iOS's (`ios.zig`), or none.
const native = switch (platform) {
    .android => @import("android.zig"),
    .ios => @import("ios.zig"),
    .desktop, .web => Unsupported,
};

/// Whether this build can vibrate the device and show toasts (see `Mobile.vibrate`, `showToast`).
pub const vibration_support: api.Support = native.vibration_support;
pub const toast_support: api.Support = native.toast_support;
/// Whether `Mobile.motion` reads the device's accelerometer and gyroscope here.
pub const motion_support: api.Support = if (is_mobile) .available else .unsupported_platform;

pub const Error = error{ NotImplemented, UnsupportedPlatform };

/// Which way up the display is.
pub const Orientation = enum { unknown, landscape, landscape_flipped, portrait, portrait_flipped };

/// How the device is moving, in its own axes: x to the right of the screen held upright, y up
/// it, z out of it towards the player.
pub const Motion = struct {
    /// Including gravity: about 9.8 down the y axis while held upright and still.
    acceleration_m_s2: math.Vec3,
    /// How fast it turns about each axis; zeros when the device has no gyroscope.
    rotation_rad_s: math.Vec3,
};

pub const Battery = struct {
    state: enum { unknown, on_battery, no_battery, charging, charged },
    /// Null where the device doesn't say.
    percent: ?u7,
    seconds_left: ?u32,
};

/// How long a toast stays up: Android's two lengths.
pub const ToastLength = enum { short, long };

/// What `Mobile` keeps open between calls: the motion sensors and the vibration device, opened
/// on first use. `App` owns it and closes it with `deinit`.
pub const State = struct {
    accelerometer: ?sdl3.sensor.Sensor = null,
    gyroscope: ?sdl3.sensor.Sensor = null,
    sensors_opened: bool = false,
    haptic: ?sdl3.haptic.Haptic = null,
    haptic_opened: bool = false,

    /// Close what was opened. Call once, before SDL shuts down.
    pub fn deinit(self: *State) void {
        if (self.accelerometer) |sensor| sensor.deinit();
        if (self.gyroscope) |sensor| sensor.deinit();
        if (self.haptic) |haptic| haptic.deinit();
        self.* = .{};
    }
};

/// The device's features, borrowed from `App` (`app.mobile()`) for the frame.
/// Main thread only, as SDL requires; don't keep it past the App.
pub const Mobile = struct {
    window: sdl3.video.Window,
    state: *State,

    /// The part of the window, in logical points, that the notch, rounded corners and system
    /// bars leave clear: put buttons and text inside it. The whole window on desktops.
    ///
    /// ```zig
    /// const safe = try app.mobile().safeArea();
    /// pause_button.x = safe.x + safe.w - pause_button.w;
    /// ```
    pub fn safeArea(self: Mobile) !ui.Rect {
        const area = try self.window.getSafeArea();
        return .{ .x = @floatFromInt(area.x), .y = @floatFromInt(area.y), .w = @floatFromInt(area.w), .h = @floatFromInt(area.h) };
    }

    /// Which way up the window's display is; `.unknown` where it can't say (most desktops).
    pub fn orientation(self: Mobile) Orientation {
        const display = self.window.getDisplayForWindow() catch return .unknown;
        return orientationOf(display.getCurrentOrientation());
    }

    /// Whether the device is a tablet rather than a phone.
    pub fn isTablet(_: Mobile) bool {
        return sdl3.system.isTablet();
    }

    /// Keep the screen on while `on` (a cutscene, a level without touches), or let it dim and
    /// lock as usual again. The setting lasts until changed.
    pub fn keepScreenOn(_: Mobile, on: bool) !void {
        if (on) try sdl3.video.disableScreenSaver() else try sdl3.video.enableScreenSaver();
    }

    /// Vibrate the device at `strength` (0 to 1) for `duration_ms`.
    /// `error.UnsupportedPlatform` on desktops and the web; see `vibration_support`.
    ///
    /// ```zig
    /// app.mobile().vibrate(0.6, 40) catch {}; // a tap when the player lands
    /// ```
    pub fn vibrate(self: Mobile, strength: f32, duration_ms: u32) !void {
        return native.vibrate(self.state, std.math.clamp(strength, 0, 1), duration_ms);
    }

    /// Show `text` briefly over the game, in the system's own style (an Android toast).
    /// `error.UnsupportedPlatform` on desktops and the web; see `toast_support`.
    pub fn showToast(_: Mobile, text: [:0]const u8, length: ToastLength) !void {
        return native.showToast(text, length);
    }

    /// How the device is moving now, or null when it has no accelerometer. Opens the sensors
    /// on first use, which then report every frame until the App closes; that first call reads
    /// zeros, as the sensors report from the next frame. `error.UnsupportedPlatform` on desktops
    /// and the web.
    ///
    /// ```zig
    /// if (try app.mobile().motion()) |motion| steer = motion.acceleration_m_s2.x / 9.8;
    /// ```
    pub fn motion(self: Mobile) !?Motion {
        if (!is_mobile) return error.UnsupportedPlatform;
        if (!self.state.sensors_opened) openSensors(self.state);
        const accelerometer = self.state.accelerometer orelse return null;
        var acceleration: [3]f32 = undefined;
        try accelerometer.getData(&acceleration);
        var rotation: [3]f32 = .{ 0, 0, 0 };
        if (self.state.gyroscope) |gyroscope| try gyroscope.getData(&rotation);
        return .{ .acceleration_m_s2 = .fromArray(acceleration), .rotation_rad_s = .fromArray(rotation) };
    }

    /// The battery's charge and whether it's charging. Estimates: check now and then, not as
    /// exact truth.
    pub fn battery(_: Mobile) !Battery {
        const info = try sdl3.PowerState.get();
        return .{ .state = switch (info.state) {
            .unknown => .unknown,
            .on_battery => .on_battery,
            .no_battery => .no_battery,
            .charging => .charging,
            .charged => .charged,
        }, .percent = info.percent, .seconds_left = info.seconds_left };
    }

    /// Open `url` in the device's browser (or the app that handles it), leaving the game.
    pub fn openUrl(_: Mobile, url: [:0]const u8) !void {
        try sdl3.openURL(url);
    }
};

/// Open the first accelerometer and gyroscope SDL lists. A device without them leaves them
/// null; one that fails to open is logged and left null too.
fn openSensors(state: *State) void {
    state.sensors_opened = true;
    const ids = sdl3.sensor.getSensors() catch |err| return std.log.warn("cannot list the device's sensors: {t}", .{err});
    defer sdl3.free(ids.ptr);
    for (ids) |id| {
        const slot = switch (id.getType() orelse continue) {
            .accelerometer => &state.accelerometer,
            .gyroscope => &state.gyroscope,
            else => continue,
        };
        if (slot.* != null) continue;
        slot.* = sdl3.sensor.Sensor.init(id) catch |err| blk: {
            std.log.warn("cannot open the device's {t}: {t}", .{ id.getType().?, err });
            break :blk null;
        };
    }
}

fn orientationOf(value: ?sdl3.video.Display.Orientation) Orientation {
    return switch (value orelse return .unknown) {
        .landscape => .landscape,
        .landscape_flipped => .landscape_flipped,
        .portrait => .portrait,
        .portrait_flipped => .portrait_flipped,
    };
}

/// Desktops and the web: no vibration or toasts.
const Unsupported = struct {
    const vibration_support: api.Support = .unsupported_platform;
    const toast_support: api.Support = .unsupported_platform;
    fn vibrate(_: *State, _: f32, _: u32) Error!void {
        return error.UnsupportedPlatform;
    }
    fn showToast(_: [:0]const u8, _: ToastLength) Error!void {
        return error.UnsupportedPlatform;
    }
};

test "the display's orientation maps over, unknown when it can't say" {
    try std.testing.expectEqual(Orientation.landscape_flipped, orientationOf(.landscape_flipped));
    try std.testing.expectEqual(Orientation.unknown, orientationOf(null));
}

test "a desktop build reports no vibration, toasts or motion" {
    if (is_mobile) return error.SkipZigTest;
    var state = State{};
    const mobile = Mobile{ .window = undefined, .state = &state };
    try std.testing.expectError(error.UnsupportedPlatform, mobile.vibrate(1, 10));
    try std.testing.expectError(error.UnsupportedPlatform, mobile.showToast("hi", .short));
    try std.testing.expectError(error.UnsupportedPlatform, mobile.motion());
    try std.testing.expectEqual(api.Support.unsupported_platform, vibration_support);
}

test "every call compiles for this platform" {
    std.testing.refAllDecls(Mobile);
    std.testing.refAllDecls(native);
}
