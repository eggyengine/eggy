//! The UI every editor host draws with: a compact context in the system's theme, its font with
//! Nerd Font symbols and colour emoji, and the monospace face beside it.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;

pub const Style = struct {
    /// Owns the UI font; the editor's other contexts and windows borrow it.
    context: ui.Context,
    /// JetBrains Mono, sharing the UI font's atlas: for paths, code and terminal output.
    mono: *ui.Font,

    /// Set up the style for windows presenting in `color_format`; `io` finds the system's emoji
    /// font. Allocation and font errors propagate. Free with `deinit`.
    ///
    /// ```zig
    /// var style = try Style.init(gpa, io, graphics.color_format);
    /// defer style.deinit(gpa);
    /// ```
    pub fn init(gpa: std.mem.Allocator, io: std.Io, color_format: eggy.vit.Format) !Style {
        var context = try ui.Context.init(gpa);
        errdefer context.deinit();
        // The editor's pages and windows are a tool's: compact, with small text.
        context.density = .compact;
        context.srgb_target = @import("weeoui_vitellus").isSrgb(color_format);
        context.theme = @import("weeoui_sdl3").systemTheme();
        const mono = try gpa.create(ui.Font);
        errdefer gpa.destroy(mono);
        mono.* = try ui.Font.initCompanion(gpa, @embedFile("mono_font"), context.font, &.{ 10, 11, 12, 13, 14, 15, 16, 18, 20, 24 });
        errdefer mono.deinit();
        // Nerd Font icons for the characters the faces lack in private-use areas, in both.
        try context.font.setSymbolsFont(@embedFile("symbols_font"));
        try mono.setSymbolsFont(@embedFile("symbols_font"));
        // Colour emoji from the system's font, where one is installed; '?' otherwise.
        _ = context.font.loadSystemEmoji(io);
        return .{ .context = context, .mono = mono };
    }

    /// Free the monospace face, then the context and the font it owns.
    pub fn deinit(self: *Style, gpa: std.mem.Allocator) void {
        self.mono.deinit();
        gpa.destroy(self.mono);
        self.context.deinit();
    }
};
