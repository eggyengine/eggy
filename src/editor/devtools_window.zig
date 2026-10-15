//! Help > DevTools: Weeoui's Elements and Performance tools, in a window of their own, for the
//! editor's main window. Inspect picks an element there, which it then highlights.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const ToolWindow = @import("tool_window.zig").ToolWindow;
const hit_test = @import("hit_test.zig");

const tools_shown = [_]ui.devtools.Tool{ .elements, .performance };
const tool_labels = [_][]const u8{ "Elements", "Performance" };

pub const DevtoolsWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    tools: ui.devtools.Devtools = .{},
    /// The tab shown: an index into `tools_shown`.
    tab: usize = 0,
    /// The tools' control that was pressed last, which gets typing and arrow keys.
    focus: u32 = 0,

    /// Open the window. On the heap: the tools are large, and kept between frames.
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font) !*DevtoolsWindow {
        const self = try gpa.create(DevtoolsWindow);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "DevTools", .{ 760, 620 }, .{ .resizable = true }) };
        return self;
    }

    pub fn close(self: *DevtoolsWindow, graphics: *eggy.Graphics) void {
        self.tools.deinit(self.gpa);
        self.window.close(graphics);
        self.gpa.destroy(self);
    }

    /// Whether `curr_event` asks to close the window: its close button, or Escape while no
    /// field is being edited (Escape cancels the edit first).
    pub fn closeRequested(self: *const DevtoolsWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (curr_event == .window_close_requested) return true;
        const input = weeoui_sdl3.translate(curr_event) orelse return false;
        return input == .key_down and input.key_down.key == .escape and self.tools.editing == null;
    }

    /// Handle `curr_event` if it is for this window; returns whether it was. Presses on the
    /// tools' controls, and typing into their fields, go to the tools; the rest (tabs, scrolling)
    /// to the window's page.
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
    pub fn update(self: *DevtoolsWindow, graphics: *eggy.Graphics, style: *const ui.Context, page: *const ui.Layout.Element) !void {
        try self.tools.prepare(self.gpa, page);
        const Page = struct {
            window: *DevtoolsWindow,
            pub fn build(p: *@This(), context: *ui.Context) void {
                const tools_window = p.window;
                _ = context.tabs(&tool_labels, &tools_window.tab);
                // The page's padding is 16 each side; the tabs take the top.
                const area = ui.Rect{ .x = 0, .y = 0, .w = @max(0, context.viewport.w - 32), .h = @max(0, context.viewport.h - 76) };
                const view = tools_window.tools.view(context.builder(), tools_window.gpa, tools_shown[tools_window.tab], area) catch return;
                context.element(view);
            }
        };
        var page_builder = Page{ .window = self };
        try self.window.present(graphics, style, &page_builder);
        // `present` let go of the page: prepare again for the main window's highlight.
        try self.tools.prepare(self.gpa, page);
    }

    /// A pointer move over the main window, at (x, y): while inspecting, it moves the highlight.
    pub fn pointerMove(self: *DevtoolsWindow, x: f32, y: f32) void {
        self.tools.pointerMove(x, y);
    }

    /// A press on the main window at (x, y); while inspecting it picks the element there, and
    /// returns true as the press is used.
    pub fn pointerDown(self: *DevtoolsWindow, x: f32, y: f32) bool {
        return self.tools.pointerDown(x, y);
    }
};
