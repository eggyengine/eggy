//! Game-save storage contracts, separate from plugin preferences and scene files.
const std = @import("std");
const api = @import("support.zig");
pub const support: api.Support = .not_implemented;

// ponytail: no game-save storage provider exists, define platform persistence before saving.
pub const Storage = struct {
    /// A successful provider would return caller-owned bytes freed with `gpa`.
    pub fn read(_: Storage, gpa: std.mem.Allocator, slot: []const u8) api.Error![]u8 {
        return api.notImplemented(.{ gpa, slot });
    }
    pub fn write(_: Storage, slot: []const u8, bytes: []const u8) api.Error!void {
        return api.notImplemented(.{ slot, bytes });
    }
    pub fn remove(_: Storage, slot: []const u8) api.Error!void {
        return api.notImplemented(slot);
    }
};
