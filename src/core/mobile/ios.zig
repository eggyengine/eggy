//! What `mobile.zig` needs on iOS beyond SDL's shared calls. SDL has neither, so both are
//! still to write in Objective-C or through the Objective-C runtime.
const api = @import("../support.zig");
const mobile = @import("mobile.zig");

pub const vibration_support: api.Support = .not_implemented;
pub const toast_support: api.Support = .not_implemented;

/// ponytail: iOS vibration is unwritten; use UIImpactFeedbackGenerator (or Core Haptics for
/// `duration_ms`), mapping `strength` to its intensity.
pub fn vibrate(state: *mobile.State, strength: f32, duration_ms: u32) mobile.Error!void {
    return api.notImplemented(.{ state, strength, duration_ms });
}

/// ponytail: iOS has no toasts; draw one with the game's UI, or present a short-lived
/// UIAlertController, when a game needs it there.
pub fn showToast(text: [:0]const u8, length: mobile.ToastLength) mobile.Error!void {
    return api.notImplemented(.{ text, length });
}
