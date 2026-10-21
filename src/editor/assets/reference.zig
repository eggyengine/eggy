//! A project asset as an Inspector field holds it: the identity its reference stores, never a
//! path. What a drag from the Assets panel carries.
const std = @import("std");
const assets = @import("eggy").assets;

pub const Reference = struct {
    key_text: [assets.id.key_len]u8,
    /// What it is as a field takes it: a model's geometry is `.model`, an imported or authored
    /// clip `.animation`, a picture `.image`.
    kind: assets.Kind,
    /// Its name as shown, borrowed from the caller (a file's name, or the model's for its
    /// geometry).
    name: []const u8,

    /// Describe asset `id`; `name` is borrowed.
    ///
    /// ```zig
    /// const reference = Reference.of(42, .image, "wood.png");
    /// std.debug.assert(reference.key().len == 16);
    /// ```
    pub fn of(id: assets.Id, kind: assets.Kind, name: []const u8) Reference {
        var made: Reference = .{ .key_text = undefined, .kind = kind, .name = name };
        _ = assets.id.key(&made.key_text, id);
        return made;
    }

    /// The canonical hexadecimal key a reference field stores; borrows `self`.
    pub fn key(self: *const Reference) []const u8 {
        return &self.key_text;
    }

    /// Whether a field accepting `accepts` takes it.
    pub fn fits(self: Reference, accepts: assets.Kind) bool {
        return accepts == .any or accepts == self.kind;
    }
};

test "a reference holds a canonical key and fits the kind it is" {
    const reference = Reference.of(0x2a, .audio, "hum.ogg");
    try std.testing.expectEqualStrings("000000000000002a", reference.key());
    try std.testing.expect(reference.fits(.audio) and reference.fits(.any));
    try std.testing.expect(!reference.fits(.image));
}
