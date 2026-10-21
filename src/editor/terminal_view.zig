//! A terminal-looking view of text output, in JetBrains Mono: light text on near-black (commands,
//! log levels and source locations coloured), wrapped to its width, following the end unless scrolled back. Like a terminal it can scroll (wheel, Page
//! Up/Down, Home/End), select (drag, double-click a word, triple-click a line, Ctrl+A) and copy
//! (Ctrl+C or Ctrl+Shift+C, or a right-click). While a build runs, its steps can be pinned under
//! the output (`showSteps`, drawn by `terminal_steps.zig`).
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const terminal_steps = @import("terminal_steps.zig");
const Step = @import("projects/build_steps.zig").Step;

const background = ui.Color{ 0.07, 0.07, 0.08 };
const foreground = ui.Color{ 0.82, 0.82, 0.8 };
const text_size: f32 = 12;
const line_height = text_size * 1.5;
const padding: f32 = 10;

/// A clickable terminal line, sharing the output view's monospace face and severity colours.
/// Its text and paint state live for the builder's frame; long lines wrap at whole characters.
/// Editor Console helper: `id == 0` makes a noninteractive label; otherwise it is a button
/// whose expanded/highlight state follows `selected`. Borrowed text/font must survive drawing;
/// the returned element/state belong to `b.allocator`. Allocation errors propagate.
///
/// ```zig
/// const line = try terminal_view.messageLine(b, mono, context.idFor("message-1"), "error: broken", false);
/// context.element(line);
/// ```
pub fn messageLine(b: ui.Layout.Builder, mono: *const ui.Font, id: u32, text: []const u8, selected: bool) !*ui.Layout.Element {
    const state = try b.allocator.create(MessageLine);
    state.* = .{ .mono = mono, .id = id, .text = text, .selected = selected };
    const element = try b.node(id, .{}, .{ .custom = .{ .context = state, .measure = MessageLine.measure, .draw = MessageLine.draw } }, &.{});
    element.accessibility = .{ .role = if (id == 0) .label else .button, .label = text, .expanded = if (id == 0) null else selected };
    if (id != 0) element.cursor = .pointer;
    return element;
}

/// A continuous terminal background for independently clickable message lines.
/// Width/height are logical points. Borrows persistent `scroll` and frame-owned `lines`
/// through layout/draw; enables its overlay scrollbar. Returns a builder-arena element
/// or allocation error without owning the scroll state.
///
/// ```zig
/// const line = try terminal_view.messageLine(b, mono, 0, "No messages.", false);
/// context.element(try terminal_view.messageList(b, context.contentWidth(), 240, &scroll, &.{line}));
/// ```
pub fn messageList(b: ui.Layout.Builder, width: f32, height: f32, scroll: *ui.Layout.ScrollState, lines: []const *ui.Layout.Element) !*ui.Layout.Element {
    const element = try b.node(0, .{
        .width = width,
        .height = height,
        .padding = .{ .top = padding, .bottom = padding },
        .overflow = .scroll,
    }, .{ .custom = .{ .context = &background, .draw = drawBackground } }, lines);
    element.scroll = scroll;
    scroll.overlay_bar = true;
    element.accessibility = .{ .role = .log, .label = "Console messages", .live = .polite };
    return element;
}

const MessageLine = struct {
    mono: *const ui.Font,
    id: u32,
    text: []const u8,
    selected: bool,

    fn columns(self: *const MessageLine, width: f32) usize {
        return @max(1, @as(usize, @intFromFloat(@max(0, width - 2 * padding) / self.mono.measure("M", text_size))));
    }

    fn measure(context: *const anyopaque, width: f32, _: *const ui.Font) f32 {
        const self: *const MessageLine = @ptrCast(@alignCast(context));
        const count = self.columns(width);
        const rows = @max(1, (columnsIn(self.text) + count - 1) / count);
        return @as(f32, @floatFromInt(rows)) * line_height;
    }

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const MessageLine = @ptrCast(@alignCast(context));
        const previous_clip = c.clip;
        const previous_font = c.font;
        c.clip = if (previous_clip) |clip| clip.intersection(r) else r;
        c.font = self.mono;
        defer {
            c.clip = previous_clip;
            c.font = previous_font;
        }
        if (self.selected or (self.id != 0 and c.hot_id == self.id)) try c.rectAlpha(r, c.theme.primary, if (self.selected) 0.2 else 0.1);
        const count = self.columns(r.w);
        const char_width = self.mono.measure("M", text_size);
        var start: usize = 0;
        var y = r.y;
        const shown = c.clip.?;
        while (start < self.text.len and y < shown.y + shown.h) {
            const end = advanceColumns(self.text, start, self.text.len, count);
            // Rows scrolled out of view are only counted past.
            if (y + line_height < shown.y) {
                start = end;
                y += line_height;
                continue;
            }
            try drawLineRow(c, self.text, start, end, .{ .x = r.x + padding, .y = y, .w = @max(0, r.w - 2 * padding), .h = line_height }, char_width);
            start = end;
            y += line_height;
        }
    }
};

fn drawBackground(_: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    try c.roundRect(r, background, c.theme.radiusMd());
}

pub const TerminalView = struct {
    gpa: std.mem.Allocator,
    /// The monospace face, sharing the UI font's atlas (see `ui.Font.initCompanion`).
    mono: *const ui.Font,
    /// A copy of the output, so selections and input between frames have it.
    text: std.ArrayList(u8) = .empty,
    /// `text` cut into the rows it is drawn as, each a byte range, up to `wrapped_to` (the start
    /// of a line), for `columns` characters a row; 0 when they must all be cut again.
    rows: std.ArrayList(Row) = .empty,
    columns: usize = 0,
    wrapped_to: usize = 0,
    /// The output's version, as `add` was last given it.
    version: ?u64 = null,
    /// Rows scrolled back from the end; 0 follows new output.
    scroll_rows: usize = 0,
    /// Byte offsets into `text`; the selection runs between them.
    selection: ?struct { anchor: usize, focus: usize } = null,
    selecting: bool = false,
    /// Whether it takes keys: it was pressed last.
    focused: bool = false,
    /// Where it was drawn last, in its window's coordinates.
    area: ?ui.Rect = null,
    /// The build steps pinned under the output, once `showSteps` is called, and how tall they
    /// were drawn last.
    live: ?terminal_steps.Live = null,
    live_height: f32 = 0,

    /// A row's bytes, and the bytes of the line it was cut from (for colouring it).
    const Row = struct { start: usize, end: usize, line_start: usize, line_end: usize };

    /// Create a lazy editor output view borrowing a loaded monospaced companion font.
    /// `mono` must outlive `deinit`; keep the view at a stable address while frame paint
    /// callbacks refer to it. Owns copied output/row storage allocated on later use.
    ///
    /// ```zig
    /// var terminal = TerminalView.init(gpa, mono);
    /// defer terminal.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator, mono: *const ui.Font) TerminalView {
        return .{ .gpa = gpa, .mono = mono };
    }

    /// Free copied text and wrapped rows, not the borrowed font. No live frame may still
    /// draw this view; it and content/selection slices are invalid afterward.
    ///
    /// ```zig
    /// terminal.deinit(); // Before deinitializing mono.
    /// ```
    pub fn deinit(self: *TerminalView) void {
        self.text.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        if (self.live) |*live| live.deinit();
    }

    /// Pin `steps` under the output for this frame, animated at `time_ms`: a row each, opened by
    /// clicking it. `steps` is borrowed until the frame is drawn; call before `add` each frame.
    ///
    /// ```zig
    /// terminal.showSteps(status.steps, sdl3.timer.getMillisecondsSinceInit());
    /// terminal.add(context, status.log, status.log.len, height);
    /// ```
    pub fn showSteps(self: *TerminalView, steps: []const Step, time_ms: u64) void {
        if (self.live == null) self.live = .{ .gpa = self.gpa, .line_height = line_height };
        self.live.?.steps = steps;
        self.live.?.time_ms = time_ms;
    }

    /// Show `output` in a `height` tall view on `context`'s page. `version` changes whenever
    /// `output` does, so unchanged output costs nothing to show again.
    /// `height` is logical points; call in an active context frame. Copies output only on
    /// version change, so borrowed input can expire after this call. The view must remain
    /// stable/alive through rendering; allocation failures silently skip adding the view
    /// and may leave its copied output cleared or partially updated.
    ///
    /// ```zig
    /// terminal.add(context, build_log, log_version, 280);
    /// // The host renders context before moving or destroying terminal.
    /// ```
    pub fn add(self: *TerminalView, context: *ui.Context, output: []const u8, version: u64, height: f32) void {
        if (self.version != version) {
            self.setText(output) catch return;
            self.version = version;
        }
        const width = context.contentWidth();
        const element = context.builder().node(0, .{ .width = width, .height = height }, .{ .custom = .{ .context = self, .draw = draw } }, &.{}) catch return;
        element.accessibility.label = "Output";
        element.cursor = .text;
        context.element(element);
    }

    /// The output so far, all of it.
    /// Borrowed bytes from the last successful version update; invalidated by add/deinit.
    ///
    /// ```zig
    /// terminal_view.copyToClipboard(terminal.content());
    /// ```
    pub fn content(self: *const TerminalView) []const u8 {
        return self.text.items;
    }

    /// The selected text, or null without a selection.
    /// Empty selections also return null. Returned bytes borrow copied output until it changes
    /// or the view is destroyed; changing selection alone does not allocate.
    ///
    /// ```zig
    /// if (terminal.selectedText()) |text| terminal_view.copyToClipboard(text);
    /// ```
    pub fn selectedText(self: *const TerminalView) ?[]const u8 {
        const selection = self.selection orelse return null;
        const start = @min(selection.anchor, selection.focus);
        const end = @max(selection.anchor, selection.focus);
        if (start == end) return null;
        return self.text.items[start..end];
    }

    /// Handle an input event; returns whether the view used it.
    /// Editor-host route before the surrounding page UI; event coordinates are window logical
    /// points matching the last drawn `area`. Before the first draw returns false. Updates
    /// focus/selection/scroll and may copy to the OS clipboard; retains no event payload.
    ///
    /// ```zig
    /// // input is translated Weeoui input for this output view's window:
    /// if (terminal.handle(input)) return;
    /// context.handle(input);
    /// ```
    pub fn handle(self: *TerminalView, event: ui.input.Event) bool {
        const area = self.area orelse return false;
        switch (event) {
            .pointer_down => |down| {
                const inside = area.contains(down.position.x, down.position.y);
                self.focused = inside;
                if (!inside) return false;
                // A press on the pinned steps opens or closes one, rather than selecting.
                if (self.live) |*live| if (live.area) |steps_area| if (down.button == .left and steps_area.contains(down.position.x, down.position.y)) {
                    _ = live.click(down.position.y);
                    return true;
                };
                switch (down.button) {
                    // A right-click copies, as Windows Terminal does.
                    .right => copyToClipboard(self.selectedText() orelse return true),
                    .middle => {},
                    .left => {
                        const at = self.offsetAt(down.position.x, down.position.y);
                        self.selection = switch (down.clicks) {
                            0, 1 => .{ .anchor = at, .focus = at },
                            2 => self.wordAround(at),
                            else => self.lineAround(at),
                        };
                        self.selecting = down.clicks <= 1;
                    },
                }
                return true;
            },
            .pointer_move => |p| {
                if (!self.selecting) return false;
                if (self.selection) |*selection| selection.focus = self.offsetAt(p.x, p.y);
                return true;
            },
            .pointer_up => {
                if (!self.selecting) return false;
                self.selecting = false;
                return true;
            },
            .wheel => |wheel| {
                if (!area.contains(wheel.position.x, wheel.position.y)) return false;
                // Over the pinned steps, the wheel scrolls them rather than the output.
                if (self.live) |*live| if (live.area) |steps_area| if (steps_area.contains(wheel.position.x, wheel.position.y)) {
                    live.scrollBy(@intFromFloat(@round(wheel.delta.y * 3)));
                    return true;
                };
                self.scrollBy(@intFromFloat(@round(wheel.delta.y * 3)));
                return true;
            },
            .key_down => |key| {
                if (!self.focused) return false;
                const command = key.modifiers.control or key.modifiers.super;
                switch (key.key) {
                    .c => if (command) copyToClipboard(self.selectedText() orelse return true) else return false,
                    .a => if (command) {
                        self.selection = .{ .anchor = 0, .focus = self.text.items.len };
                    } else return false,
                    .escape => self.selection = null,
                    .page_up => self.scrollBy(@intCast(self.visibleRows())),
                    .page_down => self.scrollBy(-@as(isize, @intCast(self.visibleRows()))),
                    .home => self.scroll_rows = self.rows.items.len,
                    .end => self.scroll_rows = 0,
                    else => return false,
                }
                return true;
            },
            else => return false,
        }
    }

    /// Take `output` as the view's text: appended to if it grew (only the new part is wrapped),
    /// else replaced.
    fn setText(self: *TerminalView, output: []const u8) !void {
        if (std.mem.startsWith(u8, output, self.text.items)) {
            if (output.len == self.text.items.len) return;
            try self.text.appendSlice(self.gpa, output[self.text.items.len..]);
        } else {
            self.text.clearRetainingCapacity();
            try self.text.appendSlice(self.gpa, output);
            self.selection = null;
            self.columns = 0; // every row is stale
        }
    }

    /// Cut `text` into rows of at most `columns` characters, breaking at newlines: all of it at
    /// a new width, else only what was added since.
    fn wrap(self: *TerminalView, columns: usize) !void {
        if (columns != self.columns) {
            self.columns = columns;
            self.rows.clearRetainingCapacity();
            self.wrapped_to = 0;
        }
        const text = std.mem.trimEnd(u8, self.text.items, "\n");
        if (self.wrapped_to > text.len) return;
        // The last line wrapped may have grown since: cut it again, with what follows.
        while (self.rows.items.len > 0 and self.rows.items[self.rows.items.len - 1].start >= self.wrapped_to) _ = self.rows.pop();
        var start = self.wrapped_to;
        while (start <= text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
            // At least one row per line, even an empty one.
            var row_start = start;
            while (true) {
                const row_end = advanceColumns(text, row_start, line_end, columns);
                try self.rows.append(self.gpa, .{ .start = row_start, .end = row_end, .line_start = start, .line_end = line_end });
                if (row_end >= line_end) break;
                row_start = row_end;
            }
            // The last line stays open to more text; the rows before it are done.
            if (line_end == text.len) {
                self.wrapped_to = start;
                break;
            }
            start = line_end + 1;
        }
    }

    fn visibleRows(self: *const TerminalView) usize {
        const area = self.area orelse return 1;
        return @max(1, @as(usize, @intFromFloat(@max(0, area.h - 2 * padding - self.live_height) / line_height)));
    }

    /// The first row on screen, given the scroll.
    fn firstRow(self: *const TerminalView) usize {
        const visible = self.visibleRows();
        if (self.rows.items.len <= visible) return 0;
        return self.rows.items.len - visible - @min(self.scroll_rows, self.rows.items.len - visible);
    }

    fn scrollBy(self: *TerminalView, rows: isize) void {
        const most = self.rows.items.len -| self.visibleRows();
        const scrolled = @as(isize, @intCast(self.scroll_rows)) + rows;
        self.scroll_rows = @intCast(std.math.clamp(scrolled, 0, @as(isize, @intCast(most))));
    }

    fn charWidth(self: *const TerminalView) f32 {
        return self.mono.measure("M", text_size);
    }

    /// The byte offset in `text` nearest (x, y), for selecting.
    fn offsetAt(self: *const TerminalView, x: f32, y: f32) usize {
        const area = self.area orelse return 0;
        if (self.rows.items.len == 0) return 0;
        const row_on_screen: isize = @intFromFloat(@floor((y - area.y - padding) / line_height));
        const row_index: usize = @intCast(std.math.clamp(@as(isize, @intCast(self.firstRow())) + row_on_screen, 0, @as(isize, @intCast(self.rows.items.len - 1))));
        const row = self.rows.items[row_index];
        const column: usize = @intFromFloat(@max(0, @round((x - area.x - padding) / self.charWidth())));
        return advanceColumns(self.text.items, row.start, row.end, column);
    }

    fn wordAround(self: *const TerminalView, at: usize) @FieldType(TerminalView, "selection") {
        const text = self.text.items;
        var start = at;
        while (start > 0 and !std.ascii.isWhitespace(text[start - 1])) start -= 1;
        var end = at;
        while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;
        return .{ .anchor = start, .focus = end };
    }

    fn lineAround(self: *const TerminalView, at: usize) @FieldType(TerminalView, "selection") {
        const text = self.text.items;
        const start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |newline| newline + 1 else 0;
        const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
        return .{ .anchor = start, .focus = end };
    }

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *TerminalView = @ptrCast(@alignCast(@constCast(context)));
        self.area = r;
        try c.roundRect(r, background, c.theme.radiusMd());

        // Clip to the inside, and draw in the monospace face.
        const inner = r.inset(padding);
        const previous_clip = c.clip;
        const previous_font = c.font;
        c.clip = if (previous_clip) |clip| clip.intersection(inner) else inner;
        c.font = self.mono;
        defer {
            c.clip = previous_clip;
            c.font = previous_font;
        }

        const char_width = self.charWidth();

        // The build's steps take the bottom, up to half the view; the output scrolls above them.
        self.live_height = 0;
        if (self.live) |*live| {
            live.area = null;
            const all_rows: usize = @intFromFloat(@max(0, inner.h) / line_height);
            const lines = if (live.steps.len == 0) 0 else live.layout(@max(3, all_rows / 2));
            if (lines > 0) {
                const steps_h = @as(f32, @floatFromInt(lines)) * line_height;
                self.live_height = steps_h + line_height * 0.75;
                try live.draw(c, .{ .x = inner.x, .y = inner.y + inner.h - steps_h, .w = inner.w, .h = steps_h }, char_width, text_size);
            }
        }

        try self.wrap(@max(1, @as(usize, @intFromFloat(inner.w / char_width))));
        const first = self.firstRow();
        const last = @min(self.rows.items.len, first + self.visibleRows());
        const selected = if (self.selection) |s| [2]usize{ @min(s.anchor, s.focus), @max(s.anchor, s.focus) } else [2]usize{ 0, 0 };
        for (self.rows.items[first..last], 0..) |row, i| {
            const y = inner.y + @as(f32, @floatFromInt(i)) * line_height;

            // The selected part of the row, behind its text.
            const from = std.math.clamp(selected[0], row.start, row.end);
            const to = std.math.clamp(selected[1], row.start, row.end);
            if (to > from or (selected[0] < row.start and selected[1] > row.end)) {
                const x0 = inner.x + @as(f32, @floatFromInt(columnsIn(self.text.items[row.start..from]))) * char_width;
                const x1 = inner.x + @as(f32, @floatFromInt(columnsIn(self.text.items[row.start..to]))) * char_width + if (selected[1] > row.end) char_width else 0;
                try c.rectAlpha(.{ .x = x0, .y = y, .w = x1 - x0, .h = line_height }, c.theme.primary, 0.35);
            }
            // The row's text, a coloured span at a time (see `lineSpans`).
            try drawLineRow(c, self.text.items[row.line_start..row.line_end], row.start - row.line_start, row.end - row.line_start, .{ .x = inner.x, .y = y, .w = inner.w, .h = line_height }, char_width);
        }

        // A thin scrollbar when there's more than fits.
        const total = self.rows.items.len;
        const visible = self.visibleRows();
        if (total > visible) {
            const track = ui.Rect{ .x = r.x + r.w - 5, .y = inner.y, .w = 3, .h = inner.h - self.live_height };
            const thumb_h = @max(12, track.h * @as(f32, @floatFromInt(visible)) / @as(f32, @floatFromInt(total)));
            const thumb_y = track.y + (track.h - thumb_h) * @as(f32, @floatFromInt(first)) / @as(f32, @floatFromInt(total - visible));
            c.clip = previous_clip;
            try c.roundRect(.{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h }, c.theme.muted_foreground, 1.5);
        }
    }
};

fn drawLineRow(c: *ui.Canvas, line: []const u8, start: usize, end: usize, r: ui.Rect, char_width: f32) !void {
    var spans_buffer: [max_spans]Span = undefined;
    for (lineSpans(line, start, end, c.theme, &spans_buffer)) |span| {
        const from = @max(start, span.start);
        const to = @min(end, span.end);
        if (to <= from) continue;
        const x = r.x + @as(f32, @floatFromInt(columnsIn(line[start..from]))) * char_width;
        try c.textIn(.{ .x = x, .y = r.y, .w = r.x + r.w - x, .h = r.h }, line[from..to], text_size, span.color, .start);
    }
}

/// A run of a line drawn in one colour: bytes `start..end` of the line.
const Span = struct { start: usize, end: usize, color: ui.Color };
const max_spans = 64;
/// How far back from a row a highlight it starts inside may begin, and how far into a line its
/// level and scope may run.
const max_lookback = 256;

const red = ui.Color{ 0.94, 0.42, 0.42 };
const soft_red = ui.Color{ 0.96, 0.7, 0.68 };
const amber = ui.Color{ 0.95, 0.75, 0.3 };
const soft_amber = ui.Color{ 0.95, 0.86, 0.66 };
const blue = ui.Color{ 0.45, 0.68, 0.98 };
const cyan = ui.Color{ 0.45, 0.82, 0.85 };
const violet = ui.Color{ 0.68, 0.6, 0.9 };
const grey = ui.Color{ 0.5, 0.5, 0.5 };

/// `line` cut into coloured spans, as a terminal would show it: a command (`$ ...`) in the
/// theme's primary colour; a log line's level by severity, its `(scope)` in violet and its
/// message tinted by severity; and in messages, `file.zig:12:5` locations in cyan and `error:`,
/// `warning:` and `note:` in their colours. Covers at least bytes `from..to` (a row of it), looking
/// no further, so a huge line costs only the rows drawn. Uses `buffer` for the result.
fn lineSpans(line: []const u8, from: usize, to: usize, theme: ui.Theme, buffer: *[max_spans]Span) []const Span {
    var spans: std.ArrayList(Span) = .initBuffer(buffer);
    if (std.mem.startsWith(u8, line, "$ ")) {
        spans.appendAssumeCapacity(.{ .start = 0, .end = line.len, .color = theme.primary });
        return spans.items;
    }

    // The level and scope (`warning(projects): `), when the line is a log message.
    const Level = struct { word: []const u8, color: ui.Color, message: ui.Color };
    const levels = [_]Level{
        .{ .word = "error", .color = red, .message = soft_red },
        .{ .word = "warning", .color = amber, .message = soft_amber },
        .{ .word = "info", .color = blue, .message = foreground },
        .{ .word = "debug", .color = grey, .message = grey },
    };
    var message_start: usize = 0;
    var message_color = foreground;
    for (levels) |level| {
        if (!std.mem.startsWith(u8, line, level.word)) continue;
        const colon = std.mem.indexOfPos(u8, line[0..@min(line.len, max_lookback)], level.word.len, ": ") orelse break;
        const scope = line[level.word.len..colon];
        if (scope.len > 0 and !(scope[0] == '(' and scope[scope.len - 1] == ')')) break;
        spans.appendAssumeCapacity(.{ .start = 0, .end = level.word.len, .color = level.color });
        if (scope.len > 0) spans.appendAssumeCapacity(.{ .start = level.word.len, .end = colon, .color = violet });
        message_start = colon;
        message_color = level.message;
        break;
    }

    // The message, with locations and diagnostics picked out, from the start of the word the
    // row starts in (a highlight may begin there).
    var at = @max(message_start, from);
    while (at > message_start and from - at < max_lookback and !wordStartsAt(line, at)) at -= 1;
    var plain_from = message_start;
    while (at < @min(line.len, to) and spans.items.len + 2 < max_spans) {
        // Only at the start of a word.
        if (!wordStartsAt(line, at)) {
            at += 1;
            continue;
        }
        const highlight: ?struct { len: usize, color: ui.Color } = if (locationLength(line[at..])) |len|
            .{ .len = len, .color = cyan }
        else if (std.mem.startsWith(u8, line[at..], "error:"))
            .{ .len = "error:".len, .color = red }
        else if (std.mem.startsWith(u8, line[at..], "warning:"))
            .{ .len = "warning:".len, .color = amber }
        else if (std.mem.startsWith(u8, line[at..], "note:"))
            .{ .len = "note:".len, .color = cyan }
        else
            null;
        if (highlight == null) {
            at += 1;
            continue;
        }
        if (at > plain_from) spans.appendAssumeCapacity(.{ .start = plain_from, .end = at, .color = message_color });
        spans.appendAssumeCapacity(.{ .start = at, .end = at + highlight.?.len, .color = highlight.?.color });
        at += highlight.?.len;
        plain_from = at;
    }
    if (line.len > plain_from) spans.appendAssumeCapacity(.{ .start = plain_from, .end = line.len, .color = message_color });
    return spans.items;
}

fn wordStartsAt(line: []const u8, at: usize) bool {
    return at == 0 or line[at - 1] == ' ' or line[at - 1] == '(';
}

/// How long the source location (`path.zig:12` or `path.zig:12:5`) starting `text` is, if one does.
fn locationLength(text: []const u8) ?usize {
    const extension = ".zig:";
    const name_end = std.mem.indexOfAny(u8, text, " \t\"'()") orelse text.len;
    const found = std.mem.indexOf(u8, text[0..name_end], extension) orelse return null;
    var end = found + extension.len;
    var numbers: usize = 0;
    while (numbers < 2) : (numbers += 1) {
        const digits_end = std.mem.indexOfNonePos(u8, text, end, "0123456789") orelse text.len;
        if (digits_end == end) break;
        end = digits_end;
        if (end < text.len and text[end] == ':' and numbers == 0 and end + 1 < text.len and std.ascii.isDigit(text[end + 1])) end += 1 else break;
    }
    return if (end > found + extension.len) end else null;
}

/// Put `text` on the clipboard.
/// Editor-host helper requiring SDL clipboard support. Copies borrowed bytes into a
/// temporary C-allocator sentinel string, freed before return; allocation failure is ignored
/// and SDL clipboard failure logs a warning.
///
/// ```zig
/// terminal_view.copyToClipboard(terminal.selectedText() orelse terminal.content());
/// ```
pub fn copyToClipboard(text: []const u8) void {
    var buffer = std.heap.c_allocator.dupeZ(u8, text) catch return;
    defer std.heap.c_allocator.free(buffer);
    sdl3.clipboard.setText(buffer[0..text.len :0]) catch |err| std.log.warn("cannot copy: {t}", .{err});
}

/// The offset `columns` characters on from `start`, stopping at `end`.
fn advanceColumns(text: []const u8, start: usize, end: usize, columns: usize) usize {
    var at = start;
    var counted: usize = 0;
    while (at < end and counted < columns) : (counted += 1) {
        at += std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
    }
    return @min(at, end);
}

/// How many characters `text` holds.
fn columnsIn(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

test "output wraps into rows of whole characters, a row per empty line too" {
    var view = TerminalView.init(std.testing.allocator, undefined);
    defer view.deinit();
    try view.setText("abcdef\n\nxy\u{e9}z\n");
    try view.wrap(3);
    try std.testing.expectEqual(@as(usize, 5), view.rows.items.len);
    const text = view.text.items;
    try std.testing.expectEqualStrings("abc", text[view.rows.items[0].start..view.rows.items[0].end]);
    try std.testing.expectEqualStrings("def", text[view.rows.items[1].start..view.rows.items[1].end]);
    try std.testing.expectEqualStrings("", text[view.rows.items[2].start..view.rows.items[2].end]);
    try std.testing.expectEqualStrings("xy\u{e9}", text[view.rows.items[3].start..view.rows.items[3].end]);
}

test "a growing output keeps the selection; a different one drops it" {
    var view = TerminalView.init(std.testing.allocator, undefined);
    defer view.deinit();
    try view.setText("one two\n");
    view.selection = view.wordAround(5);
    try std.testing.expectEqualStrings("two", view.selectedText().?);
    try view.setText("one two\nthree\n");
    try std.testing.expectEqualStrings("two", view.selectedText().?);
    view.selection = view.lineAround(10);
    try std.testing.expectEqualStrings("three", view.selectedText().?);
    try view.setText("other");
    try std.testing.expect(view.selectedText() == null);
}

test "a log line is coloured by level, scope and the locations in it" {
    var buffer: [max_spans]Span = undefined;
    const line = "error(zig_build): src/main.zig:12:5: error: expected ';'";
    const spans = lineSpans(line, 0, line.len, .{}, &buffer);
    try std.testing.expectEqualStrings("error", line[spans[0].start..spans[0].end]);
    try std.testing.expectEqualStrings("(zig_build)", line[spans[1].start..spans[1].end]);
    try std.testing.expectEqual(cyan, spans[3].color);
    try std.testing.expectEqualStrings("src/main.zig:12:5", line[spans[3].start..spans[3].end]);
    try std.testing.expectEqualStrings("error:", line[spans[5].start..spans[5].end]);
    // Every byte is drawn, once.
    var covered: usize = 0;
    for (spans) |span| covered += span.end - span.start;
    try std.testing.expectEqual(line.len, covered);
}

test "output added a bit at a time wraps as it would all at once" {
    var growing = TerminalView.init(std.testing.allocator, undefined);
    defer growing.deinit();
    var whole = TerminalView.init(std.testing.allocator, undefined);
    defer whole.deinit();
    const output = "a long first line\nsecond\n\nthe last one, and longer\n";
    // Line by line, and a line in two halves, wrapping after each.
    for ([_]usize{ 5, 18, 25, 26, 40, output.len }) |end| {
        try growing.setText(output[0..end]);
        try growing.wrap(7);
    }
    try whole.setText(output);
    try whole.wrap(7);
    try std.testing.expectEqualSlices(TerminalView.Row, whole.rows.items, growing.rows.items);
}

test "a huge line colours only the rows drawn, and its later locations too" {
    const gpa = std.testing.allocator;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    // Thousands of locations, no spaces: once quadratic in the line's length, every row.
    for (0..4000) |i| try line.print(gpa, "(pkg/src/file.zig:{d}:5", .{i});
    var buffer: [max_spans]Span = undefined;
    const from = line.items.len - 120;
    const spans = lineSpans(line.items, from, line.items.len, .{}, &buffer);
    // The row's last location is still picked out.
    const last = spans[spans.len - 1];
    try std.testing.expectEqual(cyan, last.color);
    try std.testing.expectEqualStrings("pkg/src/file.zig:3999:5", line.items[last.start..last.end]);
    // Nothing before the row's first word was looked at.
    try std.testing.expect(spans[1].start + max_lookback >= from);
}
