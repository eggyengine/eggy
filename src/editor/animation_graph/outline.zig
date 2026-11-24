//! The graph editor's outline: the graph's layers, then its parameters, each a row to pick, with
//! a button under each list to add another.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const format = eggy.assets.animation_graph;
const page_style = @import("../page_style.zig");
const Document = @import("document.zig").Document;

const plus_glyph = "\u{f067}";

/// Build the outline for `document`, `width` wide. Returns whether the document changed.
pub fn build(context: *ui.Context, document: *Document, width: f32) !bool {
    const arena = context.builder().allocator;
    const item_width = width - 24;
    var changed = false;
    context.begin(.column);

    for (document.graph().layers, 0..) |layer, index| {
        const id = context.idFor(try std.fmt.allocPrint(arena, "graph layer {d}", .{index}));
        if (context.activated(id)) document.showLayer(index);
        const detail: []const u8 = if (layer.bone.len > 0) layer.bone else if (index == 0) "whole body" else "no bone";
        page_style.navItem(context, id, layer.name, .{ .detail = detail }, document.layer == index and document.selection == .layer, item_width, layer.name);
    }
    if (document.graph().layers.len < format.max_layers and context.buttonVariant(plus_glyph ++ "  Add layer##graph add layer", .ghost)) {
        document.addLayer() catch {};
        changed = true;
    }

    context.separator();

    for (document.graph().parameters, 0..) |parameter, index| {
        const id = context.idFor(try std.fmt.allocPrint(arena, "graph parameter {d}", .{index}));
        if (context.activated(id)) document.selection = .{ .parameter = index };
        const picked = document.selection == .parameter and document.selection.parameter == index;
        page_style.navItem(context, id, parameter.name, .{ .detail = @tagName(parameter.kind) }, picked, item_width, parameter.name);
    }
    if (document.graph().parameters.len == 0) {
        context.muted("No parameters yet.");
        page_style.smallText(context, 12);
    }
    if (document.graph().parameters.len < format.max_parameters) {
        context.begin(.row);
        inline for (.{ .float, .bool, .trigger }) |kind| {
            if (context.buttonVariant(plus_glyph ++ "  " ++ @tagName(kind) ++ "##graph add " ++ @tagName(kind), .ghost)) {
                document.addParameter(kind) catch {};
                changed = true;
            }
        }
        page_style.endRow(context);
    }

    context.end();
    page_style.restyle(context, .{ .gap = 2, .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 } });
    return changed;
}
