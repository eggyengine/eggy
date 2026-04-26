const math = @import("../math.zig");

pub const Colour = struct {
    r: f32 = 0.0,
    g: f32 = 0.0,
    b: f32 = 0.0,
    a: f32 = 1.0,

    const Error = error {
        InvalidHexFormat,
    };

    pub fn from_hex(hex: []const u8) !Colour {
        var hex_clean = hex;
        
        if (hex.len > 0 and hex[0] == '#') {
            hex_clean = hex[1..];
        }
        
        var r: u8 = 0;
        var g: u8 = 0;
        var b: u8 = 0;
        var a: u8 = 255;
        
        switch (hex_clean.len) {
            // RGB shorthand (#F0A -> #FF00AA)
            3 => {
                r = parseHexDigit(hex_clean[0]) * 17; // 0xF * 17 = 0xFF
                g = parseHexDigit(hex_clean[1]) * 17;
                b = parseHexDigit(hex_clean[2]) * 17;
            },
            // RGBA shorthand (#F0A8)
            4 => {
                r = parseHexDigit(hex_clean[0]) * 17;
                g = parseHexDigit(hex_clean[1]) * 17;
                b = parseHexDigit(hex_clean[2]) * 17;
                a = parseHexDigit(hex_clean[3]) * 17;
            },
            // RRGGBB
            6 => {
                r = parseHexByte(hex_clean[0..2]);
                g = parseHexByte(hex_clean[2..4]);
                b = parseHexByte(hex_clean[4..6]);
            },
            // RRGGBBAA
            8 => {
                r = parseHexByte(hex_clean[0..2]);
                g = parseHexByte(hex_clean[2..4]);
                b = parseHexByte(hex_clean[4..6]);
                a = parseHexByte(hex_clean[6..8]);
            },
            else => {
                return error.InvalidHexFormat;
            },
        }
        
        return from_u8_alpha(r, g, b, a);
    }

    fn parseHexDigit(c: u8) u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => 0,
        };
    }

    fn parseHexByte(hex: []const u8) u8 {
        return (parseHexDigit(hex[0]) << 4) | parseHexDigit(hex[1]);
    }

    pub fn from_f32_alpha(r: f32, g: f32, b: f32, a: f32) Colour {
        return Colour{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn from_f32(r: f32, g: f32, b: f32) Colour {
        return Colour{ .r = r, .g = g, .b = b, .a = 1.0 };
    }

    pub fn from_u8_alpha(r: u8, g: u8, b: u8, a: u8) Colour {
        return Colour{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }

    pub fn from_u8(r: u8, g: u8, b: u8) Colour {
        return from_u8_alpha(r, g, b, 255);
    }

    pub fn to_vec4(self: @This()) math.Vec4 {
        return math.Vec4 {
            .x = self.r,
            .y = self.g,
            .z = self.b,
            .w = self.a,
        };
    }

    pub const black = Colour{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    pub const white = Colour{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    pub const cornflower_blue = Colour{ .r = 0.392, .g = 0.584, .b = 0.929, .a = 1.0 };
    pub const transparent = Colour {.r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0};
};