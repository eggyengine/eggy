//! Translated text: a table per locale, each a project `.zon` file of keys and their text, of
//! which the one for the chosen locale is loaded and looked up by key.
//!
//! ```zon
//! // resources/locales/fr.zon
//! .{
//!     .@"menu.play" = "Jouer",
//!     .@"menu.quit" = "Quitter",
//! }
//! ```
const std = @import("std");
const api = @import("support.zig");
const AssetRef = @import("refs.zig").AssetRef;
const Resources = @import("resources/resources.zig").Resources;
pub const support: api.Support = .available;

/// The longest locale name taken, as in `en-AU` or `zh-Hant-TW`.
const max_locale_len = 35;

pub const Localization = struct {
    gpa: std.mem.Allocator = std.heap.c_allocator,
    /// Each locale's table file, as `addTable` gave them.
    tables: std.ArrayList(Table) = .empty,
    /// The locale chosen and its table's keys and text, owned by `loaded`.
    current: ?[]const u8 = null,
    entries: std.StringHashMapUnmanaged([]const u8) = .empty,
    loaded: ?std.heap.ArenaAllocator = null,

    const Table = struct { locale: []u8, file: AssetRef(.text) };

    pub fn deinit(self: *Localization) void {
        for (self.tables.items) |table| self.gpa.free(table.locale);
        self.tables.deinit(self.gpa);
        self.forgetLoaded();
        self.* = .{ .gpa = self.gpa };
    }

    /// Say that `locale`'s text is in `file`, a `.zon` of keys and text. Giving a locale again
    /// replaces its file; it is read when `setLocale` chooses it. Fails with `InvalidLocale` for
    /// a name that isn't letters, digits, `-` and `_` (35 at most).
    ///
    /// ```zig
    /// try app.localization.addTable("fr", .init("resources/locales/fr.zon"));
    /// ```
    pub fn addTable(self: *Localization, locale: []const u8, file: AssetRef(.text)) !void {
        try validateLocale(locale);
        if (file.len == 0) return error.UnsetAsset;
        for (self.tables.items) |*table| if (std.ascii.eqlIgnoreCase(table.locale, locale)) {
            table.file = file;
            return;
        };
        const owned = try self.gpa.dupe(u8, locale);
        errdefer self.gpa.free(owned);
        try self.tables.append(self.gpa, .{ .locale = owned, .file = file });
    }

    /// Choose `locale`, reading its table through `resources`: its own, or else its language's
    /// (`fr` for `fr-CA`). Fails with `UnknownLocale` when neither was added, and with the read's
    /// or the file's error (`InvalidLocaleTable` when it isn't keys and strings); the locale in
    /// use then stays as it was.
    ///
    /// ```zig
    /// try app.localization.setLocale(app.resources(), "fr-CA");
    /// ```
    pub fn setLocale(self: *Localization, resources: Resources, locale: []const u8) !void {
        try validateLocale(locale);
        const table = self.tableFor(locale) orelse return error.UnknownLocale;
        const source = try resources.read(self.gpa, table.file);
        defer self.gpa.free(source);

        // Read the new table whole before letting go of the old one.
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        var entries: std.StringHashMapUnmanaged([]const u8) = .empty;
        try readTable(arena.allocator(), source, &entries);
        const chosen = try arena.allocator().dupe(u8, table.locale);
        self.forgetLoaded();
        self.loaded = arena;
        self.entries = entries;
        self.current = chosen;
    }

    /// The locale in use, as its table was added; null before `setLocale`.
    pub fn currentLocale(self: *const Localization) ?[]const u8 {
        return self.current;
    }

    /// `key`'s text in the locale in use, borrowed until the locale changes; null when its table
    /// has no such key (or none is chosen).
    ///
    /// ```zig
    /// const label = app.localization.lookup("menu.play") orelse "Play";
    /// ```
    pub fn lookup(self: *const Localization, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    /// A copy of `key`'s text in the locale in use, allocated with `gpa`. Fails with
    /// `NoLocale` before `setLocale`, and `MissingTranslation` when the table lacks the key: the
    /// key itself is never handed back as its text.
    ///
    /// ```zig
    /// const label = try app.localization.text(gpa, "menu.play");
    /// defer gpa.free(label);
    /// ```
    pub fn text(self: *const Localization, gpa: std.mem.Allocator, key: []const u8) ![]u8 {
        if (self.current == null) return error.NoLocale;
        const found = self.lookup(key) orelse return error.MissingTranslation;
        return gpa.dupe(u8, found);
    }

    /// The table for `locale`, or else for its language.
    fn tableFor(self: *const Localization, wanted: []const u8) ?Table {
        for (self.tables.items) |table| if (std.ascii.eqlIgnoreCase(table.locale, wanted)) return table;
        const language_end = std.mem.indexOfAny(u8, wanted, "-_") orelse return null;
        const language = wanted[0..language_end];
        for (self.tables.items) |table| if (std.ascii.eqlIgnoreCase(table.locale, language)) return table;
        return null;
    }

    fn forgetLoaded(self: *Localization) void {
        if (self.loaded) |*arena| arena.deinit();
        self.loaded = null;
        self.entries = .empty;
        self.current = null;
    }
};

fn validateLocale(locale: []const u8) !void {
    if (locale.len == 0 or locale.len > max_locale_len) return error.InvalidLocale;
    for (locale) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidLocale;
}

/// `source`'s keys and text into `entries`, allocated in `arena`: a ZON struct whose every field
/// is a string.
fn readTable(arena: std.mem.Allocator, source: [:0]const u8, entries: *std.StringHashMapUnmanaged([]const u8)) !void {
    var ast = try std.zig.Ast.parse(arena, source, .{ .mode = .zon });
    defer ast.deinit(arena);
    const zoir = try std.zig.ZonGen.generate(arena, ast, .{});
    defer zoir.deinit(arena);
    if (zoir.hasCompileErrors()) return error.InvalidLocaleTable;
    switch (std.zig.Zoir.Node.Index.root.get(&zoir)) {
        .empty_literal => {},
        .struct_literal => |table| for (table.names, 0..) |name, at| {
            const value = switch (table.vals.at(@intCast(at)).get(&zoir)) {
                .string_literal => |string| string,
                else => return error.InvalidLocaleTable,
            };
            try entries.put(arena, try arena.dupe(u8, name.get(&zoir)), try arena.dupe(u8, value));
        },
        else => return error.InvalidLocaleTable,
    }
}

test "a locale's table is read, a regional locale falls back to its language, and missing keys stay missing" {
    const assets = @import("eggy_assets");
    const Source = struct {
        fn read(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8) ![:0]u8 {
            return gpa.dupeSentinel(u8, ".{ .@\"menu.play\" = \"Jouer\", .quit = \"Quitter\" }", 0);
        }
        fn model(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !assets.Model {
            return error.NotPackaged;
        }
        fn image(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !assets.Texture {
            return error.NotPackaged;
        }
    };
    var context: u8 = 0;
    const resources = Resources.from(&context, Source.read, Source.model, Source.image);
    var localization = Localization{ .gpa = std.testing.allocator };
    defer localization.deinit();

    try std.testing.expectError(error.NoLocale, localization.text(std.testing.allocator, "quit"));
    try localization.addTable("fr", .init("locales/fr.zon"));
    try std.testing.expectError(error.UnknownLocale, localization.setLocale(resources, "de"));
    try localization.setLocale(resources, "fr-CA");
    try std.testing.expectEqualStrings("fr", localization.currentLocale().?);
    try std.testing.expectEqualStrings("Jouer", localization.lookup("menu.play").?);
    const quit = try localization.text(std.testing.allocator, "quit");
    defer std.testing.allocator.free(quit);
    try std.testing.expectEqualStrings("Quitter", quit);
    try std.testing.expectError(error.MissingTranslation, localization.text(std.testing.allocator, "menu.options"));
    try std.testing.expectError(error.InvalidLocale, localization.addTable("fr fr", .init("locales/fr.zon")));
}

test "a table that isn't keys and strings is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var entries: std.StringHashMapUnmanaged([]const u8) = .empty;
    try std.testing.expectError(error.InvalidLocaleTable, readTable(arena.allocator(), ".{ .play = 3 }", &entries));
    try std.testing.expectError(error.InvalidLocaleTable, readTable(arena.allocator(), ".{ \"a\", \"b\" }", &entries));
}
