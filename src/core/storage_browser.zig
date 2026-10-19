//! Synchronous persistent browser save slots through Emscripten's JavaScript bridge.
const std = @import("std");
const format = @import("storage_format.zig");
const web = @import("web_storage.zig");

/// Check that this origin exposes persistent Web Storage, never fall back to MEMFS.
pub fn checkAvailable() !void {
    try web.checkAvailable();
}

/// Return an owned binary envelope; malformed base64 and unavailable persistence are errors.
pub fn read(gpa: std.mem.Allocator, namespace: []const u8, slot: []const u8) ![]u8 {
    var buffer: [256]u8 = undefined;
    return web.read(gpa, try storageKey(&buffer, namespace, slot), format.header_bytes + format.max_payload_bytes);
}

/// Atomically replace one localStorage value; quota failures leave the old value unchanged.
pub fn write(namespace: []const u8, slot: []const u8, encoded: []const u8) !void {
    var buffer: [256]u8 = undefined;
    try web.write(try storageKey(&buffer, namespace, slot), encoded);
}

/// Remove exactly one key, returning FileNotFound when it does not exist.
pub fn remove(namespace: []const u8, slot: []const u8) !void {
    var buffer: [256]u8 = undefined;
    try web.remove(try storageKey(&buffer, namespace, slot));
}

fn storageKey(buffer: []u8, namespace: []const u8, slot: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "eggy.save.{s}.{s}", .{ namespace, slot });
}
