//! The Assets panel's icons: Lucide's (lucide.dev, ISC licence, see `icons/LICENSE`), drawn
//! at 48 pixels in two tints, one for dark themes and one for light, as the UI draws images as
//! they are.
const std = @import("std");
const ui = @import("eggy").ui;
const Kind = @import("listing.zig").Kind;

pub const Icon = enum {
    folder,
    folder_open,
    scene,
    code,
    text,
    image,
    audio,
    file,
    model,
    clip,
    ui,
    up,
    list,
    grid,

    /// Choose the editor icon for a listing kind; input maps share the text-file icon.
    ///
    /// ```zig
    /// const icon = Icon.of(.scene); // .scene
    /// ```
    pub fn of(kind: Kind) Icon {
        return switch (kind) {
            .folder => .folder,
            .scene => .scene,
            .code => .code,
            .text, .input_map => .text,
            .image, .material => .image,
            .animation => .clip,
            .ui => .ui,
            .model => .model,
            .audio => .audio,
            .file => .file,
        };
    }

    /// The Lucide icon it is drawn with.
    fn lucideName(icon: Icon) []const u8 {
        return switch (icon) {
            .folder => "folder",
            .folder_open => "folder-open",
            .scene => "clapperboard",
            .code => "file-code",
            .text => "file-text",
            .image => "image",
            .audio => "music",
            .file => "file",
            .model => "box",
            .clip => "film",
            .ui => "layout-template",
            .up => "corner-left-up",
            .list => "list",
            .grid => "layout-grid",
        };
    }
};

const count = std.meta.fields(Icon).len;

pub const Icons = struct {
    /// Each icon for dark themes, then for light ones; null where it didn't load.
    on_dark: [count]?ui.Image = @splat(null),
    on_light: [count]?ui.Image = @splat(null),

    /// Load every icon into `font`'s atlas. An icon that fails to load is left blank.
    /// Editor-only: keep the font alive while using the images and release them with `deinit`.
    ///
    /// ```zig
    /// // Given allocator gpa and a live UI font:
    /// var icons = Icons.load(gpa, &font);
    /// defer icons.deinit(gpa);
    /// ```
    pub fn load(gpa: std.mem.Allocator, font: *ui.Font) Icons {
        var self = Icons{};
        inline for (std.meta.fields(Icon)) |field| {
            const icon: Icon = @enumFromInt(field.value);
            const name = comptime icon.lucideName();
            self.on_dark[field.value] = ui.Image.load(gpa, font, @embedFile("icons/" ++ name ++ "-on-dark.png")) catch null;
            self.on_light[field.value] = ui.Image.load(gpa, font, @embedFile("icons/" ++ name ++ "-on-light.png")) catch null;
        }
        return self;
    }

    /// Release loaded editor images using the allocator supplied to `load`; call once.
    /// Paint values borrowing these images must no longer be in use.
    ///
    /// ```zig
    /// var icons = Icons.load(gpa, &font); // Existing allocator and live font.
    /// defer icons.deinit(gpa);
    /// ```
    pub fn deinit(self: *Icons, gpa: std.mem.Allocator) void {
        for (&self.on_dark) |*image| if (image.*) |*loaded| loaded.deinit(gpa);
        for (&self.on_light) |*image| if (image.*) |*loaded| loaded.deinit(gpa);
    }

    /// `icon`, tinted for `theme`, as layout paint; nothing where it didn't load.
    /// The returned image frame borrows this icon set and its font atlas.
    ///
    /// ```zig
    /// // Given loaded icons and the current UI theme:
    /// const folder_paint = icons.paint(.folder, theme);
    /// ```
    pub fn paint(self: *const Icons, icon: Icon, theme: ui.Theme) ui.Layout.Paint {
        const dark = (theme.background[0] + theme.background[1] + theme.background[2]) / 3 < 0.5;
        const image = (if (dark) self.on_dark else self.on_light)[@intFromEnum(icon)] orelse return .none;
        return .{ .image = image.frameAt(0) };
    }
};

test "every icon loads" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var icons = Icons.load(std.testing.allocator, &font);
    defer icons.deinit(std.testing.allocator);
    for (icons.on_dark, icons.on_light) |dark, light| {
        try std.testing.expect(dark != null);
        try std.testing.expect(light != null);
    }
}
