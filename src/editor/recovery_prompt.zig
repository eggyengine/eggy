//! The "Restore unsaved changes?" window: when the editor opens a project that a previous editor
//! closed without saving (it crashed, or was killed), it offers to put those changes back.
//! Modal over the editor.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const ToolWindow = @import("tool_window.zig").ToolWindow;
const page_style = @import("page_style.zig");

/// What the person answered: put the changes back, throw them away, or leave the copy where it
/// is to decide another time.
pub const Answer = enum { restore, discard, later };

pub const RecoveryPrompt = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    question_buffer: [200]u8 = undefined,
    question_len: usize = 0,

    /// Open the prompt over `parent`, modal to it, about changes to `scene_name` (null: a scene
    /// never saved). On the heap, as its page keeps a pointer to it. Window errors propagate.
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, parent: sdl3.video.Window, scene_name: ?[]const u8) !*RecoveryPrompt {
        const self = try gpa.create(RecoveryPrompt);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "Restore unsaved changes", .{ 460, 190 }, .{}) };
        const question = std.fmt.bufPrint(&self.question_buffer, "The editor closed before changes to {s} were saved. Restore them?", .{scene_name orelse "an unsaved scene"}) catch "The editor closed before changes were saved. Restore them?";
        self.question_len = question.len;
        const window = self.window.popout.window.window;
        window.setParent(parent) catch {};
        window.setModal(true) catch {};
        return self;
    }

    /// Destroy the window and free `self`; the host carries out the answer.
    pub fn close(self: *RecoveryPrompt, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.gpa.destroy(self);
    }

    /// Handle `curr_event` if it is for this window; returns whether it was.
    pub fn handle(self: *RecoveryPrompt, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        self.window.handle(curr_event);
        return true;
    }

    /// The answer `curr_event` gives, if it is one: closing the window or Escape leaves the
    /// copy for later, Enter restores.
    pub fn keyAnswer(self: *const RecoveryPrompt, curr_event: sdl3.events.Event) ?Answer {
        if (!self.window.owns(curr_event)) return null;
        if (curr_event == .window_close_requested) return .later;
        const input = weeoui_sdl3.translate(curr_event) orelse return null;
        if (input != .key_down) return null;
        return switch (input.key_down.key) {
            .escape => .later,
            .enter => .restore,
            else => null,
        };
    }

    /// Draw a frame; returns the answer if a button was pressed.
    pub fn update(self: *RecoveryPrompt, graphics: *eggy.Graphics, style: *const ui.Context) !?Answer {
        const Page = struct {
            prompt: *RecoveryPrompt,
            answer: ?Answer = null,
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.answer = page.prompt.build(context);
            }
        };
        var page = Page{ .prompt = self };
        try self.window.present(graphics, style, &page);
        return page.answer;
    }

    fn build(self: *RecoveryPrompt, context: *ui.Context) ?Answer {
        var answer: ?Answer = null;
        context.text(self.question_buffer[0..self.question_len]);
        if (context.last_added) |text| text.paint_kind.text.wrap = true;
        context.muted("Restoring replaces the scene in the editor; Undo takes it back. Nothing is saved until you save.");
        page_style.smallText(context, 12);
        if (context.last_added) |text| text.paint_kind.text.wrap = true;
        context.begin(.row);
        if (context.buttonVariant("Discard", .outline)) answer = .discard;
        context.element(context.builder().node(0, .{ .grow = 1 }, .none, &.{}) catch return answer);
        if (context.buttonVariant("Not now", .ghost)) answer = .later;
        if (context.button("Restore")) answer = .restore;
        context.end();
        page_style.restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center });
        return answer;
    }
};
