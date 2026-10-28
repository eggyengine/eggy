//! The console's input line: a text field that runs on Enter, recalls lines with Up and Down,
//! and completes the word at the caret with Tab, offering the candidates under it.
const std = @import("std");
const ui = @import("weeoui");
const completion = @import("completion.zig");
const Palette = @import("palette.zig").Palette;

/// The longest line the prompt takes.
pub const max_line_bytes = 1024;
/// The most lines Up and Down recall.
const max_history = 100;
const chip_height: f32 = 22;
const chip_gap: f32 = 6;
const chip_padding: f32 = 8;
const chip_text_size: f32 = 12;
/// How far in from a field's edge weeoui starts its text.
pub const field_text_inset = ui.text_edit.inputContentRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 }).x;

/// What completes the word at the caret: the line, the caret's byte offset, an arena for the result.
pub const Completer = struct {
    context: *anyopaque,
    complete: *const fn (context: *anyopaque, arena: std.mem.Allocator, line: []const u8, cursor: usize) anyerror!completion.Completion,
};

/// How the prompt is laid out this frame.
pub const Options = struct {
    /// Its field's accessible label (and id); unique in the context.
    label: []const u8 = "##console prompt",
    placeholder: []const u8 = "Write your command",
    /// Take the keyboard this frame, as the console opens.
    take_focus: bool = false,
    /// Where to put it, over the page, with the candidates above the field; null for the page's flow,
    /// with them below it.
    place: ?ui.Rect = null,
    z_index: i16 = 0,
    /// Colours of its own, as over the game; null for the context's theme.
    palette: ?Palette = null,
};

pub const Prompt = struct {
    edit: ui.TextEdit(max_line_bytes) = .{},
    /// The lines run, oldest first, owned.
    history: std.ArrayList([]u8) = .empty,
    /// The line of `history` Up and Down have put in the field; null for the one being typed.
    browsing: ?usize = null,
    /// Tab's turn through the candidates, while the field holds what Tab last put there.
    cycle: ?Cycle = null,
    /// How many candidates the last `build` showed, for a host painting a backdrop behind them.
    candidates_shown: usize = 0,
    /// Tab presses (+1) and Shift+Tab presses (-1) since the last frame. Weeoui moves the focus on
    /// Tab before a frame is declared, so hosts take Tab from the field's events (`takeTab`).
    tab_steps: i32 = 0,
    /// The context whose field had the keyboard when last declared, for `takeTab`. The editor
    /// declares the prompt in two (its Console panel and the game as it plays).
    focused_in: ?*const ui.Context = null,

    const Cycle = struct {
        /// The candidates, owned, and where the word they replace starts.
        candidates: [][]u8,
        start: usize,
        index: usize,
        /// The field's text as Tab left it; typing anything else ends the turn.
        left: u64,
    };

    pub fn deinit(self: *Prompt, gpa: std.mem.Allocator) void {
        self.endCycle(gpa);
        for (self.history.items) |line| gpa.free(line);
        self.history.deinit(gpa);
    }

    /// Declare the prompt in `context` for this frame and act on the keys the field was given:
    /// Enter returns the line typed (in the frame's arena) and clears the field, Up and Down walk
    /// the history, Tab and Shift+Tab complete through `completer`. Returns null otherwise.
    ///
    /// ```zig
    /// if (prompt.build(gpa, context, completer, .{})) |line| console.submit(app, commands, line);
    /// ```
    pub fn build(self: *Prompt, gpa: std.mem.Allocator, context: *ui.Context, completer: Completer, options: Options) ?[]const u8 {
        const arena = context.builder().allocator;
        self.candidates_shown = 0;
        if (options.take_focus) context.focus = context.idFor(options.label);
        _ = context.textInput(options.label, &self.edit, options.placeholder);
        const field = context.last_added orelse return null;
        if (options.place) |place| {
            const height = field.style.height orelse 32;
            field.overlay = .{ .point = .init(place.x, place.y + place.h - height) };
            field.style.width = place.w;
            field.style.z_index = options.z_index + 1;
        }
        if (options.palette) |palette| if (field.paint_kind == .input) {
            const paint = arena.create(Field) catch return null;
            paint.* = .{ .input = field.paint_kind.input, .palette = palette };
            field.paint_kind = .{ .custom = .{ .context = paint, .draw = Field.draw } };
        };
        if (context.focus != field.id) {
            if (self.focused_in == context) self.focused_in = null;
            return null;
        }
        self.focused_in = context;

        var submitted: ?[]const u8 = null;
        if (self.tab_steps != 0) self.complete(gpa, arena, completer, self.tab_steps);
        self.tab_steps = 0;
        for (context.pending.items) |item| if (item == .key) switch (item.key.key) {
            .enter => if (!item.key.repeat and self.edit.len != 0) {
                submitted = arena.dupe(u8, self.edit.text()) catch null;
                self.remember(gpa, self.edit.text());
                self.edit = .{};
                self.endCycle(gpa);
            },
            .up => self.recall(gpa, .older),
            .down => self.recall(gpa, .newer),
            else => {},
        };
        if (self.cycle) |cycle| if (cycle.left != std.hash.Wyhash.hash(0, self.edit.text())) self.endCycle(gpa);

        // The candidates for the word at the caret, the one Tab is on lit.
        const shown, const lit = if (self.cycle) |cycle| .{ @as([]const []const u8, cycle.candidates), cycle.index } else blk: {
            const found = completer.complete(completer.context, arena, self.edit.text(), self.edit.cursor) catch break :blk .{ @as([]const []const u8, &.{}), null };
            break :blk .{ found.candidates, null };
        };
        self.candidates_shown = shown.len;
        if (shown.len != 0) {
            const chips = arena.create(Chips) catch return submitted;
            chips.* = .{ .names = shown, .lit = lit, .palette = options.palette };
            const width = if (options.place) |place| place.w else context.contentWidth();
            const row = context.builder().node(0, .{ .width = width, .height = chip_height, .z_index = options.z_index + 1 }, .{ .custom = .{ .context = chips, .draw = Chips.draw } }, &.{}) catch return submitted;
            row.accessibility.role = .ignored;
            if (options.place) |place| row.overlay = .{ .point = .init(place.x, place.y + place.h - (field.style.height orelse 32) - chip_height - chip_gap) };
            context.element(row);
        }
        return submitted;
    }

    /// Take a Tab key press for completion while the field has the keyboard: true when it was
    /// taken, and the host must then not pass it on to the UI (which would move the focus on).
    ///
    /// ```zig
    /// if (prompt.takeTab(key.key == .tab, key.modifiers.shift)) return;
    /// ```
    pub fn takeTab(self: *Prompt, is_tab: bool, shift: bool) bool {
        if (!is_tab or self.focused_in == null) return false;
        self.tab_steps += if (shift) -1 else 1;
        return true;
    }

    /// Replace the word at the caret with the next candidate (`step` > 0) or the one before.
    fn complete(self: *Prompt, gpa: std.mem.Allocator, arena: std.mem.Allocator, completer: Completer, step: i32) void {
        if (self.cycle == null) {
            const found = completer.complete(completer.context, arena, self.edit.text(), self.edit.cursor) catch return;
            if (found.candidates.len == 0) return;
            const owned = gpa.alloc([]u8, found.candidates.len) catch return;
            for (owned, found.candidates, 0..) |*slot, name, made| slot.* = gpa.dupe(u8, name) catch {
                for (owned[0..made]) |earlier| gpa.free(earlier);
                gpa.free(owned);
                return;
            };
            // The first Tab takes the first candidate, Shift+Tab the last.
            self.cycle = .{ .candidates = owned, .start = found.start, .index = if (step > 0) owned.len - 1 else 0, .left = 0 };
        }
        const cycle = &self.cycle.?;
        const count: i64 = @intCast(cycle.candidates.len);
        cycle.index = @intCast(@mod(@as(i64, @intCast(cycle.index)) + std.math.sign(step), count));
        // The word runs from where it started to the caret, which Tab leaves after it.
        self.edit.replace(.{ .start = cycle.start, .end = self.edit.cursor }, cycle.candidates[cycle.index]) catch return;
        cycle.left = std.hash.Wyhash.hash(0, self.edit.text());
    }

    fn endCycle(self: *Prompt, gpa: std.mem.Allocator) void {
        const cycle = self.cycle orelse return;
        for (cycle.candidates) |name| gpa.free(name);
        gpa.free(cycle.candidates);
        self.cycle = null;
    }

    /// Keep `line` for Up to bring back, unless it repeats the last.
    fn remember(self: *Prompt, gpa: std.mem.Allocator, line: []const u8) void {
        self.browsing = null;
        if (self.history.items.len != 0 and std.mem.eql(u8, self.history.items[self.history.items.len - 1], line)) return;
        const owned = gpa.dupe(u8, line) catch return;
        self.history.append(gpa, owned) catch return gpa.free(owned);
        if (self.history.items.len > max_history) gpa.free(self.history.orderedRemove(0));
    }

    /// Put an older or newer line of the history in the field; past the newest, an empty one.
    fn recall(self: *Prompt, gpa: std.mem.Allocator, direction: enum { older, newer }) void {
        const count = self.history.items.len;
        if (count == 0) return;
        self.browsing = switch (direction) {
            .older => if (self.browsing) |at| at -| 1 else count - 1,
            .newer => if (self.browsing) |at| if (at + 1 < count) at + 1 else null else null,
        };
        self.edit.set(if (self.browsing) |at| self.history.items[at] else "") catch {};
        self.endCycle(gpa);
    }
};

/// The field in a palette's colours: weeoui's text, caret and selection, on the palette's band
/// with no box around it.
const Field = struct {
    input: ui.Input,
    palette: Palette,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Field = @ptrCast(@alignCast(context));
        const theme = c.theme;
        defer c.theme = theme;
        c.theme = self.palette.fieldTheme(theme);
        const painted = ui.Layout.Element{ .paint_kind = .{ .input = self.input }, .bounds = r, .clip = c.clip orelse r };
        try painted.draw(c);
        // weeoui edges a focused field; on the band, the band is edge enough.
        try c.outline(r, self.palette.band);
    }
};

/// The candidates as a row, painted in the frame they are declared: chips in the theme, or
/// plain words in a palette with the one Tab is on lit.
const Chips = struct {
    names: []const []const u8,
    lit: ?usize,
    palette: ?Palette,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Chips = @ptrCast(@alignCast(context));
        if (self.palette) |palette| return self.drawWords(c, r, palette);
        const theme = c.theme;
        var x = r.x;
        for (self.names, 0..) |name, index| {
            const width = c.font.measure(name, chip_text_size) + chip_padding * 2;
            if (x + width > r.x + r.w) break;
            const chip = ui.Rect{ .x = x, .y = r.y, .w = width, .h = r.h };
            const lit = self.lit == index;
            try c.roundRect(chip, if (lit) theme.primary else theme.popover, r.h / 2);
            if (!lit) try c.roundRectStroke(chip, theme.border, r.h / 2, 1);
            try c.textIn(chip, name, chip_text_size, if (lit) theme.primary_foreground else theme.popover_foreground, .center);
            x += width + chip_gap;
        }
    }

    fn drawWords(self: *const Chips, c: *ui.Canvas, r: ui.Rect, palette: Palette) !void {
        // The first word's text lines up with the field's.
        var x = r.x + field_text_inset - chip_padding / 2;
        for (self.names, 0..) |name, index| {
            const width = c.font.measure(name, chip_text_size) + chip_padding;
            if (x + width > r.x + r.w) break;
            const word = ui.Rect{ .x = x, .y = r.y + 2, .w = width, .h = r.h - 4 };
            const lit = self.lit == index;
            if (lit) try c.rect(word, palette.yolk);
            try c.textIn(word, name, chip_text_size, if (lit) palette.on_yolk else palette.dim, .center);
            x += width + chip_gap;
        }
    }
};

const TestCompleter = struct {
    fn completer() Completer {
        return .{ .context = undefined, .complete = complete };
    }
    fn complete(_: *anyopaque, arena: std.mem.Allocator, line: []const u8, cursor: usize) anyerror!completion.Completion {
        return completion.complete(arena, line, cursor, .{ .commands = &.{ "get", "god" }, .buzz = &.{}, .entities = &.{}, .fields = &.{} });
    }
};

test "Tab turns through the candidates, and typing ends the turn" {
    const gpa = std.testing.allocator;
    var prompt = Prompt{};
    defer prompt.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try prompt.edit.set("g");
    prompt.complete(gpa, arena.allocator(), TestCompleter.completer(), 1);
    try std.testing.expectEqualStrings("get", prompt.edit.text());
    prompt.complete(gpa, arena.allocator(), TestCompleter.completer(), 1);
    try std.testing.expectEqualStrings("god", prompt.edit.text());
    prompt.complete(gpa, arena.allocator(), TestCompleter.completer(), -1);
    try std.testing.expectEqualStrings("get", prompt.edit.text());
}

test "Up and Down walk back and forth through the lines run" {
    const gpa = std.testing.allocator;
    var prompt = Prompt{};
    defer prompt.deinit(gpa);
    prompt.remember(gpa, "help");
    prompt.remember(gpa, "timescale 2");
    prompt.remember(gpa, "timescale 2");
    try std.testing.expectEqual(@as(usize, 2), prompt.history.items.len);
    prompt.recall(gpa, .older);
    try std.testing.expectEqualStrings("timescale 2", prompt.edit.text());
    prompt.recall(gpa, .older);
    prompt.recall(gpa, .older);
    try std.testing.expectEqualStrings("help", prompt.edit.text());
    prompt.recall(gpa, .newer);
    prompt.recall(gpa, .newer);
    try std.testing.expectEqualStrings("", prompt.edit.text());
}
