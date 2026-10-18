//! The "Save changes?" window: before the editor reloads, quits or opens another project with
//! the scene changed since it was saved, it asks whether to save first, not save, or stay.
//! Modal over the editor, which waits for the answer.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const ToolWindow = @import("tool_window.zig").ToolWindow;
const page_style = @import("page_style.zig");

/// What the person answered.
pub const Answer = enum { save, discard, cancel };

pub const SavePrompt = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    /// "Save changes to main.scene.zon before reloading?", kept here for the page.
    question_buffer: [160]u8 = undefined,
    question_len: usize = 0,

    /// Open the prompt over `parent`, modal to it, asking about scene `scene_name` (null: one not
    /// saved anywhere yet) before `doing` ("reloading", "quitting", ...). On the heap, as its
    /// page keeps a pointer to it.
    /// Editor-host only: copies the question into a bounded buffer; borrowed font/graphics
    /// must outlive `close`. Allocation/window errors propagate; modal/parent failures are ignored.
    ///
    /// ```zig
    /// const prompt = try SavePrompt.open(gpa, graphics, font, parent, scene_name, "reloading");
    /// defer prompt.close(graphics);
    /// ```
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, parent: sdl3.video.Window, scene_name: ?[]const u8, doing: []const u8) !*SavePrompt {
        const self = try gpa.create(SavePrompt);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "Unsaved changes", .{ 440, 170 }, .{}) };
        const question = std.fmt.bufPrint(&self.question_buffer, "Save changes to {s} before {s}?", .{ scene_name orelse "the scene", doing }) catch "Save changes before leaving?";
        self.question_len = question.len;
        const window = self.window.popout.window.window;
        window.setParent(parent) catch {};
        window.setModal(true) catch {};
        return self;
    }

    /// Destroy the prompt's window/UI/surface and free `self`, without saving/discarding anything.
    /// The host owns carrying out the answer and must not reuse this pointer.
    ///
    /// ```zig
    /// prompt.close(graphics); // After receiving an answer.
    /// ```
    pub fn close(self: *SavePrompt, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.gpa.destroy(self);
    }

    /// Handle `curr_event` if it is for this window; returns whether it was. Closing the window
    /// or Escape answers Cancel, Enter answers Save (see `keyAnswer`).
    /// This method only forwards UI input; the host must query `keyAnswer` first to act on
    /// keyboard/close answers. Does not retain the event or destroy the prompt.
    ///
    /// ```zig
    /// // After the host has checked prompt.keyAnswer(event):
    /// if (prompt.handle(event)) return;
    /// ```
    pub fn handle(self: *SavePrompt, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        self.window.handle(curr_event);
        return true;
    }

    /// The answer `curr_event` gives, if it is one: closing the window or Escape cancels,
    /// Enter saves.
    /// Returns null for unrelated windows/events; pure query, so the host applies the answer.
    ///
    /// ```zig
    /// if (prompt.keyAnswer(event)) |answer| {
    ///     std.log.info("Save prompt: {t}", .{answer});
    ///     // Host handles answer before closing prompt.
    /// }
    /// ```
    pub fn keyAnswer(self: *const SavePrompt, curr_event: sdl3.events.Event) ?Answer {
        if (!self.window.owns(curr_event)) return null;
        if (curr_event == .window_close_requested) return .cancel;
        const input = weeoui_sdl3.translate(curr_event) orelse return null;
        if (input != .key_down) return null;
        return switch (input.key_down.key) {
            .escape => .cancel,
            .enter => .save,
            else => null,
        };
    }

    /// Draw a frame; returns the answer if a button was pressed.
    /// Borrows the editor's style for this call; rendering errors propagate.
    /// Neither answer application nor prompt destruction is performed here.
    ///
    /// ```zig
    /// if (try prompt.update(graphics, style)) |answer| {
    ///     std.log.info("Save prompt: {t}", .{answer});
    ///     // Host performs save/discard/cancel and closes the prompt.
    /// }
    /// ```
    pub fn update(self: *SavePrompt, graphics: *eggy.Graphics, style: *const ui.Context) !?Answer {
        const Page = struct {
            prompt: *SavePrompt,
            answer: ?Answer = null,
            /// Internal synchronous tool-page adapter; appends prompt controls in the
            /// active frame and stores a button answer in this borrowed stack page.
            ///
            /// ```zig
            /// // Inside update:
            /// var page = Page{ .prompt = self };
            /// try self.window.present(graphics, style, &page);
            /// ```
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.answer = page.prompt.build(context);
            }
        };
        var page = Page{ .prompt = self };
        try self.window.present(graphics, style, &page);
        return page.answer;
    }

    fn build(self: *SavePrompt, context: *ui.Context) ?Answer {
        var answer: ?Answer = null;
        context.text(self.question_buffer[0..self.question_len]);
        if (context.last_added) |text| text.paint_kind.text.wrap = true;
        context.muted("Changes not saved are lost.");
        page_style.smallText(context, 12);
        context.begin(.row);
        if (context.buttonVariant("Don't save", .outline)) answer = .discard;
        context.element(context.builder().node(0, .{ .grow = 1 }, .none, &.{}) catch return answer);
        if (context.buttonVariant("Cancel", .ghost)) answer = .cancel;
        if (context.button("Save")) answer = .save;
        context.end();
        page_style.restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center });
        return answer;
    }
};
