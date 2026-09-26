//! SDL3 host for Weeoui's semantic tree, backed by native AccessKit adapters.
const std = @import("std");
const builtin = @import("builtin");
const sdl_adapter = @import("vitellus_sdl3");
const sdl3 = sdl_adapter.sdl;
const ui = @import("weeoui");
const Demo = @import("ui_demo.zig").Demo;
const Action = @import("ui_demo.zig").AccessibilityAction;
const c = @cImport({
    @cInclude("accesskit.h");
});
const text_run_id: u64 = @as(u64, 1) << 63;
const TextEvent = struct {
    value: [128]u8 = undefined,
    len: usize = 0,
    anchor: usize = 0,
    focus: usize = 0,
};

const Adapter = switch (builtin.os.tag) {
    .linux => c.accesskit_unix_adapter,
    .windows => c.accesskit_windows_subclassing_adapter,
    .macos => c.accesskit_macos_subclassing_adapter,
    else => @compileError("AccessKit desktop adapter unavailable for this target"),
};

pub const Bridge = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    arena: std.heap.ArenaAllocator,
    snapshot: ui.accessibility.Snapshot,
    scale: f32,
    event_type: @TypeOf(sdl3.events.register(1).?),
    native: ?*Adapter = null,

    pub fn init(allocator: std.mem.Allocator, window: sdl_adapter.Sdl3Window, demo: *Demo, viewport: ui.Rect, font: *const ui.Font) !*Self {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, font);
        const event_type = sdl3.events.register(1) orelse return error.NoAccessibilityEvent;
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .arena = arena, .snapshot = snapshot, .scale = demo.ui_scale, .event_type = event_type };
        const props = try window.window.getProperties();
        self.native = switch (builtin.os.tag) {
            .linux => c.accesskit_unix_adapter_new(initialTree, self, handleAction, self, deactivated, self),
            .windows => blk: {
                const hwnd = (props.win32_hwnd orelse return error.NoNativeWindow).value orelse return error.NoNativeWindow;
                break :blk c.accesskit_windows_subclassing_adapter_new(@ptrCast(@alignCast(hwnd)), initialTree, self, handleAction, self);
            },
            .macos => blk: {
                const nswindow = (props.cocoa_window orelse return error.NoNativeWindow).value orelse return error.NoNativeWindow;
                c.accesskit_macos_add_focus_forwarder_to_window_class("SDL3Window");
                break :blk c.accesskit_macos_subclassing_adapter_for_window(nswindow, initialTree, self, handleAction, self);
            },
            else => unreachable,
        } orelse return error.AccessKitInitFailed;
        errdefer switch (builtin.os.tag) {
            .linux => c.accesskit_unix_adapter_free(self.native.?),
            .windows => c.accesskit_windows_subclassing_adapter_free(self.native.?),
            .macos => c.accesskit_macos_subclassing_adapter_free(self.native.?),
            else => unreachable,
        };
        try self.windowBounds(window);
        return self;
    }

    pub fn deinit(self: *Self) void {
        switch (builtin.os.tag) {
            .linux => c.accesskit_unix_adapter_free(self.native.?),
            .windows => c.accesskit_windows_subclassing_adapter_free(self.native.?),
            .macos => c.accesskit_macos_subclassing_adapter_free(self.native.?),
            else => unreachable,
        }
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn publish(self: *Self, demo: *Demo, viewport: ui.Rect, font: *const ui.Font) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const snapshot = try demo.accessibilitySnapshot(arena.allocator(), viewport, font);
        self.lock();
        var old = self.arena;
        self.arena = arena;
        self.snapshot = snapshot;
        self.scale = demo.ui_scale;
        self.mutex.unlock();
        old.deinit();
        switch (builtin.os.tag) {
            .linux => c.accesskit_unix_adapter_update_if_active(self.native.?, updatedTree, self),
            .windows => if (c.accesskit_windows_subclassing_adapter_update_if_active(self.native.?, updatedTree, self)) |events| c.accesskit_windows_queued_events_raise(events),
            .macos => if (c.accesskit_macos_subclassing_adapter_update_if_active(self.native.?, updatedTree, self)) |events| c.accesskit_macos_queued_events_raise(events),
            else => unreachable,
        }
    }

    pub fn windowFocus(self: *Self, focused: bool) void {
        switch (builtin.os.tag) {
            .linux => c.accesskit_unix_adapter_update_window_focus_state(self.native.?, focused),
            .macos => if (c.accesskit_macos_subclassing_adapter_update_view_focus_state(self.native.?, focused)) |events| c.accesskit_macos_queued_events_raise(events),
            .windows => {},
            else => unreachable,
        }
    }

    pub fn windowBounds(self: *Self, window: sdl_adapter.Sdl3Window) !void {
        if (builtin.os.tag != .linux) return;
        const props = try window.window.getProperties();
        if (props.x11_window == null) return;
        const position = try window.window.getPosition();
        const size = try window.window.getSize();
        const borders = try window.window.getBordersSize();
        const x: f64 = @floatFromInt(position.@"0");
        const y: f64 = @floatFromInt(position.@"1");
        const w: f64 = @floatFromInt(size.@"0");
        const h: f64 = @floatFromInt(size.@"1");
        c.accesskit_unix_adapter_set_root_window_bounds(self.native.?, .{
            .x0 = x - @as(f64, @floatFromInt(borders.left)),
            .y0 = y - @as(f64, @floatFromInt(borders.top)),
            .x1 = x + w + @as(f64, @floatFromInt(borders.right)),
            .y1 = y + h + @as(f64, @floatFromInt(borders.bottom)),
        }, .{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h });
    }

    pub fn event(self: *Self, user: sdl3.events.User, demo: *Demo) bool {
        if (user.event_type != self.event_type) return false;
        if (user.code == @intFromEnum(Action.set_value) or user.code == @intFromEnum(Action.set_selection)) {
            const data: *TextEvent = @ptrCast(@alignCast(user.data2 orelse {
                std.log.warn("Missing AccessKit text event data", .{});
                return true;
            }));
            defer std.heap.page_allocator.destroy(data);
            const raw_target = @intFromPtr(user.data1 orelse return true);
            if (raw_target > std.math.maxInt(u32)) {
                std.log.warn("Invalid AccessKit text target: {d}", .{raw_target});
                return true;
            }
            const target: u32 = @intCast(raw_target);
            const success = if (user.code == @intFromEnum(Action.set_value)) demo.accessibilitySetValue(target, data.value[0..data.len]) else demo.accessibilitySetSelection(target, data.anchor, data.focus);
            if (!success) std.log.warn("AccessKit text action rejected for control {d}", .{target});
            return true;
        }
        const raw_id = @intFromPtr(user.data1 orelse return true);
        if (raw_id > std.math.maxInt(u32)) {
            std.log.warn("Invalid AccessKit target: {d}", .{raw_id});
            return true;
        }
        const id: u32 = @intCast(raw_id);
        const action: Action = switch (user.code) {
            @intFromEnum(Action.focus) => .focus,
            @intFromEnum(Action.click) => .click,
            @intFromEnum(Action.increment) => .increment,
            @intFromEnum(Action.decrement) => .decrement,
            else => {
                std.log.warn("Unknown AccessKit action event: {d}", .{user.code});
                return true;
            },
        };
        if (!demo.accessibilityAction(id, action)) std.log.warn("Unrecognized AccessKit target/action: {d}/{s}", .{ id, @tagName(action) });
        return true;
    }

    fn initialTree(userdata: ?*anyopaque) callconv(.c) ?*c.accesskit_tree_update {
        const self: *Self = @ptrCast(@alignCast(userdata.?));
        return self.updateTree(true);
    }
    fn updatedTree(userdata: ?*anyopaque) callconv(.c) ?*c.accesskit_tree_update {
        const self: *Self = @ptrCast(@alignCast(userdata.?));
        return self.updateTree(false);
    }
    fn updateTree(self: *Self, initial: bool) *c.accesskit_tree_update {
        self.lock();
        defer self.mutex.unlock();
        const update = c.accesskit_tree_update_with_capacity_and_focus(self.snapshot.nodes.len * 2, self.snapshot.focus) orelse @panic("AccessKit tree allocation failed");
        if (initial) c.accesskit_tree_update_set_tree_info(update, c.accesskit_tree_info_new(0));
        for (self.snapshot.nodes) |source| {
            const node = c.accesskit_node_new(if (source.id == 0) c.ACCESSKIT_ROLE_WINDOW else if (source.multiline and source.role == .input) c.ACCESSKIT_ROLE_MULTILINE_TEXT_INPUT else nativeRole(source.role)) orelse @panic("AccessKit node allocation failed");
            const scale: f64 = @floatCast(self.scale);
            c.accesskit_node_set_bounds(node, .{
                .x0 = @as(f64, source.bounds.x) * scale,
                .y0 = @as(f64, source.bounds.y) * scale,
                .x1 = @as(f64, source.bounds.x + source.bounds.w) * scale,
                .y1 = @as(f64, source.bounds.y + source.bounds.h) * scale,
            });
            if (source.id == 0) c.accesskit_node_set_label(node, "eggy");
            if (source.label.len != 0) c.accesskit_node_set_label_with_length(node, source.label.ptr, source.label.len);
            if (source.description.len != 0) c.accesskit_node_set_description_with_length(node, source.description.ptr, source.description.len);
            if (source.described_by) |id| c.accesskit_node_push_described_by(node, id);
            if (source.controls) |id| c.accesskit_node_push_controlled(node, id);
            if (source.value.len != 0) c.accesskit_node_set_value_with_length(node, source.value.ptr, source.value.len);
            if (source.disabled) c.accesskit_node_set_disabled(node);
            if (source.invalid) c.accesskit_node_set_invalid(node, c.ACCESSKIT_INVALID_TRUE);
            if (source.modal) c.accesskit_node_set_modal(node);
            if (source.live != .off) c.accesskit_node_set_live(node, if (source.live == .polite) c.ACCESSKIT_LIVE_POLITE else c.ACCESSKIT_LIVE_ASSERTIVE);
            if (source.role == .ignored) c.accesskit_node_set_hidden(node);
            if (source.toggled) |value| c.accesskit_node_set_toggled(node, if (value) c.ACCESSKIT_TOGGLED_TRUE else c.ACCESSKIT_TOGGLED_FALSE);
            if (source.selected) |value| c.accesskit_node_set_selected(node, value);
            if (source.expanded) |value| c.accesskit_node_set_expanded(node, value);
            if (source.numeric_value) |value| {
                c.accesskit_node_set_numeric_value(node, value);
                c.accesskit_node_set_min_numeric_value(node, 0);
                c.accesskit_node_set_max_numeric_value(node, 1);
                if (source.role == .slider) c.accesskit_node_set_numeric_value_step(node, 0.05);
            }
            for (source.children) |child| c.accesskit_node_push_child(node, child);
            if (source.role == .input and !source.disabled) {
                const child_id = text_run_id | source.id;
                const text = c.accesskit_node_new(c.ACCESSKIT_ROLE_TEXT_RUN) orelse @panic("AccessKit text run allocation failed");
                c.accesskit_node_set_value_with_length(text, source.value.ptr, source.value.len);
                const lengths = self.allocator.alloc(u8, source.value.len) catch @panic("AccessKit character allocation failed");
                defer self.allocator.free(lengths);
                var at: usize = 0;
                var characters: usize = 0;
                while (at < source.value.len) : (characters += 1) {
                    const size = std.unicode.utf8ByteSequenceLength(source.value[at]) catch unreachable;
                    lengths[characters] = size;
                    at += size;
                }
                c.accesskit_node_set_character_lengths(text, characters, lengths.ptr);
                c.accesskit_node_push_child(node, child_id);
                c.accesskit_tree_update_push_node(update, child_id, text);
                if (source.text_selection) |selection| c.accesskit_node_set_text_selection(node, .{
                    .anchor = .{ .node = child_id, .character_index = std.unicode.utf8CountCodepoints(source.value[0..selection.anchor]) catch unreachable },
                    .focus = .{ .node = child_id, .character_index = std.unicode.utf8CountCodepoints(source.value[0..selection.focus]) catch unreachable },
                });
            }
            if (source.actionable and !source.disabled) {
                c.accesskit_node_add_action(node, c.ACCESSKIT_ACTION_FOCUS);
                switch (source.role) {
                    .button, .checkbox, .switch_control, .radio, .tab, .menu_item, .column_header => c.accesskit_node_add_action(node, c.ACCESSKIT_ACTION_CLICK),
                    .slider => {
                        c.accesskit_node_add_action(node, c.ACCESSKIT_ACTION_INCREMENT);
                        c.accesskit_node_add_action(node, c.ACCESSKIT_ACTION_DECREMENT);
                    },
                    .input => {
                        c.accesskit_node_add_action(node, c.ACCESSKIT_ACTION_SET_VALUE);
                        c.accesskit_node_add_action(node, c.ACCESSKIT_ACTION_SET_TEXT_SELECTION);
                    },
                    else => {},
                }
            }
            c.accesskit_tree_update_push_node(update, source.id, node);
        }
        return update;
    }

    fn lock(self: *Self) void {
        // ponytail: one snapshot lock; use a blocking mutex if tree updates become large.
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn deactivated(userdata: ?*anyopaque) callconv(.c) void {
        _ = userdata;
    }

    fn handleAction(request: ?*c.accesskit_action_request, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(userdata.?));
        const action = request.?.action;
        defer c.accesskit_action_request_free(request);
        const code: Action = switch (action) {
            c.ACCESSKIT_ACTION_FOCUS => .focus,
            c.ACCESSKIT_ACTION_CLICK => .click,
            c.ACCESSKIT_ACTION_INCREMENT => .increment,
            c.ACCESSKIT_ACTION_DECREMENT => .decrement,
            c.ACCESSKIT_ACTION_SET_VALUE => .set_value,
            c.ACCESSKIT_ACTION_SET_TEXT_SELECTION => .set_selection,
            else => {
                std.log.warn("Unsupported AccessKit action: {d}", .{action});
                return;
            },
        };
        if (request.?.target_node == 0 or request.?.target_node > std.math.maxInt(u32)) return;
        var data: ?*TextEvent = null;
        if (code == .set_value or code == .set_selection) {
            if (!request.?.data.has_value) {
                std.log.warn("Missing AccessKit text action payload", .{});
                return;
            }
            data = std.heap.page_allocator.create(TextEvent) catch {
                std.log.err("Cannot allocate AccessKit text action", .{});
                return;
            };
            data.?.* = .{};
            if (code == .set_value) {
                if (request.?.data.value.tag != c.ACCESSKIT_ACTION_DATA_VALUE) {
                    std.log.warn("Invalid AccessKit value action data", .{});
                    std.heap.page_allocator.destroy(data.?);
                    return;
                }
                const raw_value = request.?.data.value.unnamed_0.unnamed_1.value;
                if (raw_value == null) {
                    std.log.warn("AccessKit value action has no text", .{});
                    std.heap.page_allocator.destroy(data.?);
                    return;
                }
                const value = std.mem.span(raw_value);
                if (value.len > data.?.value.len) {
                    std.log.warn("AccessKit value exceeds 128 bytes", .{});
                    std.heap.page_allocator.destroy(data.?);
                    return;
                }
                @memcpy(data.?.value[0..value.len], value);
                data.?.len = value.len;
            } else {
                if (request.?.data.value.tag != c.ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION) {
                    std.log.warn("Invalid AccessKit selection action data", .{});
                    std.heap.page_allocator.destroy(data.?);
                    return;
                }
                const selection = request.?.data.value.unnamed_0.unnamed_7.set_text_selection;
                const child_id = text_run_id | request.?.target_node;
                if (selection.anchor.node != child_id or selection.focus.node != child_id) {
                    std.log.warn("AccessKit selection references another text run", .{});
                    std.heap.page_allocator.destroy(data.?);
                    return;
                }
                data.?.anchor = selection.anchor.character_index;
                data.?.focus = selection.focus.character_index;
            }
        }
        sdl3.events.push(.{ .user = .{
            .common = .{ .timestamp = 0 },
            .event_type = self.event_type,
            .code = @intFromEnum(code),
            .data1 = @ptrFromInt(request.?.target_node),
            .data2 = data,
        } }) catch |err| {
            if (data) |owned| std.heap.page_allocator.destroy(owned);
            std.log.err("Failed to queue AccessKit action: {s}", .{@errorName(err)});
        };
    }
};

fn nativeRole(role: ui.accessibility.Role) c.accesskit_role {
    return switch (role) {
        .group => c.ACCESSKIT_ROLE_GENERIC_CONTAINER,
        .region => c.ACCESSKIT_ROLE_REGION,
        .log => c.ACCESSKIT_ROLE_LOG,
        .label => c.ACCESSKIT_ROLE_LABEL,
        .heading => c.ACCESSKIT_ROLE_HEADING,
        .button => c.ACCESSKIT_ROLE_BUTTON,
        .checkbox => c.ACCESSKIT_ROLE_CHECK_BOX,
        .switch_control => c.ACCESSKIT_ROLE_SWITCH,
        .slider => c.ACCESSKIT_ROLE_SLIDER,
        .input => c.ACCESSKIT_ROLE_TEXT_INPUT,
        .radio => c.ACCESSKIT_ROLE_RADIO_BUTTON,
        .radio_group => c.ACCESSKIT_ROLE_RADIO_GROUP,
        .progress => c.ACCESSKIT_ROLE_PROGRESS_INDICATOR,
        .tab => c.ACCESSKIT_ROLE_TAB,
        .tab_list => c.ACCESSKIT_ROLE_TAB_LIST,
        .tab_panel => c.ACCESSKIT_ROLE_TAB_PANEL,
        .image => c.ACCESSKIT_ROLE_IMAGE,
        .alert => c.ACCESSKIT_ROLE_ALERT,
        .status => c.ACCESSKIT_ROLE_STATUS,
        .tooltip => c.ACCESSKIT_ROLE_TOOLTIP,
        .dialog => c.ACCESSKIT_ROLE_DIALOG,
        .alert_dialog => c.ACCESSKIT_ROLE_ALERT_DIALOG,
        .menu => c.ACCESSKIT_ROLE_MENU,
        .menu_item => c.ACCESSKIT_ROLE_MENU_ITEM,
        .table => c.ACCESSKIT_ROLE_TABLE,
        .row => c.ACCESSKIT_ROLE_ROW,
        .cell => c.ACCESSKIT_ROLE_CELL,
        .column_header => c.ACCESSKIT_ROLE_COLUMN_HEADER,
        .ignored => c.ACCESSKIT_ROLE_GENERIC_CONTAINER,
    };
}

test "native AccessKit update includes Weeoui labels and app focus" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snapshot = try demo.accessibilitySnapshot(arena.allocator(), .{ .x = 0, .y = 0, .w = 900, .h = 675 }, &font);
    var bridge = Bridge{ .allocator = std.testing.allocator, .arena = arena, .snapshot = snapshot, .scale = 1, .event_type = @intFromEnum(sdl3.events.Type.user) + 1 };
    const update = bridge.updateTree(true);
    defer c.accesskit_tree_update_free(update);
    const debug = c.accesskit_tree_update_debug(update) orelse return error.AccessKitDebugFailed;
    defer c.accesskit_string_free(debug);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(debug), "Try button") != null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(debug), "Show hints") != null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(debug), "Details panel") != null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(debug), "Activity over five periods") != null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(debug), "Open dialog") != null);
    try std.testing.expectEqual(c.ACCESSKIT_ROLE_TAB, nativeRole(.tab));
    try std.testing.expectEqual(c.ACCESSKIT_ROLE_COLUMN_HEADER, nativeRole(.column_header));
    try std.testing.expectEqual(c.ACCESSKIT_ROLE_ALERT_DIALOG, nativeRole(.alert_dialog));

    const requested: sdl3.events.Event = .{ .user = .{
        .common = .{ .timestamp = 0 },
        .event_type = bridge.event_type,
        .code = @intFromEnum(Action.click),
        .data1 = @ptrFromInt(360),
    } };
    const encoded = requested.toSdl();
    const received = switch (sdl3.events.Event.fromSdl(encoded)) {
        .user => |user| user,
        else => return error.LostRegisteredEvent,
    };
    try std.testing.expect(bridge.event(received, &demo));
    bridge.snapshot = try demo.accessibilitySnapshot(arena.allocator(), .{ .x = 0, .y = 0, .w = 900, .h = 675 }, &font);
    const changed = bridge.updateTree(false);
    defer c.accesskit_tree_update_free(changed);
    const changed_debug = c.accesskit_tree_update_debug(changed) orelse return error.AccessKitDebugFailed;
    defer c.accesskit_string_free(changed_debug);
    try std.testing.expectEqual(@as(u64, 360), bridge.snapshot.focus);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(changed_debug), "Overview panel") != null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(changed_debug), "Details panel") == null);
}

test "AccessKit value and selection actions reach the bounded UTF-8 editor" {
    var font = try ui.Font.init(std.testing.allocator, ui.default_font, 32);
    defer font.deinit();
    var demo: Demo = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snapshot = try demo.accessibilitySnapshot(arena.allocator(), .{ .x = 0, .y = 0, .w = 900, .h = 675 }, &font);
    var bridge = Bridge{ .allocator = std.testing.allocator, .arena = arena, .snapshot = snapshot, .scale = 1, .event_type = @intFromEnum(sdl3.events.Type.user) + 1 };
    const value = try std.heap.page_allocator.create(TextEvent);
    value.* = .{};
    @memcpy(value.value[0..4], "AéB");
    value.len = 4;
    const target: ?*anyopaque = @ptrFromInt(300);
    try std.testing.expect(bridge.event(.{
        .common = .{ .timestamp = 0 },
        .event_type = bridge.event_type,
        .code = @intFromEnum(Action.set_value),
        .data1 = target,
        .data2 = value,
    }, &demo));
    try std.testing.expectEqualStrings("AéB", demo.editable[0].text.text());
    const selection = try std.heap.page_allocator.create(TextEvent);
    selection.* = .{ .anchor = 1, .focus = 2 };
    try std.testing.expect(bridge.event(.{
        .common = .{ .timestamp = 0 },
        .event_type = bridge.event_type,
        .code = @intFromEnum(Action.set_selection),
        .data1 = target,
        .data2 = selection,
    }, &demo));
    try std.testing.expectEqualStrings("é", demo.selectedText().?);
}
