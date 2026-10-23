//! `Name`: what an entity is called, as the editor's Hierarchy shows it and scenes save it. A
//! component like any other, kept in a fixed buffer so it holds no pointers. `find` looks an
//! entity up by it, to reach what a scene made from code.
const std = @import("std");
const ecs = @import("clutch");

pub const Name = struct {
    buffer: [max_len]u8 = undefined,
    len: u8 = 0,

    /// The longest name kept; longer ones are cut at a character boundary.
    pub const max_len = 64;

    /// `value`, cut to `max_len` bytes without splitting a UTF-8 character.
    /// Copies bytes into the returned value without allocation; does not validate UTF-8.
    ///
    /// ```zig
    /// const name = Name.init("Player");
    /// ```
    pub fn init(value: []const u8) Name {
        var end = @min(value.len, max_len);
        while (end > 0 and end < value.len and (value[end] & 0xC0) == 0x80) end -= 1;
        var name = Name{ .len = @intCast(end) };
        @memcpy(name.buffer[0..end], value[0..end]);
        return name;
    }

    /// Borrow the stored bytes, without a sentinel; valid until this name moves or changes.
    ///
    /// ```zig
    /// const name = Name.init("Player");
    /// const label = name.text();
    /// ```
    pub fn text(self: *const Name) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// The first entity of `world` named `name`, if any: `eggy.findNamed(&app.world, "Player")`.
/// Compares exact bytes, not a prefix; duplicate names resolve in ECS query order.
/// The returned ID is not a component pointer and must be checked if retained after despawns.
///
/// ```zig
/// const player = find(world, "Player") orelse return error.PlayerMissing;
/// ```
pub fn find(world: *ecs.World, name: []const u8) ?ecs.EntityId {
    var named = world.query(.{*const Name});
    while (named.next()) |view| if (std.mem.eql(u8, view.get(*const Name).text(), name)) return view.entity;
    return null;
}

test "an entity is found by its name" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{Name.init("Floor")});
    const player = try world.spawn(.{Name.init("Player")});
    try std.testing.expect(find(&world, "Player").?.eql(player));
    try std.testing.expect(find(&world, "Nobody") == null);
}

test "a name keeps its text, cut at a character boundary when too long" {
    try std.testing.expectEqualStrings("Sun", Name.init("Sun").text());
    const long: [80]u8 = @bitCast(@as([40][2]u8, @splat("é".*)));
    const cut = Name.init(&long);
    try std.testing.expectEqual(@as(usize, 64), cut.text().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut.text()));
}
