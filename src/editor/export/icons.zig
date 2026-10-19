//! The Export window's platform icons: Eggy's own platforms' (see `icons/LICENSE`), drawn at 48
//! pixels in a tint for dark themes and one for light, each plugin platform's own PNG, and the
//! folder on its folder buttons.
const std = @import("std");
const ui = @import("eggy").ui;
const platforms = @import("platforms.zig");

const Tinted = struct { on_dark: ?ui.Image = null, on_light: ?ui.Image = null };

pub const Icons = struct {
    gpa: std.mem.Allocator,
    font: *ui.Font,
    builtins: [platforms.count]Tinted = @splat(.{}),
    /// For a plugin platform without an icon of its own.
    package: Tinted = .{},
    /// For buttons that pick a folder (the Assets panel's).
    folder_icon: Tinted = .{},
    /// Plugin platforms' icons by key (owned), null where theirs didn't load.
    plugins: std.StringHashMapUnmanaged(?ui.Image) = .empty,

    /// Load Eggy's icons into `font`'s atlas; one that fails to load is left blank.
    /// Keep the font alive while the icons are used, and release them with `deinit`.
    ///
    /// ```zig
    /// var icons = Icons.load(gpa, font);
    /// defer icons.deinit();
    /// ```
    pub fn load(gpa: std.mem.Allocator, font: *ui.Font) Icons {
        var self = Icons{ .gpa = gpa, .font = font };
        inline for (std.meta.fields(platforms.Platform)) |field| {
            self.builtins[field.value] = loadTinted(gpa, font, field.name);
        }
        self.package = loadTinted(gpa, font, "plugin");
        self.folder_icon = .{
            .on_dark = ui.Image.load(gpa, font, @embedFile("../assets/icons/folder-on-dark.png")) catch null,
            .on_light = ui.Image.load(gpa, font, @embedFile("../assets/icons/folder-on-light.png")) catch null,
        };
        return self;
    }

    /// Release every icon and the plugin keys.
    pub fn deinit(self: *Icons) void {
        for (&self.builtins) |*tinted| freeTinted(self.gpa, tinted);
        freeTinted(self.gpa, &self.package);
        freeTinted(self.gpa, &self.folder_icon);
        var plugins = self.plugins.iterator();
        while (plugins.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |*image| image.deinit(self.gpa);
        }
        self.plugins.deinit(self.gpa);
    }

    /// Eggy's `platform`, tinted for `theme`, as layout paint; nothing where it didn't load.
    pub fn builtin(self: *const Icons, platform: platforms.Platform, theme: ui.Theme) ui.Layout.Paint {
        return paintTinted(self.builtins[@intFromEnum(platform)], theme);
    }

    /// A folder, tinted for `theme`, as layout paint.
    pub fn folder(self: *const Icons, theme: ui.Theme) ui.Layout.Paint {
        return paintTinted(self.folder_icon, theme);
    }

    /// The plugin platform `key`'s icon from `png`, loaded the first time it is asked for, or
    /// the package icon when it has none or it doesn't load.
    pub fn plugin(self: *Icons, key: []const u8, png: []const u8, theme: ui.Theme) ui.Layout.Paint {
        const fallback = paintTinted(self.package, theme);
        if (png.len == 0) return fallback;
        const entry = self.plugins.getOrPut(self.gpa, key) catch return fallback;
        if (!entry.found_existing) {
            entry.key_ptr.* = self.gpa.dupe(u8, key) catch {
                self.plugins.removeByPtr(entry.key_ptr);
                return fallback;
            };
            entry.value_ptr.* = ui.Image.load(self.gpa, self.font, png) catch null;
        }
        const image = entry.value_ptr.* orelse return fallback;
        return .{ .image = image.frameAt(0) };
    }
};

fn loadTinted(gpa: std.mem.Allocator, font: *ui.Font, comptime name: []const u8) Tinted {
    return .{
        .on_dark = ui.Image.load(gpa, font, @embedFile("icons/" ++ name ++ "-on-dark.png")) catch null,
        .on_light = ui.Image.load(gpa, font, @embedFile("icons/" ++ name ++ "-on-light.png")) catch null,
    };
}

fn freeTinted(gpa: std.mem.Allocator, tinted: *Tinted) void {
    if (tinted.on_dark) |*image| image.deinit(gpa);
    if (tinted.on_light) |*image| image.deinit(gpa);
}

fn paintTinted(tinted: Tinted, theme: ui.Theme) ui.Layout.Paint {
    const dark = (theme.background[0] + theme.background[1] + theme.background[2]) / 3 < 0.5;
    const image = (if (dark) tinted.on_dark else tinted.on_light) orelse return .none;
    return .{ .image = image.frameAt(0) };
}

test "every platform icon loads" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var icons = Icons.load(std.testing.allocator, &font);
    defer icons.deinit();
    for (icons.builtins ++ [_]Tinted{ icons.package, icons.folder_icon }) |tinted| {
        try std.testing.expect(tinted.on_dark != null);
        try std.testing.expect(tinted.on_light != null);
    }
}
