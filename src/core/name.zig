//! `Name`: what an entity is called, as the editor's Hierarchy shows it and scenes save it. A
//! component like any other, kept in a fixed buffer so it holds no pointers.
const std = @import("std");

pub const Name = struct {
    buffer: [max_len]u8 = undefined,
    len: u8 = 0,

    /// The longest name kept; longer ones are cut at a character boundary.
    pub const max_len = 64;

    /// `value`, cut to `max_len` bytes without splitting a UTF-8 character.
    pub fn init(value: []const u8) Name {
        var end = @min(value.len, max_len);
        while (end > 0 and end < value.len and (value[end] & 0xC0) == 0x80) end -= 1;
        var name = Name{ .len = @intCast(end) };
        @memcpy(name.buffer[0..end], value[0..end]);
        return name;
    }

    pub fn text(self: *const Name) []const u8 {
        return self.buffer[0..self.len];
    }
};

test "a name keeps its text, cut at a character boundary when too long" {
    try std.testing.expectEqualStrings("Sun", Name.init("Sun").text());
    const long = "é" ** 40; // 80 bytes
    const cut = Name.init(long);
    try std.testing.expectEqual(@as(usize, 64), cut.text().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut.text()));
}
