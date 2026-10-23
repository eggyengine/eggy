//! What `mobile.zig` needs on Android beyond SDL's shared calls: vibration through SDL's
//! haptics, which drive the phone's vibrator, and toasts.
const std = @import("std");
const sdl3 = @import("vitellus_sdl3").sdl;
const api = @import("../support.zig");
const mobile = @import("mobile.zig");

pub const vibration_support: api.Support = .available;
pub const toast_support: api.Support = .available;

/// Vibrate through the first haptic device SDL lists (the vibrator), opened on first use.
/// A phone without one gives `error.NoVibrator`.
pub fn vibrate(state: *mobile.State, strength: f32, duration_ms: u32) !void {
    if (!state.haptic_opened) {
        state.haptic_opened = true;
        state.haptic = openVibrator() catch |err| blk: {
            std.log.warn("cannot open the device's vibrator: {t}", .{err});
            break :blk null;
        };
    }
    const haptic = state.haptic orelse return error.NoVibrator;
    try haptic.playRumble(strength, duration_ms);
}

fn openVibrator() !sdl3.haptic.Haptic {
    const ids = try sdl3.haptic.getHaptics();
    defer sdl3.free(ids.ptr);
    if (ids.len == 0) return error.NoVibrator;
    const haptic = try sdl3.haptic.Haptic.init(ids[0]);
    errdefer haptic.deinit();
    try haptic.initRumble();
    return haptic;
}

/// Show `text` as an Android toast, centred low on the screen as the system places them.
pub fn showToast(text: [:0]const u8, length: mobile.ToastLength) !void {
    const duration: c_int = switch (length) {
        .short => 0,
        .long => 1,
    };
    // -1: no gravity of our own, so Android puts it where toasts go.
    if (!sdl3.c.SDL_ShowAndroidToast(text.ptr, duration, -1, 0, 0)) return error.SdlError;
}
