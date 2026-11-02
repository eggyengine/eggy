//! Paths chosen in the system's file or folder picker, handed from SDL's callback, which may run
//! on any thread, to the main thread's next frame.
const std = @import("std");
const sdl3 = @import("eggy").sdl_adapter.sdl;

/// One picker's result slot. Keep it at a stable address from `show*` until the dialog closes,
/// and `deinit` it once no dialog can still answer.
pub const PickedPaths = struct {
    /// The paths picked and not yet taken, one per line, owned by the C allocator.
    slot: std.atomic.Value(?[*:0]u8) = .init(null),

    /// Ask for one folder, the dialog parented to `window` and opening in `start_in` if given.
    ///
    /// ```zig
    /// self.picked.showFolder(window, null);
    /// // A later frame:
    /// if (self.picked.take()) |dir| { defer PickedPaths.free(dir); open(dir); }
    /// ```
    pub fn showFolder(self: *PickedPaths, window: sdl3.video.Window, start_in: ?[:0]const u8) void {
        sdl3.dialog.showOpenFolder(PickedPaths, picked, self, window, start_in, false);
    }

    /// Ask for files, any number of them, the dialog parented to `window`.
    pub fn showFiles(self: *PickedPaths, window: sdl3.video.Window) void {
        sdl3.dialog.showOpenFile(PickedPaths, picked, self, window, null, null, true);
    }

    /// What was picked since the last call, one path per line, or null. Free it with `free`.
    pub fn take(self: *PickedPaths) ?[:0]u8 {
        const paths = self.slot.swap(null, .acq_rel) orelse return null;
        return std.mem.span(paths);
    }

    /// Free what `take` returned.
    pub fn free(paths: [:0]u8) void {
        std.heap.c_allocator.free(paths);
    }

    /// Free anything picked and not taken. Does not close an open dialog.
    pub fn deinit(self: *PickedPaths) void {
        if (self.take()) |paths| free(paths);
    }

    /// SDL's dialog callback: join the chosen paths and put them in the slot, replacing any
    /// not yet taken. A cancelled or failed dialog, or no memory, leaves the slot alone.
    fn picked(self: ?*PickedPaths, files: ?[]const [*:0]const u8, _: ?usize, failed: bool) void {
        const chosen = files orelse return;
        if (failed or chosen.len == 0) return;
        var joined: std.ArrayList(u8) = .empty;
        for (chosen, 0..) |file, i| {
            if (i > 0) joined.append(std.heap.c_allocator, '\n') catch return joined.deinit(std.heap.c_allocator);
            joined.appendSlice(std.heap.c_allocator, std.mem.span(file)) catch return joined.deinit(std.heap.c_allocator);
        }
        const owned = joined.toOwnedSliceSentinel(std.heap.c_allocator, 0) catch return joined.deinit(std.heap.c_allocator);
        if (self.?.slot.swap(owned.ptr, .acq_rel)) |old| std.heap.c_allocator.free(std.mem.span(old));
    }
};

test "picked paths arrive one per line, newest replacing what wasn't taken" {
    var paths: PickedPaths = .{};
    defer paths.deinit();
    PickedPaths.picked(&paths, &.{"/old"}, null, false);
    PickedPaths.picked(&paths, &.{ "/a.png", "/b.png" }, null, false);
    PickedPaths.picked(&paths, &.{}, null, false); // cancelled: nothing changes
    const taken = paths.take().?;
    defer PickedPaths.free(taken);
    try std.testing.expectEqualStrings("/a.png\n/b.png", taken);
    try std.testing.expect(paths.take() == null);
}
