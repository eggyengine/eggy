//! Eggy's binary save envelope: format/schema versions, bounded payload length and SHA-256 integrity.
const std = @import("std");

pub const header_bytes = 56;
pub const max_payload_bytes = 64 << 20;
const magic = "EGGYSAVE";
const format_version: u32 = 1;

/// Encode the fixed little-endian header; game payload serialization is left to the game.
pub fn header(bytes: []const u8, schema: u32) [header_bytes]u8 {
    std.debug.assert(bytes.len <= max_payload_bytes);
    var result: [header_bytes]u8 = undefined;
    @memcpy(result[0..8], magic);
    std.mem.writeInt(u32, result[8..12], format_version, .little);
    std.mem.writeInt(u32, result[12..16], schema, .little);
    std.mem.writeInt(u64, result[16..24], bytes.len, .little);
    std.crypto.hash.sha2.Sha256.hash(bytes, result[24..56], .{});
    return result;
}

/// Validate the complete envelope before exposing its borrowed payload.
/// Rejects truncated/trailing bytes, changed payloads and unsupported versions distinctly.
pub fn payload(encoded: []const u8, schema: u32) ![]const u8 {
    if (encoded.len < header_bytes or !std.mem.eql(u8, encoded[0..8], magic)) return error.CorruptSave;
    if (std.mem.readInt(u32, encoded[8..12], .little) != format_version) return error.UnsupportedSaveFormat;
    const size = std.mem.readInt(u64, encoded[16..24], .little);
    if (size > max_payload_bytes) return error.SaveTooLarge;
    const bytes = encoded[header_bytes..];
    if (size != bytes.len) return error.CorruptSave;
    var checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &checksum, .{});
    if (!std.mem.eql(u8, &checksum, encoded[24..56])) return error.CorruptSave;
    if (std.mem.readInt(u32, encoded[12..16], .little) != schema) return error.UnsupportedSaveSchema;
    return bytes;
}

test "save envelope detects bad magic, truncation, trailing bytes and checksums" {
    const saved_header = header("save", 3);
    var encoded = saved_header ++ "save".*;
    try std.testing.expectEqualStrings("save", try payload(&encoded, 3));
    try std.testing.expectError(error.UnsupportedSaveSchema, payload(&encoded, 1));
    for (0..encoded.len) |len| try std.testing.expectError(error.CorruptSave, payload(encoded[0..len], 3));
    try std.testing.expectError(error.CorruptSave, payload(&(encoded ++ "x".*), 3));
    encoded[0] ^= 1;
    try std.testing.expectError(error.CorruptSave, payload(&encoded, 3));
    encoded[0] ^= 1;
    encoded[24] ^= 1;
    try std.testing.expectError(error.CorruptSave, payload(&encoded, 3));
}

test "save envelope distinguishes engine format from game schema" {
    var encoded = header("", 42);
    try std.testing.expectEqualStrings("", try payload(&encoded, 42));
    std.mem.writeInt(u32, encoded[8..12], 99, .little);
    try std.testing.expectError(error.UnsupportedSaveFormat, payload(&encoded, 42));
    std.mem.writeInt(u32, encoded[8..12], 1, .little);
    std.mem.writeInt(u64, encoded[16..24], max_payload_bytes + 1, .little);
    try std.testing.expectError(error.SaveTooLarge, payload(&encoded, 42));
}
