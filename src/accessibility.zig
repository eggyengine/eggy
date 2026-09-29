//! Connects the demo to Weeoui's AccessKit adapter: publish its tree, apply screen-reader actions.
const std = @import("std");
const ui = @import("weeoui");
const Demo = @import("ui_demo.zig").Demo;
const Adapter = ui.accesskit.Adapter;

pub fn publish(adapter: *Adapter, demo: *Demo, viewport: ui.Rect, font: *const ui.Font) !void {
    var arena = std.heap.ArenaAllocator.init(adapter.allocator);
    errdefer arena.deinit();
    const snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, font);
    adapter.update(arena, snapshot, demo.ui_scale);
}

/// Apply queued screen-reader actions to the demo. Returns true if any arrived.
pub fn applyActions(adapter: *Adapter, demo: *Demo) bool {
    var any = false;
    while (adapter.nextAction()) |action| {
        any = true;
        const accepted = switch (action) {
            .focus => |id| demo.accessibilityAction(id, .focus),
            .click => |id| demo.accessibilityAction(id, .click),
            .increment => |id| demo.accessibilityAction(id, .increment),
            .decrement => |id| demo.accessibilityAction(id, .decrement),
            .set_value => |value| demo.accessibilitySetValue(value.target, value.text()),
            .set_selection => |selection| demo.accessibilitySetSelection(selection.target, selection.anchor, selection.focus),
        };
        if (!accepted) std.log.warn("screen reader action rejected: {s}", .{@tagName(action)});
    }
    return any;
}

const test_viewport = ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 675 };

fn headless() Adapter {
    return .{ .allocator = std.testing.allocator, .name = "eggy", .arena = .init(std.testing.allocator) };
}

fn contains(adapter: *Adapter, text: []const u8) !bool {
    const dump = try ui.accesskit.debugTree(adapter, std.testing.allocator);
    defer std.testing.allocator.free(dump);
    return std.mem.indexOf(u8, dump, text) != null;
}

test "published tree includes demo labels and follows screen-reader focus" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var demo: Demo = .{};
    var adapter = headless();
    defer adapter.arena.deinit();
    try publish(&adapter, &demo, test_viewport, &font);
    for ([_][]const u8{ "Try button", "Show hints", "Details panel", "Activity over five periods", "Alert dialog" }) |label| {
        try std.testing.expect(try contains(&adapter, label));
    }
    adapter.push(.{ .click = 360 });
    try std.testing.expect(applyActions(&adapter, &demo));
    try publish(&adapter, &demo, test_viewport, &font);
    try std.testing.expectEqual(@as(u64, 360), adapter.snapshot.focus);
    try std.testing.expect(try contains(&adapter, "Overview panel"));
    try std.testing.expect(!try contains(&adapter, "Details panel"));
}

test "value and selection actions reach the bounded UTF-8 editor" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var demo: Demo = .{};
    var adapter = headless();
    defer adapter.arena.deinit();
    try publish(&adapter, &demo, test_viewport, &font);
    var value: ui.accesskit.Action = .{ .set_value = .{ .target = 300 } };
    @memcpy(value.set_value.buffer[0..4], "AéB");
    value.set_value.len = 4;
    adapter.push(value);
    adapter.push(.{ .set_selection = .{ .target = 300, .anchor = 1, .focus = 2 } });
    try std.testing.expect(applyActions(&adapter, &demo));
    try std.testing.expectEqualStrings("AéB", demo.editable[0].text.text());
    try std.testing.expectEqualStrings("é", demo.selectedText().?);
}

test "screen-reader clicks activate message and sidebar controls" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font);
    defer font.deinit();
    var demo: Demo = .{};
    var adapter = headless();
    defer adapter.arena.deinit();
    try publish(&adapter, &demo, test_viewport, &font);
    for ([_]u32{ 498, 521, 522, 533 }) |target| {
        adapter.push(.{ .click = target });
        _ = applyActions(&adapter, &demo);
        try publish(&adapter, &demo, test_viewport, &font);
    }
    try std.testing.expectEqual(@as(usize, 4), demo.message_count);
    try std.testing.expectEqual(@as(u32, 522), demo.sidebar_selection);
    try std.testing.expect(!demo.checked);
    try std.testing.expect(try contains(&adapter, "Four"));
    try std.testing.expect(try contains(&adapter, "Settings view"));
    try std.testing.expect(try contains(&adapter, "Show hints"));
}
