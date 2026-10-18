//! Localization lookup contracts without loaded tables or fallback translations.
const std = @import("std");
const api = @import("support.zig");
pub const support: api.Support = .not_implemented;

// ponytail: localization has no table provider, implement loading and locale rules first.
pub const Localization = struct {
    /// Request a locale identifier such as `en-AU`. Currently returns `NotImplemented`,
    /// without validating/retaining the borrowed identifier or loading translation tables.
    ///
    /// ```zig
    /// try app.localization.setLocale("en-AU"); // Currently NotImplemented.
    /// ```
    pub fn setLocale(_: Localization, locale: []const u8) api.Error!void {
        return api.notImplemented(locale);
    }
    /// A successful lookup would allocate text with `gpa`, never return a key as a translation.
    /// `key` identifies a translation entry. Currently returns `NotImplemented`, without
    /// allocation; callers must not present this as a successful fallback lookup.
    ///
    /// ```zig
    /// const label = try app.localization.text(gpa, "menu.play"); // NotImplemented.
    /// defer gpa.free(label); // Required when a future provider succeeds.
    /// ```
    pub fn text(_: Localization, gpa: std.mem.Allocator, key: []const u8) api.Error![]u8 {
        return api.notImplemented(.{ gpa, key });
    }
};
