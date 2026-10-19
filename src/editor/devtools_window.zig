//! Help > DevTools: Weeoui's Elements and Performance tools, in a window of their own, for the
//! editor's main window. Inspect picks an element there, which it then highlights.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const ToolWindow = @import("tool_window.zig").ToolWindow;
const hit_test = eggy.ui_hit_test;

const tools_shown = [_]ui.devtools.Tool{ .elements, .performance };
const tool_labels = [_][]const u8{ "Elements", "Performance", "Game" };

pub const DevtoolsWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    tools: ui.devtools.Devtools = .{},
    /// The tab shown: an index into `tools_shown`.
    tab: usize = 0,
    /// The tools' control that was pressed last, which gets typing and arrow keys.
    focus: u32 = 0,

    /// Open the window. On the heap: the tools are large, and kept between frames.
    /// Editor-host only: graphics and the borrowed font must outlive `close`.
    /// Allocation/window/surface failures propagate.
    ///
    /// ```zig
    /// const tools = try DevtoolsWindow.open(gpa, graphics, font);
    /// defer tools.close(graphics);
    /// ```
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font) !*DevtoolsWindow {
        const self = try gpa.create(DevtoolsWindow);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "DevTools", .{ 760, 620 }, .{ .resizable = true }) };
        return self;
    }

    /// Release tools, surface, UI, and heap-owned `self` before its shared font/device.
    ///
    /// ```zig
    /// // Editor shutdown, after the final highlight draw:
    /// tools.close(graphics);
    /// ```
    pub fn close(self: *DevtoolsWindow, graphics: *eggy.Graphics) void {
        self.tools.deinit(self.gpa);
        self.window.close(graphics);
        self.gpa.destroy(self);
    }

    /// Whether `curr_event` asks to close the window: its close button, or Escape while no
    /// field is being edited (Escape cancels the edit first).
    /// Pure query; the host must close and clear its pointer when true.
    ///
    /// ```zig
    /// if (tools.closeRequested(event)) {
    ///     tools.close(graphics);
    ///     return;
    /// }
    /// _ = tools.handle(event);
    /// ```
    pub fn closeRequested(self: *const DevtoolsWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (curr_event == .window_close_requested) return true;
        const input = weeoui_sdl3.translate(curr_event) orelse return false;
        return input == .key_down and input.key_down.key == .escape and self.tools.editing == null;
    }

    /// Handle `curr_event` if it is for this window; returns whether it was. Presses on the
    /// tools' controls, and typing into their fields, go to the tools; the rest (tabs, scrolling)
    /// to the window's page.
    /// Does not retain the event or close the window.
    ///
    /// ```zig
    /// // After checking closeRequested:
    /// if (tools.handle(event)) return;
    /// ```
    pub fn handle(self: *DevtoolsWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        const input = weeoui_sdl3.translate(curr_event) orelse {
            self.window.handle(curr_event);
            return true;
        };
        if (!self.handleTools(input)) self.window.handle(curr_event);
        return true;
    }

    fn handleTools(self: *DevtoolsWindow, input: ui.input.Event) bool {
        const gpa = self.gpa;
        switch (input) {
            .pointer_down => |down| {
                if (down.button != .left) return false;
                const root = self.window.ui.last_root orelse return false;
                const id = hit_test.controlAt(root, down.position.x, down.position.y);
                // Leaving a field applies what was typed, as Chrome does.
                if (id != self.focus and self.tools.editing != null) self.tools.blur(gpa);
                self.focus = id;
                return self.tools.activate(gpa, id);
            },
            .text => |text| return self.tools.insertText(self.focus, text),
            .key_down => |key| {
                if (key.key == .escape) return self.tools.cancel();
                if (key.key == .enter) return self.tools.commit(gpa, self.focus);
                const edit_key: ui.devtools.EditKey = switch (key.key) {
                    .left => .left,
                    .right => .right,
                    .up => .up,
                    .down => .down,
                    .home => .home,
                    .end => .end,
                    .backspace => .backspace,
                    .delete => .delete,
                    .a => if (key.modifiers.control) .select_all else return false,
                    else => return false,
                };
                if (self.tools.isField(self.focus)) return self.tools.editKey(gpa, self.focus, edit_key, key.modifiers.shift, key.modifiers.control);
                const next = self.tools.treeKey(gpa, self.focus, edit_key) orelse return false;
                self.focus = next;
                return true;
            },
            else => return false,
        }
    }

    /// Draw a frame of the tools for `page`, the main window's tree from this frame (laid out).
    /// The page must stay alive until the main window draws the tools' highlight.
    /// Borrows the editor's style; allocation/preparation/rendering errors propagate.
    ///
    /// ```zig
    /// // Host: main_tree is this frame's laid-out main-window tree.
    /// try tools.update(graphics, style, main_tree, &app.profiling);
    /// // Draw the main window's highlight before releasing main_tree.
    /// ```
    pub fn update(self: *DevtoolsWindow, graphics: *eggy.Graphics, style: *const ui.Context, page: *const ui.Layout.Element, profile: *const eggy.profiling.Profiling) !void {
        try self.tools.prepare(self.gpa, page);
        const Page = struct {
            window: *DevtoolsWindow,
            profile: *const eggy.profiling.Profiling,
            /// Internal page adapter used synchronously by `ToolWindow.present`.
            /// Appends tool tabs/content in the active context frame, borrowing the window.
            ///
            /// ```zig
            /// // Inside update:
            /// var page_builder = Page{ .window = self };
            /// try self.window.present(graphics, style, &page_builder);
            /// ```
            pub fn build(p: *@This(), context: *ui.Context) void {
                const tools_window = p.window;
                _ = context.tabs(&tool_labels, &tools_window.tab);
                if (tools_window.tab == 2) {
                    p.gameProfile(context);
                    return;
                }
                // The tabs take the top.
                const area = ui.Rect{ .x = 0, .y = 0, .w = context.contentWidth(), .h = @max(0, context.viewport.h - 2 * context.pagePadding() - 40) };
                const view = tools_window.tools.view(context.builder(), tools_window.gpa, tools_shown[tools_window.tab], area) catch return;
                context.element(view);
            }

            fn gameProfile(p: *@This(), context: *ui.Context) void {
                const profile_frame = &p.profile.last;
                const frame_ms = @as(f64, @floatFromInt(profile_frame.frame_duration_ns)) / std.time.ns_per_ms;
                context.label("CPU frame: {d:.3} ms", .{frame_ms});
                context.label("CPU samples (not GPU timings)", .{});
                for (profile_frame.samples[0..profile_frame.sample_count]) |*sample| {
                    const elapsed_ms = @as(f64, @floatFromInt(sample.duration_ns)) / std.time.ns_per_ms;
                    if (sample.finished)
                        context.label("{s}: {d:.3} ms", .{ sample.name.text(), elapsed_ms })
                    else
                        context.label("{s}: unfinished", .{sample.name.text()});
                }
                context.label("Counters", .{});
                for (profile_frame.counters[0..profile_frame.counter_count]) |*counter| {
                    context.label("{s}: {d:.2}", .{ counter.name.text(), counter.value });
                }
            }
        };
        var page_builder = Page{ .window = self, .profile = profile };
        try self.window.present(graphics, style, &page_builder);
        // `present` let go of the page: prepare again for the main window's highlight.
        try self.tools.prepare(self.gpa, page);
    }

    /// A pointer move over the main window, at (x, y): while inspecting, it moves the highlight.
    /// Coordinates are main-window logical points, not this tool window's pixels.
    ///
    /// ```zig
    /// tools.pointerMove(motion.x, motion.y); // Main-window SDL mouse motion.
    /// ```
    pub fn pointerMove(self: *DevtoolsWindow, x: f32, y: f32) void {
        self.tools.pointerMove(x, y);
    }

    /// A press on the main window at (x, y); while inspecting it picks the element there, and
    /// returns true as the press is used.
    /// Coordinates are main-window logical points; the host must withhold consumed presses.
    ///
    /// ```zig
    /// if (tools.pointerDown(button.x, button.y)) return;
    /// ```
    pub fn pointerDown(self: *DevtoolsWindow, x: f32, y: f32) bool {
        return self.tools.pointerDown(x, y);
    }
};
