//! The live block a terminal view pins under its output while a build runs: a row per build step
//! with a bar of character-sized cells, as if the terminal printed it, and, for a row clicked
//! open, the work inside that step, each with its own thinner bar.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const build_steps = @import("projects/build_steps.zig");
const Step = build_steps.Step;

// Running is the yolk, finished is sage, stopped is brick; cells not yet filled are charcoal.
const yolk = [4]f32{ 0.949, 0.702, 0.239, 1 };
const sage = [4]f32{ 0.498, 0.714, 0.522, 1 };
const brick = [4]f32{ 0.898, 0.376, 0.298, 1 };
const empty_cell = ui.Color{ 0.145, 0.145, 0.173 };
const rule = ui.Color{ 0.2, 0.2, 0.23 };
const name_color = ui.Color{ 0.82, 0.82, 0.8 };
const dim = ui.Color{ 0.52, 0.52, 0.5 };

/// Lines the block can hold, however tall the view.
const max_lines = 48;

/// What one line of the block shows.
const Line = union(enum) {
    /// Finished steps folded away, and how many.
    folded: usize,
    step: usize,
    work: struct { step: usize, work: usize },
};

pub const Live = struct {
    gpa: std.mem.Allocator,
    /// This frame's steps, borrowed until it is drawn; empty after, since a click comes once the
    /// frame (and its copy of the steps) is gone.
    steps: []const Step = &.{},
    time_ms: u64 = 0,
    /// Steps opened to show their work, by their name's hash; kept across frames.
    opened: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The lines as last laid out, and where they were drawn, for clicking.
    lines: [max_lines]Line = undefined,
    /// Each line's step, by its name's hash (0 for the folded line), which is all a click needs.
    line_keys: [max_lines]u64 = undefined,
    line_count: usize = 0,
    area: ?ui.Rect = null,
    line_height: f32 = 18,

    pub fn deinit(self: *Live) void {
        self.opened.deinit(self.gpa);
    }

    /// Lay the block out in at most `budget` lines: every step, the work of those opened, and
    /// when that's too many, the oldest finished steps folded into one line. Returns the count.
    pub fn layout(self: *Live, budget_lines: usize) usize {
        const budget = @min(budget_lines, max_lines);
        var foldable: usize = 0;
        for (self.steps) |*step| {
            if (step.state == .done and !self.isOpen(step)) foldable += 1;
        }
        var folded: usize = 0;
        while (true) {
            self.line_count = 0;
            if (folded > 0) self.push(.{ .folded = folded });
            var skipped: usize = 0;
            for (self.steps, 0..) |*step, index| {
                if (step.state == .done and skipped < folded and !self.isOpen(step)) {
                    skipped += 1;
                    continue;
                }
                self.push(.{ .step = index });
                if (!self.isOpen(step)) continue;
                for (0..step.works().len) |work| self.push(.{ .work = .{ .step = index, .work = work } });
            }
            if (self.line_count <= budget or folded == foldable) break;
            folded += 1;
        }
        self.line_count = @min(self.line_count, budget);
        return self.line_count;
    }

    fn push(self: *Live, line: Line) void {
        if (self.line_count == max_lines) return;
        self.lines[self.line_count] = line;
        self.line_keys[self.line_count] = switch (line) {
            .folded => 0,
            .step => |index| stepKey(&self.steps[index]),
            .work => |at| stepKey(&self.steps[at.step]),
        };
        self.line_count += 1;
    }

    fn isOpen(self: *const Live, step: *const Step) bool {
        return self.opened.contains(stepKey(step));
    }

    fn stepKey(step: *const Step) u64 {
        return std.hash.Wyhash.hash(0, step.name());
    }

    /// A press at `y` in the block: a step's row opens or closes. Returns whether it was on one.
    pub fn click(self: *Live, y: f32) bool {
        const area = self.area orelse return false;
        const row = @floor((y - area.y) / self.line_height);
        if (row < 0 or row >= @as(f32, @floatFromInt(self.line_count))) return false;
        const line: usize = @intFromFloat(row);
        if (self.lines[line] == .folded) return true;
        const key = self.line_keys[line];
        if (self.opened.fetchRemove(key) == null) self.opened.put(self.gpa, key, {}) catch {};
        return true;
    }

    /// Draw the laid-out lines into `r`, a dim rule above them, in the canvas's (monospace)
    /// font, `char_width` points a column.
    pub fn draw(self: *Live, c: *ui.Canvas, r: ui.Rect, char_width: f32, text_size: f32) !void {
        try c.rect(.{ .x = r.x, .y = r.y - self.line_height * 0.35, .w = r.w, .h = 1 }, rule);
        self.area = r;
        const columns: usize = @intFromFloat(@max(1, r.w / char_width));
        const bar_cells: usize = if (columns >= 72) 24 else if (columns >= 48) 14 else 8;
        const tail_columns: usize = 5;
        // Caret, state, then the name; the bar and its percentage keep to the right.
        const bar_x = r.x + @as(f32, @floatFromInt(columns -| (bar_cells + tail_columns + 1))) * char_width;
        const name_x = r.x + 4 * char_width;
        for (self.lines[0..self.line_count], 0..) |line, i| {
            const y = r.y + @as(f32, @floatFromInt(i)) * self.line_height;
            const row = ui.Rect{ .x = r.x, .y = y, .w = r.w, .h = self.line_height };
            const middle = y + self.line_height / 2;
            switch (line) {
                .folded => |count| {
                    try check(c, r.x + 2.5 * char_width, middle, sage);
                    var buffer: [48]u8 = undefined;
                    const text = std.fmt.bufPrint(&buffer, "{d} earlier step{s} done", .{ count, if (count == 1) "" else "s" }) catch "";
                    try c.textIn(.{ .x = name_x, .y = y, .w = bar_x - name_x, .h = row.h }, text, text_size, dim, .start);
                },
                .step => |index| {
                    const step = &self.steps[index];
                    if (step.works().len > 0) try caret(c, r.x + 0.8 * char_width, middle, self.isOpen(step));
                    switch (step.state) {
                        .running => try spinner(c, r.x + 2.5 * char_width, middle, self.time_ms),
                        .done => try check(c, r.x + 2.5 * char_width, middle, sage),
                        .failed => try cross(c, r.x + 2.5 * char_width, middle, brick),
                    }
                    try self.label(c, name_x, y, bar_x - char_width, step.name(), step.task(), if (step.state == .running) name_color else dim, text_size, char_width);
                    try bar(c, bar_x, y, bar_cells, char_width, self.line_height, step.fraction, step.state, self.time_ms, false);
                    try percent(c, bar_x + @as(f32, @floatFromInt(bar_cells + 1)) * char_width, y, tail_columns, char_width, self.line_height, step, text_size);
                },
                .work => |at| {
                    const work = &self.steps[at.step].works()[at.work];
                    const indent = @as(f32, @floatFromInt(work.depth)) * 2 * char_width;
                    var count_buffer: [32]u8 = undefined;
                    const count = if (work.total) |total| std.fmt.bufPrint(&count_buffer, "{d}/{d}", .{ work.done, total }) catch "" else "";
                    try self.label(c, name_x + indent, y, bar_x - char_width, work.name(), count, dim, text_size, char_width);
                    const fraction: ?f32 = if (work.total) |total| std.math.clamp(@as(f32, @floatFromInt(work.done)) / @as(f32, @floatFromInt(total)), 0, 1) else null;
                    try bar(c, bar_x, y, bar_cells, char_width, self.line_height, fraction, .running, self.time_ms +% @as(u64, at.work) * 211, true);
                },
            }
        }
        self.steps = &.{};
    }

    /// `name`, then `detail` dimmer after it, both cut off at `right`.
    fn label(self: *const Live, c: *ui.Canvas, x: f32, y: f32, right: f32, name: []const u8, detail: []const u8, color: ui.Color, text_size: f32, char_width: f32) !void {
        if (right <= x) return;
        const previous = c.clip;
        const room = ui.Rect{ .x = x, .y = y, .w = right - x, .h = self.line_height };
        c.clip = if (previous) |clip| clip.intersection(room) else room;
        defer c.clip = previous;
        try c.textIn(room, name, text_size, color, .start);
        if (detail.len == 0) return;
        const after = x + @as(f32, @floatFromInt(name.len + 2)) * char_width;
        if (after < right) try c.textIn(.{ .x = after, .y = y, .w = right - after, .h = self.line_height }, detail, text_size, dim, .start);
    }
};

/// A bar of `cells` cells, each a column wide: filled to `fraction` (the leading cell in part),
/// or, unknown, a short comet sweeping to and fro. `thin` for work inside a step.
fn bar(c: *ui.Canvas, x: f32, y: f32, cells: usize, char_width: f32, line_height: f32, fraction: ?f32, state: Step.State, time_ms: u64, thin: bool) !void {
    const height: f32 = if (thin) line_height * 0.22 else line_height * 0.46;
    const top = y + (line_height - height) / 2;
    const cell_w = char_width - 2;
    const fill = switch (state) {
        .running => yolk,
        .done => sage,
        .failed => brick,
    };
    const alpha: f32 = if (state == .done) 0.55 else if (thin) 0.8 else 1;
    const cells_f: f32 = @floatFromInt(cells);
    // The comet's head runs to the end and back every 1.6 seconds.
    const phase = @as(f32, @floatFromInt(time_ms % 1600)) / 800;
    const head = (if (phase <= 1) phase else 2 - phase) * (cells_f - 1);
    const forward = phase <= 1;
    for (0..cells) |i| {
        const at = @as(f32, @floatFromInt(i));
        const cell = ui.Rect{ .x = x + at * char_width + 1, .y = top, .w = cell_w, .h = height };
        try c.roundRect(cell, empty_cell, 1);
        if (fraction) |done| {
            const filled = std.math.clamp(done * cells_f - at, 0, 1);
            if (filled > 0) try c.roundRectAlpha(.{ .x = cell.x, .y = cell.y, .w = cell.w * filled, .h = cell.h }, .{ fill[0], fill[1], fill[2] }, 1, alpha);
        } else if (state == .running) {
            // Brightest at the head, fading behind it the way it travels.
            const behind = if (forward) head - at else at - head;
            if (behind > -0.5 and behind < 3.5) {
                const glow = std.math.clamp(1 - behind / 3.5, 0.15, 1);
                try c.roundRectAlpha(cell, .{ fill[0], fill[1], fill[2] }, 1, glow * alpha);
            }
        } else if (state == .failed) {
            try c.roundRectAlpha(cell, .{ fill[0], fill[1], fill[2] }, 1, 0.35);
        }
    }
}

/// The percentage after a step's bar, right-aligned in `columns` columns; "done" once finished.
fn percent(c: *ui.Canvas, x: f32, y: f32, columns: usize, char_width: f32, line_height: f32, step: *const Step, text_size: f32) !void {
    var buffer: [8]u8 = undefined;
    const text: []const u8 = switch (step.state) {
        .done => "done",
        .failed => "",
        .running => if (step.fraction) |done| std.fmt.bufPrint(&buffer, "{d}%", .{@as(u32, @intFromFloat(done * 100))}) catch "" else "",
    };
    const color: ui.Color = if (step.state == .running) .{ yolk[0], yolk[1], yolk[2] } else dim;
    try c.textIn(.{ .x = x, .y = y, .w = @as(f32, @floatFromInt(columns)) * char_width, .h = line_height }, text, text_size, color, .end);
}

/// Eight dots round a ring, one bright and the rest fading after it, a step every 90 ms.
fn spinner(c: *ui.Canvas, x: f32, y: f32, time_ms: u64) !void {
    const lead = (time_ms / 90) % 8;
    for (0..8) |dot| {
        const angle = std.math.tau * @as(f32, @floatFromInt(dot)) / 8 - std.math.pi / 2.0;
        const age = (lead + 8 - dot) % 8;
        const alpha = 1 - @as(f32, @floatFromInt(age)) / 8;
        try c.roundRectAlpha(.{ .x = x + @cos(angle) * 4.5 - 1, .y = y + @sin(angle) * 4.5 - 1, .w = 2.2, .h = 2.2 }, .{ yolk[0], yolk[1], yolk[2] }, 1.1, alpha);
    }
}

fn check(c: *ui.Canvas, x: f32, y: f32, color: [4]f32) !void {
    try segment(c, .{ x - 4, y }, .{ x - 1.5, y + 3 }, 1, color);
    try segment(c, .{ x - 1.5, y + 3 }, .{ x + 4, y - 3.5 }, 1, color);
}

fn cross(c: *ui.Canvas, x: f32, y: f32, color: [4]f32) !void {
    try segment(c, .{ x - 3.5, y - 3.5 }, .{ x + 3.5, y + 3.5 }, 1, color);
    try segment(c, .{ x - 3.5, y + 3.5 }, .{ x + 3.5, y - 3.5 }, 1, color);
}

/// A small triangle: pointing right when closed, down when open.
fn caret(c: *ui.Canvas, x: f32, y: f32, open: bool) !void {
    const color = [4]f32{ dim[0], dim[1], dim[2], 1 };
    const colors = .{ color, color, color };
    if (open) {
        try c.triangle(.{ .{ x - 3.5, y - 2 }, .{ x + 3.5, y - 2 }, .{ x, y + 2.5 } }, colors);
    } else {
        try c.triangle(.{ .{ x - 2, y - 3.5 }, .{ x + 2.5, y }, .{ x - 2, y + 3.5 } }, colors);
    }
}

/// A line from `a` to `b`, `half_width` either side.
fn segment(c: *ui.Canvas, a: [2]f32, b: [2]f32, half_width: f32, color: [4]f32) !void {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const span = @sqrt(dx * dx + dy * dy);
    if (span < 0.01) return;
    const nx = -dy / span * half_width;
    const ny = dx / span * half_width;
    const colors = .{ color, color, color };
    try c.triangle(.{ .{ a[0] + nx, a[1] + ny }, .{ b[0] + nx, b[1] + ny }, .{ b[0] - nx, b[1] - ny } }, colors);
    try c.triangle(.{ .{ a[0] + nx, a[1] + ny }, .{ b[0] - nx, b[1] - ny }, .{ a[0] - nx, a[1] - ny } }, colors);
}

fn testStep(name: []const u8, state: Step.State, works: usize) Step {
    var step = Step{ .state = state };
    step.name_len = @intCast(name.len);
    @memcpy(step.name_buffer[0..name.len], name);
    for (0..works) |i| step.work[i] = .{ .depth = 1 };
    step.work_len = @intCast(works);
    return step;
}

test "a clicked step opens to its work, and finished steps fold away when there's no room" {
    var live = Live{ .gpa = std.testing.allocator };
    defer live.deinit();
    const steps = [_]Step{ testStep("a", .done, 0), testStep("b", .done, 0), testStep("c", .running, 3) };
    live.steps = &steps;
    try std.testing.expectEqual(@as(usize, 3), live.layout(10));

    // Clicking the running step's row opens it, after the frame's steps are gone: its three
    // pieces of work follow it.
    live.area = .{ .x = 0, .y = 100, .w = 400, .h = 200 };
    live.steps = &.{};
    try std.testing.expect(live.click(100 + 2.5 * live.line_height));
    live.steps = &steps;
    try std.testing.expectEqual(@as(usize, 6), live.layout(10));
    try std.testing.expectEqual(@as(usize, 2), live.lines[3].work.step);

    // With room for five, the two finished steps fold into one line.
    try std.testing.expectEqual(@as(usize, 5), live.layout(5));
    try std.testing.expectEqual(@as(usize, 2), live.lines[0].folded);

    // Clicking its work closes it again.
    live.area = .{ .x = 0, .y = 0, .w = 400, .h = 200 };
    live.steps = &.{};
    try std.testing.expect(live.click(2.5 * live.line_height));
    live.steps = &steps;
    try std.testing.expectEqual(@as(usize, 3), live.layout(5));
}
