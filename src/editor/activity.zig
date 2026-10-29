//! How the editor is being used, for plugins through `EditorStatus`: when someone last gave its
//! windows input, since when none of them has focus, and how many times this editor saved the
//! scene, started playing and started a build.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;

pub const Activity = struct {
    last_input_ms: u64 = 0,
    /// When the editor's windows lost focus, until one gains it again.
    focus_lost_ms: ?u64 = null,
    saves: u32 = 0,
    plays: u32 = 0,
    builds: u32 = 0,

    /// Follow focus and input from `event`, which arrived at `now_ms`. A pointer passing over an
    /// unfocused window isn't use.
    pub fn follow(self: *Activity, event: sdl3.events.Event, now_ms: u64) void {
        switch (event) {
            .window_focus_gained => self.focus_lost_ms = null,
            .window_focus_lost => self.focus_lost_ms = now_ms,
            else => if (self.focus_lost_ms == null and eggy.game_ui.isInput(event)) {
                self.last_input_ms = now_ms;
            },
        }
    }
};

test "input counts only while a window has focus" {
    var activity = Activity{};
    activity.follow(.{ .key_down = std.mem.zeroes(@FieldType(sdl3.events.Event, "key_down")) }, 1000);
    activity.follow(.{ .window_focus_lost = std.mem.zeroes(@FieldType(sdl3.events.Event, "window_focus_lost")) }, 2000);
    activity.follow(.{ .mouse_motion = std.mem.zeroes(@FieldType(sdl3.events.Event, "mouse_motion")) }, 3000);
    try std.testing.expectEqual(1000, activity.last_input_ms);
    try std.testing.expectEqual(2000, activity.focus_lost_ms.?);
}
