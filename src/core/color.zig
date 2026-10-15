//! `Color`: red, green, blue and alpha, each 0 to 1. The editor's Inspector shows a field of it
//! (or of any struct of `r`, `g`, `b` and maybe `a`) as a swatch with a box per channel.
pub const Color = extern struct {
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
    a: f32 = 1,
};
