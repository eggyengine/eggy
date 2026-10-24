//! The "Update plugin?" window: a newer version of an installed plugin was found, and it is
//! installed only once the person agrees, after seeing the version and where it comes from.
//! Modal over the editor.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const ToolWindow = @import("../tool_window.zig").ToolWindow;
const page_style = @import("../page_style.zig");
const Offer = @import("auto_update.zig").Offer;

pub const UpdatePrompt = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    /// The offer's texts, copied: the heading, the versions, and where it comes from.
    arena: std.heap.ArenaAllocator,
    heading: []const u8 = "",
    versions: []const u8 = "",
    origin: []const u8 = "",
    /// The plugin and version asked about, for the host to remember a Skip.
    key: []const u8 = "",

    /// Open the prompt over `parent`, modal to it, asking about `offer` (copied). On the heap, as
    /// its page keeps a pointer to it. Allocation and window errors propagate.
    ///
    /// ```zig
    /// const prompt = try UpdatePrompt.open(gpa, graphics, font, parent, offer);
    /// defer prompt.close(graphics);
    /// ```
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, parent: sdl3.video.Window, offer: Offer) !*UpdatePrompt {
        const self = try gpa.create(UpdatePrompt);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = undefined, .arena = .init(gpa) };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.heading = try std.fmt.allocPrint(a, "Update {s}?", .{offer.title});
        self.versions = try std.fmt.allocPrint(a, "{s}  \u{2192}  {s}", .{ offer.installed_version, offer.version });
        self.origin = try std.fmt.allocPrint(a, "From {s}", .{if (offer.repository.len > 0) offer.repository else offer.source});
        self.key = try updateKey(a, offer);
        self.window = try ToolWindow.open(gpa, graphics, font, "Plugin update", .{ 460, 210 }, .{});
        const window = self.window.popout.window.window;
        window.setParent(parent) catch {};
        window.setModal(true) catch {};
        return self;
    }

    /// Destroy the window and free `self`, without installing anything.
    pub fn close(self: *UpdatePrompt, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// Handle `curr_event` if it is for this window; returns whether it was.
    pub fn handle(self: *UpdatePrompt, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        self.window.handle(curr_event);
        return true;
    }

    /// The answer `curr_event` gives, if it is one: closing the window or Escape skips. Enter
    /// doesn't update, so a keypress meant for the editor can't install code.
    pub fn keyAnswer(self: *const UpdatePrompt, curr_event: sdl3.events.Event) ?bool {
        if (!self.window.owns(curr_event)) return null;
        if (curr_event == .window_close_requested) return false;
        const input = weeoui_sdl3.translate(curr_event) orelse return null;
        if (input != .key_down or input.key_down.key != .escape) return null;
        return false;
    }

    /// Draw a frame; returns whether to install when a button was pressed.
    pub fn update(self: *UpdatePrompt, graphics: *eggy.Graphics, style: *const ui.Context) !?bool {
        const Page = struct {
            prompt: *UpdatePrompt,
            answer: ?bool = null,
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.answer = page.prompt.build(context);
            }
        };
        var page = Page{ .prompt = self };
        try self.window.present(graphics, style, &page);
        return page.answer;
    }

    fn build(self: *UpdatePrompt, context: *ui.Context) ?bool {
        var answer: ?bool = null;
        context.heading(3, self.heading);
        context.text(self.versions);
        context.muted(self.origin);
        if (context.last_added) |text| text.paint_kind.text.wrap = true;
        context.muted("Only update plugins you trust: an update runs new code in the editor and your game.");
        if (context.last_added) |text| text.paint_kind.text.wrap = true;
        page_style.smallText(context, 12);
        context.begin(.row);
        context.element(context.builder().node(0, .{ .grow = 1 }, .none, &.{}) catch return answer);
        if (context.buttonVariant("Skip", .ghost)) answer = false;
        if (context.button("Update")) answer = true;
        context.end();
        page_style.restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center });
        return answer;
    }
};

/// "module@version": what a Skip is remembered by, so the same version isn't offered again.
pub fn updateKey(arena: std.mem.Allocator, offer: Offer) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}@{s}", .{ offer.module, offer.version });
}
