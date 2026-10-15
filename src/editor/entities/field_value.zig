//! A field's value as the Inspector gets it, ZON text, read part by part (`Value`) and changed
//! one part at a time with the rest of the text kept as it is (`replace`). `defaultText` makes
//! the text a part starts with, for a union variant just picked.
const std = @import("std");
const eggy = @import("eggy");
const Zoir = std.zig.Zoir;
const Part = eggy.components.Part;

/// A node of a `Value`: the whole of it, or a part inside.
pub const Node = Zoir.Node.Index;

pub const Value = struct {
    source: [:0]const u8,
    ast: std.zig.Ast,
    zoir: Zoir,

    /// `zon` parsed, in `arena`; null when it isn't ZON.
    pub fn parse(arena: std.mem.Allocator, zon: []const u8) ?Value {
        const source = arena.dupeZ(u8, zon) catch return null;
        const ast = std.zig.Ast.parse(arena, source, .zon) catch return null;
        if (ast.errors.len > 0) return null;
        const zoir = std.zig.ZonGen.generate(arena, ast, .{ .parse_str_lits = true }) catch return null;
        if (zoir.hasCompileErrors()) return null;
        return .{ .source = source, .ast = ast, .zoir = zoir };
    }

    pub fn get(self: *const Value, node: Node) Zoir.Node {
        return node.get(self.zoir);
    }

    /// The node's own text.
    pub fn text(self: *const Value, node: Node) []const u8 {
        return self.ast.getNodeSource(node.getAstNode(self.zoir));
    }

    /// A number node's value; null for anything else.
    pub fn number(self: *const Value, node: Node) ?f64 {
        return switch (self.get(node)) {
            .int_literal => |int| switch (int) {
                .small => |small| @floatFromInt(small),
                .big => |big| big.toFloat(f64, .nearest_even)[0],
            },
            .float_literal => |float| @floatCast(float),
            .char_literal => |char| @floatFromInt(char),
            .pos_inf => std.math.inf(f64),
            .neg_inf => -std.math.inf(f64),
            .nan => std.math.nan(f64),
            else => null,
        };
    }

    /// The `index`th element of a list (`.{ a, b }`), or field of a struct (`.{ .x = a }`).
    pub fn child(self: *const Value, node: Node, index: usize) ?Node {
        const range = switch (self.get(node)) {
            .array_literal => |range| range,
            .struct_literal => |literal| literal.vals,
            else => return null,
        };
        if (index >= range.len) return null;
        return range.at(@intCast(index));
    }

    /// The field named `name` of a struct node.
    pub fn field(self: *const Value, node: Node, name: []const u8) ?Node {
        const literal = switch (self.get(node)) {
            .struct_literal => |literal| literal,
            else => return null,
        };
        for (literal.names, 0..) |field_name, i| {
            if (std.mem.eql(u8, field_name.get(self.zoir), name)) return literal.vals.at(@intCast(i));
        }
        return null;
    }

    /// A union node's tag and its payload: `.cube` is `cube` with none, `.{ .model = x }`
    /// is `model` with `x`.
    pub fn variant(self: *const Value, node: Node) ?struct { tag: []const u8, payload: ?Node } {
        return switch (self.get(node)) {
            .enum_literal => |tag| .{ .tag = tag.get(self.zoir), .payload = null },
            .struct_literal => |literal| if (literal.names.len == 1) .{ .tag = literal.names[0].get(self.zoir), .payload = literal.vals.at(0) } else null,
            else => null,
        };
    }

    /// The first numbers under `node`, depth first, into `out`; returns how many were found.
    pub fn numbers(self: *const Value, node: Node, out: []Node) usize {
        var found: usize = 0;
        self.collectNumbers(node, out, &found);
        return found;
    }

    fn collectNumbers(self: *const Value, node: Node, out: []Node, found: *usize) void {
        if (found.* == out.len) return;
        if (self.number(node) != null) {
            out[found.*] = node;
            found.* += 1;
            return;
        }
        var index: usize = 0;
        while (self.child(node, index)) |inner| : (index += 1) self.collectNumbers(inner, out, found);
    }

    /// The whole value's text with `node`'s replaced by `replacement`, in `arena`.
    pub fn replace(self: *const Value, arena: std.mem.Allocator, node: Node, replacement: []const u8) ![]const u8 {
        const old = self.text(node);
        const start = @intFromPtr(old.ptr) - @intFromPtr(self.source.ptr);
        return std.mem.concat(arena, u8, &.{ self.source[0..start], replacement, self.source[start + old.len ..] });
    }

    /// The whole value's text with each of `nodes` replaced by the matching `replacements`, in
    /// `arena`. The nodes mustn't hold one another.
    pub fn replaceAll(self: *const Value, arena: std.mem.Allocator, nodes: []const Node, replacements: []const []const u8) ![]const u8 {
        // Spliced from the last in the text to the first, so earlier offsets stay put.
        var order: [8]usize = undefined;
        for (order[0..nodes.len], 0..) |*slot, i| slot.* = i;
        const Sort = struct {
            value: *const Value,
            nodes: []const Node,
            fn later(context: @This(), a: usize, b: usize) bool {
                return @intFromPtr(context.value.text(context.nodes[a]).ptr) > @intFromPtr(context.value.text(context.nodes[b]).ptr);
            }
        };
        std.mem.sort(usize, order[0..nodes.len], Sort{ .value = self, .nodes = nodes }, Sort.later);
        var result: []const u8 = self.source;
        for (order[0..nodes.len]) |i| {
            const old = self.text(nodes[i]);
            const start = @intFromPtr(old.ptr) - @intFromPtr(self.source.ptr);
            result = try std.mem.concat(arena, u8, &.{ result[0..start], replacements[i], result[start + old.len ..] });
        }
        return result;
    }
};

/// `number` as ZON for a part of kind `kind` (`.int` or `.float`): whole for an int, which is
/// kept at 0 or above when `unsigned`.
pub fn numberText(arena: std.mem.Allocator, number: f64, part: Part) []const u8 {
    if (part.kind == .int) {
        const whole = @round(if (part.unsigned) @max(number, 0) else number);
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(std.math.clamp(whole, -9.0e18, 9.0e18)))}) catch "0";
    }
    // As an f32, so steps of 0.1 read 0.1 rather than 0.10000000149.
    if (!std.math.isFinite(number)) return "0";
    return std.fmt.allocPrint(arena, "{d}", .{@as(f32, @floatCast(number))}) catch "0";
}

/// The ZON a value of part `parts[index]` starts with: zeroes, false, the first tag, nothing set.
pub fn defaultText(arena: std.mem.Allocator, parts: []const Part, index: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeDefault(&out.writer, parts, index);
    return out.written();
}

fn writeDefault(writer: *std.Io.Writer, parts: []const Part, index: usize) std.Io.Writer.Error!void {
    const part = parts[index];
    switch (part.kind) {
        .bool => try writer.writeAll("false"),
        .int, .float => try writer.writeAll("0"),
        .@"enum" => try writer.print(".{s}", .{if (part.option_count > 0) std.mem.span(part.options[0]) else "_"}),
        .entity => try writer.writeAll("null"),
        .asset => try writer.writeAll("\"\""),
        .optional => try writer.writeAll("null"),
        .quaternion => try writer.writeAll(".{ .v = .{ 0, 0, 0, 1 } }"),
        .vector, .color => {
            const labels = if (part.kind == .color) "rgba" else "xyzw";
            try writer.writeAll(".{ ");
            for (0..part.len) |i| {
                if (i > 0) try writer.writeAll(", ");
                if (part.named) try writer.print(".{c} = ", .{labels[i]});
                // Colours start opaque white rather than black.
                try writer.writeAll(if (part.kind == .color) "1" else "0");
            }
            try writer.writeAll(" }");
        },
        .array => {
            try writer.writeAll(".{ ");
            for (0..part.len) |i| {
                if (i > 0) try writer.writeAll(", ");
                try writeDefault(writer, parts, part.first);
            }
            try writer.writeAll(" }");
        },
        .@"struct" => {
            try writer.writeAll(".{ ");
            for (part.children(parts), 0..) |inner, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print(".{s} = ", .{std.mem.span(inner.name)});
                try writeDefault(writer, parts, part.first + i);
            }
            try writer.writeAll(" }");
        },
        .@"union" => try writeVariant(writer, parts, index, 0),
        .none, .other => try writer.writeAll(".{}"),
    }
}

/// The ZON for union `parts[index]` set to its variant `variant`, with that variant's defaults.
pub fn variantText(arena: std.mem.Allocator, parts: []const Part, index: usize, variant: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeVariant(&out.writer, parts, index, variant);
    return out.written();
}

fn writeVariant(writer: *std.Io.Writer, parts: []const Part, index: usize, variant: usize) std.Io.Writer.Error!void {
    const part = parts[index];
    if (part.count == 0) return writer.writeAll(".{}");
    const chosen = parts[part.first + variant];
    if (chosen.kind == .none) return writer.print(".{s}", .{std.mem.span(chosen.name)});
    try writer.print(".{{ .{s} = ", .{std.mem.span(chosen.name)});
    try writeDefault(writer, parts, part.first + variant);
    try writer.writeAll(" }");
}

test "a part of a value changes, and the rest of its text stays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = Value.parse(arena.allocator(), ".{.position=.{1,-2.5,3},.shape=.cube}").?;
    const position = value.field(.root, "position").?;
    var numbers: [4]Node = undefined;
    try std.testing.expectEqual(@as(usize, 3), value.numbers(position, &numbers));
    try std.testing.expectEqual(@as(f64, -2.5), value.number(numbers[1]).?);
    try std.testing.expectEqualStrings(".{.position=.{1,7,3},.shape=.cube}", try value.replace(arena.allocator(), numbers[1], "7"));
    try std.testing.expectEqualStrings(".{.position=.{9,-2.5,8},.shape=.cube}", try value.replaceAll(arena.allocator(), &.{ numbers[0], numbers[2] }, &.{ "9", "8" }));
    try std.testing.expectEqualStrings("cube", value.variant(value.field(.root, "shape").?).?.tag);
    try std.testing.expect(Value.parse(arena.allocator(), ".{ 1, ") == null);
}

test "numbers are written for their part: whole for ints, short for floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("0.1", numberText(arena.allocator(), 0.1, .{ .kind = .float }));
    try std.testing.expectEqualStrings("3", numberText(arena.allocator(), 2.6, .{ .kind = .int }));
    try std.testing.expectEqualStrings("0", numberText(arena.allocator(), -4, .{ .kind = .int, .unsigned = true }));
}

test "a union variant starts with its payload's defaults" {
    const Shape = union(enum) { cube, model: eggy.AssetRef(.model), size: struct { x: f32 = 1, on: bool = true } };
    const Holder = struct { shape: Shape = .cube };
    const parts = eggy.components.Registry(&.{Holder}, &.{"game"}).infos[0].fields[0].parts;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(".cube", try variantText(arena.allocator(), parts, 0, 0));
    try std.testing.expectEqualStrings(".{ .model = \"\" }", try variantText(arena.allocator(), parts, 0, 1));
    try std.testing.expectEqualStrings(".{ .size = .{ .x = 0, .on = false } }", try variantText(arena.allocator(), parts, 0, 2));
}
