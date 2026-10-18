//! Localization lookup contracts without loaded tables or fallback translations.
const std = @import("std");
const api = @import("support.zig");
pub const support: api.Support = .not_implemented;

// ponytail: localization has no table provider, implement loading and locale rules first.
pub const Localization = struct {
    pub fn setLocale(_: Localization, locale: []const u8) api.Error!void {
        return api.notImplemented(locale);
    }
    /// A successful lookup would allocate text with `gpa`, never return a key as a translation.
    pub fn text(_: Localization, gpa: std.mem.Allocator, key: []const u8) api.Error![]u8 {
        return api.notImplemented(.{ gpa, key });
    }
};
