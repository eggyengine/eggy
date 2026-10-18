//! Checks for pages in tests: everything laid out inside the window, and every unwrapped line
//! of text inside its box, so a long name or a narrow panel can't push the editor's UI out of
//! shape unnoticed.
const std = @import("std");
const ui = @import("eggy").ui;
const L = ui.Layout;

/// Allowance for rounding.
const slack: f32 = 0.5;

/// Fail if any element of `root` (laid out in `viewport`) reaches past the viewport's sides,
/// or holds text wider than itself.
/// Test-only editor helper: borrows a laid-out tree and loaded font, measuring logical points
/// with 0.5-point slack. Checks horizontal bounds, not height/scroll clipping; prints a
/// diagnostic and returns `ElementOutsideWindow` or `TextOverflows` on failure.
///
/// ```zig
/// // After the test's context.render() has produced a laid-out last_root:
/// try ui_checks.expectFits(context.last_root.?, context.font, viewport);
/// ```
pub fn expectFits(root: *const L.Element, font: *const ui.Font, viewport: ui.Rect) !void {
    try visit(root, font, viewport);
}

fn visit(element: *const L.Element, font: *const ui.Font, viewport: ui.Rect) !void {
    const box = element.bounds;
    if (box.w > 0 and box.h > 0) {
        if (box.x < viewport.x - slack or box.x + box.w > viewport.x + viewport.w + slack) {
            std.debug.print("{s} at x {d:.1}, {d:.1} wide, leaves the {d:.0}-wide window\n", .{ describe(element), box.x, box.w, viewport.w });
            return error.ElementOutsideWindow;
        }
        const needed: f32 = switch (element.paint_kind) {
            .text => |text| if (text.wrap) 0 else font.measure(text.value, text.size),
            .menu_item => |item| font.measure(item.label, if (item.size == .sm) 12 else 14) + (if (item.shortcut.len > 0) font.measure(item.shortcut, if (item.size == .sm) 11 else 13) + 12 else 0) + 16,
            .button => |button| if (button.label.len == 0) 0 else font.measure(button.label, if (button.size == .sm) 12 else 14) + (if (button.size == .sm) @as(f32, 16) else 32),
            else => 0,
        };
        if (needed > box.w + slack) {
            std.debug.print("{s} needs {d:.1} but has {d:.1}\n", .{ describe(element), needed, box.w });
            return error.TextOverflows;
        }
    }
    for (element.children) |child| try visit(child, font, viewport);
}

fn describe(element: *const L.Element) []const u8 {
    return switch (element.paint_kind) {
        .text => |text| text.value,
        .menu_item => |item| item.label,
        .button => |button| button.label,
        else => @tagName(element.paint_kind),
    };
}

test "a box too narrow for its text is caught" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 60, .h = 100 };
    const root = try b.node(0, .{ .width = 60 }, .none, &.{try b.node(0, .{ .width = 50 }, .{ .text = .{ .value = "A much longer line than fits" } }, &.{})});
    root.layout(viewport, &font);
    try std.testing.expectError(error.TextOverflows, expectFits(root, &font, viewport));
}
