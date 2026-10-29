//! The "Update the editor?" window: when the linked Eggy codebase changed in ways that can break
//! the game's code, it asks before the editor rebuilds onto it, listing those changes (or, for
//! an extreme update, the whole changelog). Modal over the editor.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const ToolWindow = @import("tool_window.zig").ToolWindow;
const page_style = @import("page_style.zig");
const eggy_update = @import("projects/eggy_update.zig");

/// What the person answered: rebuild onto the new Eggy, or keep this editor for the session.
pub const Answer = enum { update, skip };

pub const EggyUpdatePrompt = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    /// Holds `measured`'s strings.
    arena: std.heap.ArenaAllocator,
    measured: eggy_update.Update,
    scroll: ui.Layout.ScrollState = .{},

    /// Open the prompt over `parent`, modal to it, taking `measured` and the arena holding it. On
    /// the heap, as its page keeps a pointer to it. Window errors propagate, the arena freed.
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, parent: sdl3.video.Window, arena: std.heap.ArenaAllocator, measured: eggy_update.Update) !*EggyUpdatePrompt {
        var owned = arena;
        errdefer owned.deinit();
        const self = try gpa.create(EggyUpdatePrompt);
        errdefer gpa.destroy(self);
        // The changelog needs room; a few breaking changes don't.
        const size: [2]f32 = if (measured.size == .extreme) .{ 620, 520 } else .{ 520, 340 };
        self.* = .{ .gpa = gpa, .window = try ToolWindow.open(gpa, graphics, font, "Update the editor", size, .{}), .arena = owned, .measured = measured };
        const window = self.window.popout.window.window;
        window.setParent(parent) catch {};
        window.setModal(true) catch {};
        return self;
    }

    /// Destroy the window and free `self`; the host carries out the answer.
    pub fn close(self: *EggyUpdatePrompt, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// Handle `curr_event` if it is for this window; returns whether it was.
    pub fn handle(self: *EggyUpdatePrompt, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        self.window.handle(curr_event);
        return true;
    }

    /// The answer `curr_event` gives, if it is one: closing the window or Escape skips, Enter
    /// updates.
    pub fn keyAnswer(self: *const EggyUpdatePrompt, curr_event: sdl3.events.Event) ?Answer {
        if (!self.window.owns(curr_event)) return null;
        if (curr_event == .window_close_requested) return .skip;
        const input = weeoui_sdl3.translate(curr_event) orelse return null;
        if (input != .key_down) return null;
        return switch (input.key_down.key) {
            .escape => .skip,
            .enter => .update,
            else => null,
        };
    }

    /// Draw a frame; returns the answer if a button was pressed.
    pub fn update(self: *EggyUpdatePrompt, graphics: *eggy.Graphics, style: *const ui.Context) !?Answer {
        const Page = struct {
            prompt: *EggyUpdatePrompt,
            answer: ?Answer = null,
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.answer = page.prompt.build(context);
            }
        };
        var page = Page{ .prompt = self };
        try self.window.present(graphics, style, &page);
        return page.answer;
    }

    fn build(self: *EggyUpdatePrompt, context: *ui.Context) ?Answer {
        const changes = self.measured.changes;
        const breaking = self.measured.breakingCount();
        const same_version = std.mem.eql(u8, self.measured.from_version, self.measured.to_version);
        if (same_version) {
            context.label("Eggy changed since this editor was built: {d} changes, {d} of which may break your game's code.", .{ changes.len, breaking });
        } else {
            context.label("Eggy went from {s} to {s} since this editor was built: {d} changes, {d} of which may break your game's code.", .{ self.measured.from_version, self.measured.to_version, changes.len, breaking });
        }

        // An extreme update shows everything, grouped; otherwise just what may break.
        const footer_height = 96;
        context.beginScroll(&self.scroll, @max(60, page_style.pageHeight(context) - footer_height - 40));
        if (self.measured.size == .extreme) {
            buildGroup(context, "Breaking changes", changes, .breaking);
            inline for (.{ .{ "Features", .feat }, .{ "Fixes", .fix }, .{ "Performance", .perf }, .{ "Refactors", .refactor }, .{ "Documentation", .docs }, .{ "Other", .other } }) |group| {
                buildGroup(context, group[0], changes, .{ .kind = group[1] });
            }
        } else {
            buildGroup(context, "May break your code", changes, .breaking);
        }
        context.end();

        var answer: ?Answer = null;
        context.muted("Skipping keeps this editor for the rest of the session: it stops rebuilding on its own. Reload asks again.");
        page_style.smallText(context, 12);
        context.begin(.row);
        if (context.buttonVariant("Skip this session", .outline)) answer = .skip;
        context.element(context.builder().node(0, .{ .grow = 1 }, .none, &.{}) catch return answer);
        if (context.button("Update")) answer = .update;
        context.end();
        page_style.restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center });
        return answer;
    }
};

/// A heading and the changes `filter` picks, or nothing when it picks none. Breaking changes
/// show only under their own heading, so each appears once.
fn buildGroup(context: *ui.Context, title: []const u8, changes: []const eggy_update.Change, filter: union(enum) { breaking, kind: eggy_update.Kind }) void {
    var shown = false;
    for (changes) |change| {
        const picked = switch (filter) {
            .breaking => change.breaking,
            .kind => |kind| !change.breaking and change.kind == kind,
        };
        if (!picked) continue;
        if (!shown) context.heading(4, title);
        shown = true;
        context.label("• {s}", .{change.summary});
    }
}
