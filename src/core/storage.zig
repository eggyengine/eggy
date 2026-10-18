//! Game-save storage contracts, separate from plugin preferences and scene files.
const std = @import("std");
const api = @import("support.zig");
pub const support: api.Support = .not_implemented;

// ponytail: no game-save storage provider exists, define platform persistence before saving.
pub const Storage = struct {
    /// A successful provider would return caller-owned bytes freed with `gpa`.
    /// `slot` is a logical save name, not a project-relative resource path.
    /// Currently returns `NotImplemented` without filesystem access or allocation.
    ///
    /// ```zig
    /// const bytes = try app.storage.read(gpa, "slot-1"); // Currently NotImplemented.
    /// defer gpa.free(bytes); // Required if a future provider succeeds.
    /// ```
    pub fn read(_: Storage, gpa: std.mem.Allocator, slot: []const u8) api.Error![]u8 {
        return api.notImplemented(.{ gpa, slot });
    }
    /// Request persistence of borrowed bytes under a logical save-slot name.
    /// Currently returns `NotImplemented`; never report a saved game after this error.
    /// No file is created and neither slice is retained.
    ///
    /// ```zig
    /// try app.storage.write("slot-1", serialized_save); // Currently NotImplemented.
    /// ```
    pub fn write(_: Storage, slot: []const u8, bytes: []const u8) api.Error!void {
        return api.notImplemented(.{ slot, bytes });
    }
    /// Request deletion of one logical save slot, separate from preferences and resources.
    /// Currently returns `NotImplemented`, without deleting anything.
    ///
    /// ```zig
    /// try app.storage.remove("slot-1"); // Currently NotImplemented.
    /// ```
    pub fn remove(_: Storage, slot: []const u8) api.Error!void {
        return api.notImplemented(slot);
    }
};
