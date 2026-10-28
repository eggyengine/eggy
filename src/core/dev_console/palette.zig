//! The dev console's own colours over the game, the same whatever theme the game's UI has.
const ui = @import("weeoui");

pub const Palette = struct {
    /// The panel, drawn at `shell_alpha` so the game still shows through.
    shell: ui.Color,
    shell_alpha: f32,
    /// The prompt's band across the bottom of the panel.
    band: ui.Color,
    /// Output, and what is typed.
    text: ui.Color,
    /// Lines typed earlier, hints and the placeholder.
    dim: ui.Color,
    /// The prompt's chevron, the panel's lower edge and the candidate Tab is on.
    yolk: ui.Color,
    /// Text over `yolk`.
    on_yolk: ui.Color,
    failure: ui.Color,

    /// `theme` with the field's colours swapped for the palette's, for weeoui to paint the
    /// prompt's text, caret and selection in.
    pub fn fieldTheme(self: Palette, theme: ui.Theme) ui.Theme {
        var field = theme;
        field.card = self.band;
        field.input = self.band;
        field.ring = self.yolk;
        field.foreground = self.text;
        field.muted_foreground = self.dim;
        field.radius = 0;
        return field;
    }
};

/// Ink violet under bone text, with Eggy's yolk for what is live.
pub const console = Palette{
    .shell = ui.rgb(0x1B, 0x19, 0x27),
    .shell_alpha = 0.94,
    .band = ui.rgb(0x26, 0x23, 0x35),
    .text = ui.rgb(0xEC, 0xE6, 0xD9),
    .dim = ui.rgb(0x8F, 0x8A, 0xA6),
    .yolk = ui.rgb(0xF5, 0xB8, 0x3D),
    .on_yolk = ui.rgb(0x1B, 0x19, 0x27),
    .failure = ui.rgb(0xFF, 0x8A, 0x7A),
};
