//! Shared synchronous browser persistence with validated, non-executable storage keys.
const std = @import("std");
const builtin = @import("builtin");
extern "c" fn emscripten_run_script_int(script: [*:0]const u8) c_int;
const script = @embedFile("storage_browser.js");

pub fn checkAvailable() !void {
    _ = try invoke("check", "", 0, 0);
}

pub fn read(gpa: std.mem.Allocator, key: []const u8, limit: usize) ![]u8 {
    const capacity = try invoke("size", key, 0, std.base64.standard.Encoder.calcSize(limit));
    const bytes = try gpa.alloc(u8, capacity);
    errdefer gpa.free(bytes);
    const len = try invoke("read", key, @intFromPtr(bytes.ptr), bytes.len);
    if (len > limit) return error.SaveTooLarge;
    return gpa.realloc(bytes, len);
}

pub fn write(key: []const u8, bytes: []const u8) !void {
    _ = try invoke("write", key, @intFromPtr(bytes.ptr), bytes.len);
}

pub fn remove(key: []const u8) !void {
    _ = try invoke("remove", key, 0, 0);
}

fn invoke(operation: []const u8, key: []const u8, ptr: usize, len: usize) !usize {
    if (comptime builtin.os.tag != .emscripten) return error.UnsupportedPlatform;
    if (key.len > 256) return error.InvalidStorageKey;
    for (key) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return error.InvalidStorageKey;
    // ponytail: Emscripten's default dynamic execution; use a JS library for a strict no-eval CSP.
    var buffer: [4096]u8 = undefined;
    const source = try std.fmt.bufPrintSentinel(&buffer, "({s})('{s}','{s}',{d},{d})", .{ script, operation, key, ptr, len }, 0);
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
