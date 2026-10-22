//! Opaque asset identities and deterministic identities for imported model children.
const std = @import("std");

pub const Id = u64;
pub const key_len = 16;

/// Format an identity as a filename-safe key; zero is reserved for an unset reference.
pub fn key(buffer: *[key_len]u8, value: Id) []const u8 {
    return std.fmt.bufPrint(buffer, "{x:0>16}", .{value}) catch unreachable;
}

/// Parse a canonical identity, rejecting paths, partial keys and the reserved zero value.
pub fn parse(text: []const u8) error{InvalidAssetId}!Id {
    if (text.len != key_len) return error.InvalidAssetId;
    for (text) |byte| if (!std.ascii.isHex(byte)) return error.InvalidAssetId;
    const value = std.fmt.parseInt(Id, text, 16) catch return error.InvalidAssetId;
    if (value == 0) return error.InvalidAssetId;
    return value;
}

/// The geometry/skeleton child retains its identity when animation is added or removed.
pub fn model(source: Id) Id {
    return child(source, "model", "", 0);
}

/// A model's material textures are identified by their place among its textures.
pub fn texture(source: Id, index: u32) Id {
    return child(source, "texture", "", index);
}

/// Clip names identify imported animations; the ordinal disambiguates duplicate names.
pub fn animation(source: Id, name: []const u8, occurrence: u32) Id {
    return child(source, "animation", name, occurrence);
}

fn child(source: Id, kind: []const u8, name: []const u8, occurrence: u32) Id {
    var hash = std.hash.Wyhash.init(0x6567_6779_6173_7365);
    var bytes: [12]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], source, .little);
    std.mem.writeInt(u32, bytes[8..12], occurrence, .little);
    hash.update(&bytes);
    hash.update(kind);
    hash.update(&.{0});
    hash.update(name);
    const value = hash.final();
    return if (value == 0) 1 else value;
}

test "asset keys are canonical opaque identities" {
    var buffer: [key_len]u8 = undefined;
    try std.testing.expectEqualStrings("000000000000002a", key(&buffer, 42));
    try std.testing.expectEqual(@as(Id, 42), try parse(&buffer));
    for ([_][]const u8{ "", "42", "0000000000000000", "resources/a.png", "00000000000000zz" }) |bad| {
        try std.testing.expectError(error.InvalidAssetId, parse(bad));
    }
}

test "model children have stable distinct identities" {
    try std.testing.expectEqual(model(42), model(42));
    try std.testing.expect(model(42) != model(43));
    try std.testing.expect(model(42) != animation(42, "walk", 0));
    try std.testing.expect(animation(42, "walk", 0) != animation(42, "run", 0));
    try std.testing.expect(animation(42, "walk", 0) != animation(42, "walk", 1));
}
