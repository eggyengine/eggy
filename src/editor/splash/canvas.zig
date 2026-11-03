//! Drawing the splash screen with SDL's 2D renderer, which is ready in moments where the
//! editor's own takes a while: textures from pixels and text, rounded shapes, bands and lines,
//! in logical pixels, each texture made at the window's pixel density so it stays sharp.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const c = eggy.sdl_adapter.sdl.c;
const icon = @import("../icon.zig");

/// Straight-alpha RGBA, 0 to 1.
pub const Color = [4]f32;

/// `rgb` (0xRRGGBB), opaque.
pub fn hex(rgb: u24) Color {
    return .{
        @as(f32, @floatFromInt(rgb >> 16)) / 255,
        @as(f32, @floatFromInt((rgb >> 8) & 0xff)) / 255,
        @as(f32, @floatFromInt(rgb & 0xff)) / 255,
        1,
    };
}

/// `color` with its alpha scaled by `alpha`.
pub fn fade(color: Color, alpha: f32) Color {
    return .{ color[0], color[1], color[2], color[3] * alpha };
}

/// `from` blended towards `to` by `t` (0 to 1).
pub fn mix(from: Color, to: Color, t: f32) Color {
    var out: Color = undefined;
    for (&out, from, to) |*channel, a, b| channel.* = std.math.lerp(a, b, t);
    return out;
}

/// A rectangle in logical pixels.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    /// The part of `self` inside `clip`, or null when none is.
    fn intersect(self: Rect, clip: Rect) ?Rect {
        const left = @max(self.x, clip.x);
        const top = @max(self.y, clip.y);
        const right = @min(self.x + self.w, clip.x + clip.w);
        const bottom = @min(self.y + self.h, clip.y + clip.h);
        if (right <= left or bottom <= top) return null;
        return .{ .x = left, .y = top, .w = right - left, .h = bottom - top };
    }

    fn sdl(self: Rect) c.SDL_FRect {
        return .{ .x = self.x, .y = self.y, .w = self.w, .h = self.h };
    }
};

/// A texture, white unless made from coloured pixels, to tint as it is drawn.
pub const Image = struct {
    texture: *c.SDL_Texture,
    /// Its size in logical pixels.
    width: f32,
    height: f32,
    /// How far its drawing starts before where it is placed, as a glow's does.
    margin: f32 = 0,

    pub fn deinit(self: Image) void {
        c.SDL_DestroyTexture(self.texture);
    }
};

/// What `Canvas.rounded` makes of a rounded rectangle.
pub const Shape = union(enum) {
    fill,
    /// Its edge only, this many logical pixels wide.
    ring: f32,
    /// A soft glow past its edges, fading over this many logical pixels.
    glow: f32,
};

pub const Canvas = struct {
    gpa: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    /// Device pixels per logical pixel.
    density: f32,

    /// A texture of `width` by `height` straight-alpha RGBA `pixels` (device pixels), drawn
    /// `density` times smaller; `nearest` keeps pixel art crisp.
    pub fn image(self: Canvas, pixels: []const u8, width: u32, height: u32, filter: enum { linear, nearest }) !Image {
        const texture = c.SDL_CreateTexture(self.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, @intCast(width), @intCast(height)) orelse return error.SdlError;
        errdefer c.SDL_DestroyTexture(texture);
        if (!c.SDL_UpdateTexture(texture, null, pixels.ptr, @intCast(width * 4))) return error.SdlError;
        _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetTextureScaleMode(texture, if (filter == .nearest) c.SDL_SCALEMODE_NEAREST else c.SDL_SCALEMODE_LINEAR);
        return .{ .texture = texture, .width = @as(f32, @floatFromInt(width)) / self.density, .height = @as(f32, @floatFromInt(height)) / self.density };
    }

    /// `value` in `font` at `size` logical pixels, white with its coverage in alpha, as tall as
    /// a line of it.
    pub fn text(self: Canvas, font: *ui.Font, value: []const u8, size: f32) !Image {
        font.dpi_scale = self.density;
        const strike = font.strike(size);
        // The pen's advance first, for the texture's width.
        var advance: f32 = 0;
        var i: usize = 0;
        while (i < value.len) advance += font.next(strike, value, &i).advance;
        const width: u32 = @max(1, @as(u32, @intFromFloat(@ceil(advance))) + 2);
        const height: u32 = @intFromFloat(@ceil(strike.size * 1.4));
        const pixels = try self.gpa.alloc(u8, width * height * 4);
        defer self.gpa.free(pixels);
        for (0..width * height) |p| pixels[p * 4 ..][0..4].* = .{ 255, 255, 255, 0 };
        // Each glyph's coverage from the font's atlas, its capitals centred in the line.
        const baseline = @round((@as(f32, @floatFromInt(height)) + strike.size * 0.7) / 2);
        var pen: f32 = 1;
        i = 0;
        while (i < value.len) {
            const glyph = font.next(strike, value, &i);
            defer pen += glyph.advance;
            const left: i32 = @as(i32, @intFromFloat(@round(pen))) + glyph.left;
            const top: i32 = @as(i32, @intFromFloat(baseline)) - glyph.top;
            for (0..glyph.h) |row| for (0..glyph.w) |column| {
                const x = left + @as(i32, @intCast(column));
                const y = top + @as(i32, @intCast(row));
                if (x < 0 or y < 0 or x >= width or y >= height) continue;
                const coverage = font.pixels[(@as(usize, glyph.y) + row) * ui.atlas_width + glyph.x + column];
                const alpha = &pixels[(@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))) * 4 + 3];
                alpha.* = @max(alpha.*, coverage);
            };
        }
        // Drawn pixel for pixel (see `draw`), so sampling between them would only blur it.
        return self.image(pixels, width, height, .nearest);
    }

    /// A white `width` by `height` rectangle (logical pixels) with corners rounded by `radius`,
    /// as `shape` says.
    pub fn rounded(self: Canvas, width: f32, height: f32, radius: f32, shape: Shape) !Image {
        const margin: f32 = switch (shape) {
            .glow => |blur| blur + 2,
            else => 0,
        };
        const d = self.density;
        const total_w: u32 = @intFromFloat(@ceil((width + 2 * margin) * d));
        const total_h: u32 = @intFromFloat(@ceil((height + 2 * margin) * d));
        const pixels = try self.gpa.alloc(u8, total_w * total_h * 4);
        defer self.gpa.free(pixels);
        for (0..total_h) |y| for (0..total_w) |x| {
            const distance = icon.roundedDistance(
                @as(f32, @floatFromInt(x)) - margin * d,
                @as(f32, @floatFromInt(y)) - margin * d,
                width * d,
                height * d,
                radius * d,
            );
            const coverage: f32 = switch (shape) {
                .fill => std.math.clamp(0.5 - distance, 0, 1),
                .ring => |border| std.math.clamp(0.5 - distance, 0, 1) - std.math.clamp(0.5 - distance - border * d, 0, 1),
                // A box shadow: whole under the shape, falling off as a Gaussian past its edge.
                .glow => |blur| if (distance <= 0) 1 else @exp(-(distance * distance) / (2 * (blur * d / 2) * (blur * d / 2))),
            };
            pixels[(y * total_w + x) * 4 ..][0..4].* = .{ 255, 255, 255, @intFromFloat(@round(std.math.clamp(coverage, 0, 1) * 255)) };
        };
        var made = try self.image(pixels, total_w, total_h, .linear);
        made.margin = margin;
        return made;
    }

    /// Draw `drawn` tinted by `color` at `x`, `y`, only the part inside `clip` when given.
    /// It lands on whole device pixels, so text stays sharp.
    pub fn draw(self: Canvas, drawn: Image, x: f32, y: f32, color: Color, clip: ?Rect) void {
        const whole: Rect = .{ .x = self.snap(x - drawn.margin), .y = self.snap(y - drawn.margin), .w = drawn.width, .h = drawn.height };
        const shown = if (clip) |area| whole.intersect(area) orelse return else whole;
        // The same part of the texture, in its own pixels.
        const source: c.SDL_FRect = .{
            .x = (shown.x - whole.x) * self.density,
            .y = (shown.y - whole.y) * self.density,
            .w = shown.w * self.density,
            .h = shown.h * self.density,
        };
        tint(drawn, color);
        _ = c.SDL_RenderTexture(self.renderer, drawn.texture, &source, &shown.sdl());
    }

    fn snap(self: Canvas, at: f32) f32 {
        return @round(at * self.density) / self.density;
    }

    /// Draw `drawn` tinted by `color`, stretched over `area`.
    pub fn drawStretched(self: Canvas, drawn: Image, area: Rect, color: Color) void {
        tint(drawn, color);
        _ = c.SDL_RenderTexture(self.renderer, drawn.texture, null, &area.sdl());
    }

    /// Fill `area` with `color`.
    pub fn fill(self: Canvas, area: Rect, color: Color) void {
        _ = c.SDL_SetRenderDrawColorFloat(self.renderer, color[0], color[1], color[2], color[3]);
        _ = c.SDL_RenderFillRect(self.renderer, &area.sdl());
    }

    /// A band `width` wide from `x` down `area`'s height, clear at its edges and `color` in its
    /// middle, only where it crosses `area`.
    pub fn band(self: Canvas, area: Rect, x: f32, width: f32, color: Color) void {
        const stops = [_]f32{ x, x + width / 2, x + width };
        const alphas = [_]f32{ 0, color[3], 0 };
        for (0..2) |i| {
            const left = @max(stops[i], area.x);
            const right = @min(stops[i + 1], area.x + area.w);
            if (right <= left) continue;
            const a0 = std.math.lerp(alphas[i], alphas[i + 1], (left - stops[i]) / (stops[i + 1] - stops[i]));
            const a1 = std.math.lerp(alphas[i], alphas[i + 1], (right - stops[i]) / (stops[i + 1] - stops[i]));
            self.quad(.{
                .{ left, area.y },
                .{ right, area.y },
                .{ right, area.y + area.h },
                .{ left, area.y + area.h },
            }, .{ withAlpha(color, a0), withAlpha(color, a1), withAlpha(color, a1), withAlpha(color, a0) });
        }
    }

    /// A straight line from `from` to `to`, `width` wide.
    pub fn line(self: Canvas, from: [2]f32, to: [2]f32, width: f32, color: Color) void {
        const dx = to[0] - from[0];
        const dy = to[1] - from[1];
        const length = @sqrt(dx * dx + dy * dy);
        if (length == 0) return;
        // Half the width out to each side, with the ends squared off past the points.
        const nx = -dy / length * width / 2;
        const ny = dx / length * width / 2;
        const ex = dx / length * width / 2;
        const ey = dy / length * width / 2;
        self.quad(.{
            .{ from[0] + nx - ex, from[1] + ny - ey },
            .{ to[0] + nx + ex, to[1] + ny + ey },
            .{ to[0] - nx + ex, to[1] - ny + ey },
            .{ from[0] - nx - ex, from[1] - ny - ey },
        }, @splat(color));
    }

    fn quad(self: Canvas, corners: [4][2]f32, colors: [4]Color) void {
        var vertices: [4]c.SDL_Vertex = undefined;
        for (&vertices, corners, colors) |*vertex, corner, color| vertex.* = .{
            .position = .{ .x = corner[0], .y = corner[1] },
            .color = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] },
            .tex_coord = .{ .x = 0, .y = 0 },
        };
        const indices = [_]c_int{ 0, 1, 2, 0, 2, 3 };
        _ = c.SDL_RenderGeometry(self.renderer, null, &vertices, vertices.len, &indices, indices.len);
    }
};

fn withAlpha(color: Color, alpha: f32) Color {
    return .{ color[0], color[1], color[2], alpha };
}

fn tint(drawn: Image, color: Color) void {
    _ = c.SDL_SetTextureColorModFloat(drawn.texture, color[0], color[1], color[2]);
    _ = c.SDL_SetTextureAlphaModFloat(drawn.texture, color[3]);
}
