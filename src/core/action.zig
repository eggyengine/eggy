//! Typed before/after values for reversible edits.
const std = @import("std");

/// Which state of an edit to apply.
pub const Direction = enum { undo, redo };

/// A reversible value edit. Slices and pointers remain borrowed: this value does not clone or
/// free them. A history owner must snapshot them before their source expires.
///
/// ```zig
/// const edit = Action(f32){ .before = 1, .after = 2 };
/// ```
pub fn Action(comptime T: type) type {
    return struct {
        before: T,
        after: T,

        /// Select the state to apply, without changing either snapshot.
        /// Returns `T` by value, preserving any borrowed pointers or slices.
        ///
        /// ```zig
        /// const edit = Action(f32){ .before = 1, .after = 2 };
        /// const restored = edit.value(.undo);
        /// ```
        pub fn value(self: @This(), direction: Direction) T {
            return switch (direction) {
                .undo => self.before,
                .redo => self.after,
            };
        }
    };
}

test "one value application path supports undo and redo" {
    const Position = struct { x: f32, y: f32 };
    const change = Action(Position){ .before = .{ .x = 1, .y = 2 }, .after = .{ .x = 3, .y = 4 } };
    var position = change.value(.redo);
    try std.testing.expectEqual(@as(f32, 3), position.x);
    position = change.value(.undo);
    try std.testing.expectEqual(@as(f32, 1), position.x);
    try std.testing.expectEqual(@as(f32, 2), position.y);
}
