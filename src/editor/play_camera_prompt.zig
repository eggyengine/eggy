//! The "Play from which camera?" window Shift+Play opens: the scene's cameras to pick from, the
//! one the game would look through chosen first; Play starts with the one picked as the only
//! active camera until Stop. Modal over the editor.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const ToolWindow = @import("tool_window.zig").ToolWindow;
const page_style = @import("page_style.zig");

pub const PlayCameraPrompt = struct {
    /// One camera offered: its entity, and the name it goes by.
    pub const Choice = struct { entity: eggy.ecs.EntityId, name: []const u8 };

    /// What the window was answered with: play from a camera, or don't play.
    pub const Answer = union(enum) { play: eggy.ecs.EntityId, cancel };

    gpa: std.mem.Allocator,
    window: ToolWindow,
    /// The cameras offered, and their names; copied.
    arena: std.heap.ArenaAllocator,
    choices: []const Choice = &.{},
    /// The one the game looks through now, marked as such.
    current: ?usize = null,
    picked: usize = 0,

    /// Open the window over `parent`, modal to it, offering `choices` (copied, at least one),
    /// with `current` picked first. On the heap, as its page keeps a pointer to it. Allocation
    /// and window errors propagate.
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, parent: sdl3.video.Window, choices: []const Choice, current: ?usize) !*PlayCameraPrompt {
        const self = try gpa.create(PlayCameraPrompt);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = undefined, .arena = .init(gpa), .current = current, .picked = current orelse 0 };
        errdefer self.arena.deinit();
        const kept = try self.arena.allocator().alloc(Choice, choices.len);
        for (kept, choices) |*out, choice| out.* = .{ .entity = choice.entity, .name = try self.arena.allocator().dupe(u8, choice.name) };
        self.choices = kept;
        const rows: f32 = @floatFromInt(@min(choices.len, 8));
        self.window = try ToolWindow.open(gpa, graphics, font, "Play from a camera", .{ 400, 150 + rows * 30 }, .{});
        const window = self.window.popout.window.window;
        window.setParent(parent) catch {};
        window.setModal(true) catch {};
        return self;
    }

    /// Destroy the window and free `self`, without playing.
    pub fn close(self: *PlayCameraPrompt, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// Handle `curr_event` if it is for this window; returns whether it was.
    pub fn handle(self: *PlayCameraPrompt, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        self.window.handle(curr_event);
        return true;
    }

    /// The answer `curr_event` gives, if it is one: closing the window or Escape cancels, and
    /// Enter plays from the camera picked.
    pub fn keyAnswer(self: *const PlayCameraPrompt, curr_event: sdl3.events.Event) ?Answer {
        if (!self.window.owns(curr_event)) return null;
        if (curr_event == .window_close_requested) return .cancel;
        const input = weeoui_sdl3.translate(curr_event) orelse return null;
        if (input != .key_down) return null;
        return switch (input.key_down.key) {
            .escape => .cancel,
            .enter => .{ .play = self.choices[self.picked].entity },
            else => null,
        };
    }

    /// Draw a frame; returns the answer when a button was pressed.
    pub fn update(self: *PlayCameraPrompt, graphics: *eggy.Graphics, style: *const ui.Context) !?Answer {
        const Page = struct {
            prompt: *PlayCameraPrompt,
            answer: ?Answer = null,
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.answer = page.prompt.build(context);
            }
        };
        var page = Page{ .prompt = self };
        try self.window.present(graphics, style, &page);
        return page.answer;
    }

    fn build(self: *PlayCameraPrompt, context: *ui.Context) ?Answer {
        var answer: ?Answer = null;
        const arena = context.builder().allocator;
        context.heading(3, "Play from which camera?");
        context.muted("The camera picked is the only one active until you press Stop.");
        page_style.smallText(context, 12);
        if (context.last_added) |text| text.paint_kind.text.wrap = true;
        for (self.choices, 0..) |choice, index| {
            const shown = if (self.current == index) std.fmt.allocPrint(arena, "{s} (the game's camera)##camera {d}", .{ choice.name, index }) else std.fmt.allocPrint(arena, "{s}##camera {d}", .{ choice.name, index });
            _ = context.radio(shown catch continue, &self.picked, index);
        }
        context.begin(.row);
        context.element(context.builder().node(0, .{ .grow = 1 }, .none, &.{}) catch return answer);
        if (context.buttonVariant("Cancel", .ghost)) answer = .cancel;
        if (context.button("Play")) answer = .{ .play = self.choices[self.picked].entity };
        page_style.endRow(context);
        return answer;
    }
};
