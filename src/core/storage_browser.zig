//! Synchronous persistent browser save slots through Emscripten's JavaScript bridge.
const std = @import("std");
const builtin = @import("builtin");
const format = @import("storage_format.zig");

extern "c" fn emscripten_run_script_int(script: [*:0]const u8) c_int;
// ponytail: uses Emscripten's default dynamic execution, use a JS library for a strict no-eval CSP.
const script = @embedFile("storage_browser.js");
const max_encoded_bytes = std.base64.standard.Encoder.calcSize(format.header_bytes + format.max_payload_bytes);

/// Check that this origin exposes persistent Web Storage, never fall back to MEMFS.
pub fn checkAvailable() !void {
    _ = try invoke("check", "", "", 0, 0);
}

/// Return an owned binary envelope; malformed base64 and unavailable persistence are errors.
pub fn read(gpa: std.mem.Allocator, namespace: []const u8, slot: []const u8) ![]u8 {
    const capacity = try invoke("size", namespace, slot, 0, max_encoded_bytes);
    const bytes = try gpa.alloc(u8, capacity);
    errdefer gpa.free(bytes);
    const len = try invoke("read", namespace, slot, @intFromPtr(bytes.ptr), bytes.len);
    return gpa.realloc(bytes, len);
}

/// Atomically replace one localStorage value; quota failures leave the old value unchanged.
pub fn write(namespace: []const u8, slot: []const u8, encoded: []const u8) !void {
    _ = try invoke("write", namespace, slot, @intFromPtr(encoded.ptr), encoded.len);
}

/// Remove exactly one key, returning FileNotFound when it does not exist.
pub fn remove(namespace: []const u8, slot: []const u8) !void {
    _ = try invoke("remove", namespace, slot, 0, 0);
}

fn invoke(operation: []const u8, namespace: []const u8, slot: []const u8, ptr: usize, len: usize) !usize {
    if (comptime builtin.os.tag != .emscripten) return error.UnsupportedPlatform;
    // Namespace is a hex digest and slot was validated; no user text becomes executable JS.
    var buffer: [4096]u8 = undefined;
    const source = std.fmt.bufPrintZ(&buffer, "({s})('{s}','eggy.save.{s}.{s}',{d},{d})", .{ script, operation, namespace, slot, ptr, len }) catch unreachable;
    const result = emscripten_run_script_int(source);
    return switch (result) {
        -1 => error.UnsupportedPlatform,
        -2 => error.StorageFull,
        -3 => error.CorruptSave,
        -4 => error.StorageIo,
        -5 => error.FileNotFound,
        -6 => error.SaveTooLarge,
        else => if (result < 0) error.StorageIo else @intCast(result),
    };
}
