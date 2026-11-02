//! A project's build as the loading screen and the Build window both show it: the project, the
//! stages so far with how long each took, the build's step under way and how many are done, its
//! output on request, and, when it fails, the first compile error with a button that opens it.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const job = @import("projects/job.zig");
const Status = job.Status;
const TerminalView = @import("terminal_view.zig").TerminalView;
const terminal_view = @import("terminal_view.zig");
const build_output = @import("projects/build_output.zig");
const diagnostic = @import("diagnostic.zig");
const code_editor = @import("code_editor.zig");
const project_tile = @import("projects/project_tile.zig");
const page_style = @import("page_style.zig");
const restyle = page_style.restyle;

/// What the window says it is doing to the project.
pub const Verb = enum {
    open,
    create,
    build,

    fn doing(verb: Verb) []const u8 {
        return switch (verb) {
            .open => "Opening",
            .create => "Creating",
            .build => "Building",
        };
    }

    fn infinitive(verb: Verb) []const u8 {
        return switch (verb) {
            .open => "open",
            .create => "create",
            .build => "build",
        };
    }
};

/// The project the build is for.
pub const Project = struct {
    verb: Verb,
    title: []const u8,
    /// Its folder, absolute.
    dir: []const u8,
    /// Its logo in the UI font's atlas; null shows its initial on a tile.
    logo: ?ui.Glyph = null,
};

/// How a finished build reads.
pub const Done = enum {
    /// The project's editor opens next: the build stays on screen until it does.
    launching,
    /// A new editor was built, for Reload to open.
    rebuilt,
    /// The build made no new editor.
    unchanged,
};

/// What the host's window offers.
pub const Options = struct {
    done: Done = .launching,
    /// The button that leaves a failed build: "Back to projects", or "Close".
    close_label: []const u8 = "Close",
    /// What "Open in ..." starts for the first error.
    code_editor: code_editor.Choice = .vscode,
};

/// What the buttons asked for this frame. The host carries it out.
pub const Action = enum { none, cancel, close, retry, reload };

/// The first compile error of a failed build, copied out of its output.
const FirstError = struct {
    /// `path:line:column`, as the compiler wrote it.
    where: []u8,
    message: []u8,
    /// The file, absolute.
    path: []u8,
    line: u32,
    column: u32,
};

/// Glyphs from the editor font's Nerd Font face.
const tick_glyph = "\u{f00c}";
const cross_glyph = "\u{f00d}";
const terminal_glyph = "\u{f120}";
const copy_glyph = "\u{f0c5}";

const stage_row_height: f32 = 30;
const footer_height: f32 = 52;

pub const BuildProgress = struct {
    gpa: std.mem.Allocator,
    mono: *const ui.Font,
    terminal: TerminalView,
    project: Project,
    /// Whether the output is shown in place of the stages.
    output_shown: bool = false,
    first_error: ?FirstError = null,
    /// Whether the failed output was searched for `first_error` yet.
    error_searched: bool = false,
    /// What opening the error said when it couldn't.
    open_failed: bool = false,

    /// Create the view for `project`, copying its text and borrowing `mono` (the monospace face),
    /// which must outlive `deinit`. The view must stay at one address while frames refer to it.
    ///
    /// ```zig
    /// var progress = try BuildProgress.init(gpa, mono, .{ .verb = .open, .title = "Space", .dir = "/home/me/space" });
    /// defer progress.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator, mono: *const ui.Font, project: Project) !BuildProgress {
        const title = try gpa.dupe(u8, project.title);
        errdefer gpa.free(title);
        const dir = try gpa.dupe(u8, project.dir);
        return .{ .gpa = gpa, .mono = mono, .terminal = .init(gpa, mono), .project = .{ .verb = project.verb, .title = title, .dir = dir, .logo = project.logo } };
    }

    /// Free the view's copies; the font and logo are not the view's.
    pub fn deinit(self: *BuildProgress) void {
        self.terminal.deinit();
        self.forgetError();
        self.gpa.free(self.project.title);
        self.gpa.free(self.project.dir);
    }

    /// Start over for a new build of the same project: its output and error are forgotten.
    ///
    /// ```zig
    /// if (action == .retry) progress.restart();
    /// ```
    pub fn restart(self: *BuildProgress) void {
        self.terminal.deinit();
        self.terminal = .init(self.gpa, self.mono);
        self.forgetError();
        self.output_shown = false;
    }

    /// Handle `input` for its window, before the page does; returns whether the output used it
    /// (selecting, copying, scrolling, or opening a step).
    pub fn handle(self: *BuildProgress, input: ui.input.Event) bool {
        return self.terminal.handle(input);
    }

    /// Show `status` as the whole page on `context`, filling the window, and return what its
    /// buttons asked for. `status` is borrowed until the frame is drawn.
    ///
    /// ```zig
    /// const action = progress.add(context, status, .{ .close_label = "Back to projects" });
    /// ```
    pub fn add(self: *BuildProgress, context: *ui.Context, status: Status, options: Options) Action {
        const height = page_style.pageHeight(context);
        context.begin(.column);
        const action = switch (status.stage) {
            .failed => self.failedPage(context, status, options, height),
            .done => if (options.done == .launching) self.workingPage(context, status) else self.donePage(context, status, options, height),
            else => if (self.output_shown) self.outputPage(context, status, height) else self.workingPage(context, status),
        };
        context.end();
        if (context.last_added) |page| page.style = .{ .height = height, .justify = .space_between, .gap = 0 };
        return action;
    }

    /// The project, its stages, the step under way, and Show output and Cancel.
    fn workingPage(self: *BuildProgress, context: *ui.Context, status: Status) Action {
        const arena = context.builder().allocator;
        context.begin(.column);
        self.header(context, .large, std.fmt.allocPrint(arena, "{s} {s}", .{ self.project.verb.doing(), self.project.title }) catch self.project.title, project_tile.homeRelative(arena, self.project.dir), .none);
        stageList(context, status);
        if (status.stage == .building or status.stage == .exporting) self.stepProgress(context, status);
        context.end();
        restyle(context, .{ .gap = 24, .padding = .{ .top = 12, .left = 12, .right = 12 } });

        var action: Action = .none;
        footerBegin(context);
        if (context.buttonVariant(terminal_glyph ++ "  Show output", .ghost)) self.output_shown = true;
        spacer(context);
        if (status.stage != .done and context.buttonVariant("Cancel", .outline)) action = .cancel;
        footerEnd(context);
        return action;
    }

    /// The output filling the window under a slim header and progress bar.
    fn outputPage(self: *BuildProgress, context: *ui.Context, status: Status, height: f32) Action {
        const arena = context.builder().allocator;
        context.begin(.column);
        const line = if (status.steps_total > 0)
            std.fmt.allocPrint(arena, "{s}, {d} of {d} steps", .{ status.stage.label(), status.steps_done, status.steps_total }) catch status.stage.label()
        else
            status.stage.label();
        self.header(context, .compact, std.fmt.allocPrint(arena, "{s} {s}", .{ self.project.verb.doing(), self.project.title }) catch self.project.title, line, .{ .elapsed = elapsed(arena, status) });
        context.progress(stepFraction(status));
        restyle(context, .{ .height = 4 });
        self.terminal.showSteps(status.steps, status.now_ms);
        self.terminal.add(context, status.log, status.log.len, @max(120, height - 56 - 4 - footer_height - 32));
        context.end();
        restyle(context, .{ .gap = 12 });

        var action: Action = .none;
        footerBegin(context);
        if (context.buttonVariant(terminal_glyph ++ "  Hide output", .ghost)) self.output_shown = false;
        spacer(context);
        if (context.buttonVariant("Cancel", .outline)) action = .cancel;
        footerEnd(context);
        return action;
    }

    /// What went wrong: the first compile error, if any, with a button opening it, over the end
    /// of the output; then Copy output, the close button and Try again.
    fn failedPage(self: *BuildProgress, context: *ui.Context, status: Status, options: Options, height: f32) Action {
        const arena = context.builder().allocator;
        if (!self.error_searched) {
            self.error_searched = true;
            self.first_error = findFirstError(self.gpa, status.log, self.project.dir) catch null;
        }
        // A build that ran and failed didn't build; anything before it couldn't even start.
        const in_build = if (status.stages.len > 0) switch (status.stages[status.stages.len - 1].stage) {
            .building, .exporting => true,
            else => false,
        } else false;
        const title = if (in_build)
            std.fmt.allocPrint(arena, "{s} didn't build", .{self.project.title}) catch "The build failed"
        else
            std.fmt.allocPrint(arena, "Couldn't {s} {s}", .{ self.project.verb.infinitive(), self.project.title }) catch "Something went wrong";

        context.begin(.column);
        self.header(context, .failed, title, status.detail, .none);
        var used: f32 = 64;
        if (self.first_error) |found| {
            used += 96;
            context.begin(.card);
            context.begin(.row);
            context.begin(.column);
            const where = context.builder().node(0, .{ .height = 18 }, .{ .custom = .{ .context = self.errorLocation(arena, found.where), .draw = drawMono } }, &.{}) catch null;
            if (where) |element| context.element(element);
            context.text(found.message);
            context.end();
            restyle(context, .{ .grow = 1, .gap = 2 });
            const open_label = std.fmt.allocPrint(arena, "Open in {s}", .{options.code_editor.label()}) catch "Open";
            if (context.buttonVariant(open_label, .outline)) {
                code_editor.openAt(self.gpa, options.code_editor, self.project.dir, found.path, found.line, found.column) catch |err| {
                    std.log.err("cannot open {s} in {s}: {t}", .{ found.path, options.code_editor.label(), err });
                    self.open_failed = true;
                };
            }
            context.end();
            restyle(context, .{ .direction = .row, .gap = 14, .align_items = .center });
            if (self.open_failed) {
                context.muted(std.fmt.allocPrint(arena, "{s} didn't start. Choose another code editor in Settings > Editor.", .{options.code_editor.label()}) catch "The code editor didn't start.");
                page_style.smallText(context, 12);
            }
            context.end();
            if (context.last_added) |card| {
                card.style.padding = .{ .left = 16, .right = 12, .top = 12, .bottom = 12 };
                card.style.max_width = null;
            }
        }
        self.terminal.showSteps(status.steps, status.now_ms);
        self.terminal.add(context, status.log, status.log.len, @max(100, height - used - footer_height - 48));
        context.end();
        restyle(context, .{ .gap = 14 });

        var action: Action = .none;
        footerBegin(context);
        if (context.buttonVariant(copy_glyph ++ "  Copy errors", .ghost)) {
            const problems = build_output.problems(self.gpa, status.log) catch status.log;
            defer if (problems.ptr != status.log.ptr) self.gpa.free(problems);
            terminal_view.copyToClipboard(problems);
        }
        spacer(context);
        if (context.buttonVariant(options.close_label, .outline)) action = .close;
        if (context.button("Try again")) action = .retry;
        footerEnd(context);
        return action;
    }

    /// The build is done: its stages, whether a new editor came of it, and Later and Reload.
    fn donePage(self: *BuildProgress, context: *ui.Context, status: Status, options: Options, height: f32) Action {
        if (self.output_shown) {
            const arena = context.builder().allocator;
            context.begin(.column);
            self.header(context, .compact, std.fmt.allocPrint(arena, "Built {s}", .{self.project.title}) catch "Built", doneLine(options.done), .{ .elapsed = elapsed(arena, status) });
            self.terminal.showSteps(status.steps, status.now_ms);
            self.terminal.add(context, status.log, status.log.len, @max(120, height - 56 - footer_height - 28));
            context.end();
            restyle(context, .{ .gap = 12 });
        } else {
            const arena = context.builder().allocator;
            context.begin(.column);
            self.header(context, .large, std.fmt.allocPrint(arena, "Built {s}", .{self.project.title}) catch "Built", doneLine(options.done), .none);
            stageList(context, status);
            context.end();
            restyle(context, .{ .gap = 24, .padding = .{ .top = 12, .left = 12, .right = 12 } });
        }

        var action: Action = .none;
        footerBegin(context);
        if (context.buttonVariant(if (self.output_shown) terminal_glyph ++ "  Hide output" else terminal_glyph ++ "  Show output", .ghost)) self.output_shown = !self.output_shown;
        spacer(context);
        switch (options.done) {
            .rebuilt => {
                if (context.buttonVariant("Later", .outline)) action = .close;
                if (context.button("Reload")) action = .reload;
            },
            .unchanged, .launching => if (context.button("Close")) {
                action = .close;
            },
        }
        footerEnd(context);
        return action;
    }

    /// The project's tile and what is happening to it, drawn as one element.
    fn header(self: *BuildProgress, context: *ui.Context, size: HeaderSize, title: []const u8, line: []const u8, right: HeaderRight) void {
        const arena = context.builder().allocator;
        const drawn = arena.create(Header) catch return;
        drawn.* = .{ .project = &self.project, .size = size, .title = title, .line = line, .mono = self.mono, .right = right };
        const tall: f32 = switch (size) {
            .large => 64,
            .compact => 44,
            .failed => 52,
        };
        const element = context.builder().node(0, .{ .width = context.contentWidth(), .height = tall }, .{ .custom = .{ .context = drawn, .draw = Header.draw } }, &.{}) catch return;
        element.accessibility = .{ .role = .heading, .label = title, .description = line };
        context.element(element);
    }

    /// The bar for the build's steps and, under it, the step under way and how many are done.
    fn stepProgress(self: *BuildProgress, context: *ui.Context, status: Status) void {
        const arena = context.builder().allocator;
        context.begin(.column);
        context.progress(stepFraction(status));
        restyle(context, .{ .height = 6 });
        const counts = arena.create(StepLine) catch return;
        counts.* = .{
            .step = if (status.build_step.len > 0) status.build_step else status.detail,
            .counts = if (status.steps_total > 0) std.fmt.allocPrint(arena, "{d} of {d} steps", .{ status.steps_done, status.steps_total }) catch "" else "",
            .mono = self.mono,
        };
        const element = context.builder().node(0, .{ .width = context.contentWidth() - stage_indent, .height = 18 }, .{ .custom = .{ .context = counts, .draw = StepLine.draw } }, &.{}) catch return;
        element.accessibility = .{ .role = .label, .label = counts.step, .description = counts.counts };
        context.element(element);
        context.end();
        restyle(context, .{ .gap = 8, .width = context.contentWidth() - stage_indent });
        indent(context);
    }

    /// The error's `path:line:column`, drawn in monospace in the theme's destructive colour.
    fn errorLocation(self: *BuildProgress, arena: std.mem.Allocator, where: []const u8) *const MonoText {
        const text = arena.create(MonoText) catch return &no_text;
        text.* = .{ .value = where, .mono = self.mono };
        return text;
    }

    fn forgetError(self: *BuildProgress) void {
        if (self.first_error) |found| {
            self.gpa.free(found.where);
            self.gpa.free(found.message);
            self.gpa.free(found.path);
        }
        self.first_error = null;
        self.error_searched = false;
        self.open_failed = false;
    }
};

/// The first `path:line:column: error: message` in `output`, its path made absolute against
/// `project_dir`; null when there is none. Owned by `gpa`.
fn findFirstError(gpa: std.mem.Allocator, output: []const u8, project_dir: []const u8) !?FirstError {
    var messages: std.ArrayList(build_output.Message) = .empty;
    defer messages.deinit(gpa);
    try build_output.parse(gpa, output, &messages);
    for (messages.items) |message| {
        if (message.level != .err) continue;
        const first_line = std.mem.sliceTo(output[message.start..message.end], '\n');
        const at = diagnostic.location(first_line) orelse continue;
        const marker = ": error: ";
        const text = if (std.mem.indexOf(u8, first_line, marker)) |i| first_line[i + marker.len ..] else first_line;
        const where = try std.fmt.allocPrint(gpa, "{s}:{d}:{d}", .{ at.path, at.line, at.column });
        errdefer gpa.free(where);
        const message_text = try gpa.dupe(u8, std.mem.trim(u8, text, " \r"));
        errdefer gpa.free(message_text);
        const path = if (std.fs.path.isAbsolute(at.path)) try gpa.dupe(u8, at.path) else try std.fs.path.join(gpa, &.{ project_dir, at.path });
        return .{ .where = where, .message = message_text, .path = path, .line = at.line, .column = at.column };
    }
    return null;
}

/// Each stage so far: a tick and how long it took, or a ring and how long it has run, or a cross
/// where it failed.
fn stageList(context: *ui.Context, status: Status) void {
    if (status.stages.len == 0) return;
    const arena = context.builder().allocator;
    const list = arena.create(StageList) catch return;
    list.* = .{ .status = status, .times = arena.alloc([]const u8, status.stages.len) catch return };
    for (status.stages, list.times) |stage, *time| time.* = duration(arena, (stage.ended_ms orelse status.now_ms) -| stage.started_ms);
    const height = @as(f32, @floatFromInt(status.stages.len)) * stage_row_height;
    const element = context.builder().node(0, .{ .width = context.contentWidth(), .height = height }, .{ .custom = .{ .context = list, .draw = StageList.draw } }, &.{}) catch return;
    element.accessibility = .{ .role = .group, .label = "Stages" };
    context.element(element);
}

/// How far the build's steps are: their count once known, else the whole job's.
fn stepFraction(status: Status) f32 {
    if (status.steps_total == 0) return status.fraction;
    return @as(f32, @floatFromInt(status.steps_done)) / @as(f32, @floatFromInt(status.steps_total));
}

/// How long the job has run, from its first stage.
fn elapsed(arena: std.mem.Allocator, status: Status) []const u8 {
    if (status.stages.len == 0) return "";
    const last = status.stages[status.stages.len - 1];
    return duration(arena, (last.ended_ms orelse status.now_ms) -| status.stages[0].started_ms);
}

/// `ms` as people read a short wait: "0.4s", "12s", "1:24".
fn duration(arena: std.mem.Allocator, ms: u64) []const u8 {
    if (ms < 10_000) return std.fmt.allocPrint(arena, "{d}.{d}s", .{ ms / 1000, ms % 1000 / 100 }) catch "";
    if (ms < 60_000) return std.fmt.allocPrint(arena, "{d}s", .{ms / 1000}) catch "";
    const seconds = ms / 1000;
    return std.fmt.allocPrint(arena, "{d}:{d:0>2}", .{ seconds / 60, seconds % 60 }) catch "";
}

fn doneLine(done: Done) []const u8 {
    return switch (done) {
        .rebuilt => "A new editor is ready. Reload to use it.",
        .unchanged, .launching => "Nothing changed.",
    };
}

/// Line the element just added up with the stages' labels.
fn indent(context: *ui.Context) void {
    const element = context.last_added orelse return;
    element.style.padding.left = stage_indent;
}
const stage_indent: f32 = 34;

fn spacer(context: *ui.Context) void {
    const element = context.builder().node(0, .{ .grow = 1 }, .none, &.{}) catch return;
    element.accessibility = .{ .role = .ignored };
    context.element(element);
}

fn footerBegin(context: *ui.Context) void {
    context.begin(.row);
}

fn footerEnd(context: *ui.Context) void {
    context.end();
    if (context.last_added) |footer| footer.style = .{ .direction = .row, .gap = 8, .align_items = .center, .width = context.contentWidth(), .height = footer_height, .padding = .{ .top = 8 } };
}

const HeaderSize = enum { large, compact, failed };
const HeaderRight = union(enum) { none, elapsed: []const u8 };

/// A header: the tile (with a cross on a failed build's), the title and a line under it.
const Header = struct {
    project: *const Project,
    size: HeaderSize,
    title: []const u8,
    line: []const u8,
    mono: *const ui.Font,
    right: HeaderRight,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Header = @ptrCast(@alignCast(context));
        const t = c.theme;
        const side: f32 = switch (self.size) {
            .large => 56,
            .compact => 40,
            .failed => 48,
        };
        const tile = ui.Rect{ .x = r.x, .y = r.y + (r.h - side) / 2, .w = side, .h = side };
        try project_tile.draw(c, tile, self.project.title, self.project.logo, side * 0.22, .normal);
        if (self.size == .failed) {
            const badge = ui.Rect{ .x = tile.x + side - 15, .y = tile.y + side - 15, .w = 20, .h = 20 };
            try c.roundRect(.{ .x = badge.x - 2, .y = badge.y - 2, .w = badge.w + 4, .h = badge.h + 4 }, t.background, 12);
            try c.roundRect(badge, t.destructive, 10);
            try c.textIn(badge, cross_glyph, 11, t.background, .center);
        }

        const text_x = tile.x + side + 16;
        const right_width: f32 = switch (self.right) {
            .none => 0,
            .elapsed => |value| c.font.measure(value, 12) + 8,
        };
        const text_w = @max(1, r.x + r.w - text_x - right_width);
        const title_size: f32 = switch (self.size) {
            .large => 20,
            .compact => 16,
            .failed => 18,
        };
        const line_size: f32 = if (self.size == .large) 12.5 else 13;
        const block = title_size + 6 + line_size;
        const top = r.y + (r.h - block) / 2 - 2;
        try c.textIn(.{ .x = text_x, .y = top, .w = text_w, .h = title_size + 4 }, self.title, title_size, t.foreground, .start);
        // A path in the large header is monospace, like the launcher's.
        const ui_font = c.font;
        if (self.size == .large and self.line.len > 0 and (self.line[0] == '/' or self.line[0] == '~')) c.font = self.mono;
        try c.textIn(.{ .x = text_x, .y = top + title_size + 6, .w = text_w, .h = line_size + 4 }, self.line, line_size, t.muted_foreground, .start);
        c.font = ui_font;
        switch (self.right) {
            .none => {},
            .elapsed => |value| {
                c.font = self.mono;
                try c.textIn(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, value, 12, t.muted_foreground, .end);
                c.font = ui_font;
            },
        }
    }
};

/// The stages as a checklist.
const StageList = struct {
    status: Status,
    times: [][]const u8,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const StageList = @ptrCast(@alignCast(context));
        const t = c.theme;
        const failed = self.status.stage == .failed;
        for (self.status.stages, self.times, 0..) |stage, time, i| {
            const y = r.y + @as(f32, @floatFromInt(i)) * stage_row_height;
            const mark = ui.Rect{ .x = r.x + 1, .y = y + (stage_row_height - 22) / 2, .w = 22, .h = 22 };
            const last = i + 1 == self.status.stages.len;
            const state: enum { done, running, failed } = if (stage.ended_ms == null) .running else if (last and failed) .failed else .done;
            switch (state) {
                .done => {
                    try c.roundRect(mark, t.muted, 11);
                    try c.textIn(mark, tick_glyph, 11, t.primary, .center);
                },
                .failed => {
                    try c.roundRect(mark, t.destructive, 11);
                    try c.textIn(mark, cross_glyph, 11, t.background, .center);
                },
                .running => try spinner(c, mark, self.status.now_ms),
            }
            const label = if (state == .done) stage.stage.doneLabel() else stage.stage.label();
            const label_rect = ui.Rect{ .x = r.x + stage_indent, .y = y, .w = r.w - stage_indent, .h = stage_row_height };
            try c.textIn(label_rect, label, t.text_size, if (state == .done) t.muted_foreground else t.foreground, .start);
            try c.textIn(label_rect, time, 12, t.muted_foreground, .end);
        }
    }
};

/// A ring with a turning arc in `r`, like the job it stands for.
fn spinner(c: *ui.Canvas, r: ui.Rect, time_ms: u64) !void {
    const t = c.theme;
    try c.roundRectStroke(r, t.border, r.w / 2, 2);
    const color = t.primary ++ [_]f32{1};
    const center = r.center();
    const radius = r.w / 2 - 1;
    const turn = @as(f32, @floatFromInt(time_ms % 1000)) / 1000 * 2 * std.math.pi;
    const sweep = 0.7 * std.math.pi;
    const segments = 12;
    for (0..segments) |i| {
        const a0 = turn + sweep * @as(f32, @floatFromInt(i)) / segments;
        const a1 = turn + sweep * @as(f32, @floatFromInt(i + 1)) / segments;
        const inner0 = point(center, radius - 1, a0);
        const outer0 = point(center, radius + 1, a0);
        const inner1 = point(center, radius - 1, a1);
        const outer1 = point(center, radius + 1, a1);
        try c.triangle(.{ inner0, outer0, outer1 }, .{ color, color, color });
        try c.triangle(.{ inner0, outer1, inner1 }, .{ color, color, color });
    }
}

fn point(center: ui.Vec2, radius: f32, angle: f32) [2]f32 {
    return .{ center.x + radius * @cos(angle), center.y + radius * @sin(angle) };
}

/// The step under way in monospace, and how many are done, on one line.
const StepLine = struct {
    step: []const u8,
    counts: []const u8,
    mono: *const ui.Font,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const StepLine = @ptrCast(@alignCast(context));
        const t = c.theme;
        const counts_w = c.font.measure(self.counts, 12.5) + 12;
        try c.textIn(r, self.counts, 12.5, t.muted_foreground, .end);
        const ui_font = c.font;
        c.font = self.mono;
        defer c.font = ui_font;
        try c.textIn(.{ .x = r.x, .y = r.y, .w = @max(1, r.w - counts_w), .h = r.h }, self.step, 12.5, t.muted_foreground, .start);
    }
};

/// A line of monospace text in the theme's destructive colour.
const MonoText = struct {
    value: []const u8,
    mono: ?*const ui.Font = null,
};
const no_text = MonoText{ .value = "" };

fn drawMono(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const self: *const MonoText = @ptrCast(@alignCast(context));
    const ui_font = c.font;
    if (self.mono) |mono| c.font = mono;
    defer c.font = ui_font;
    try c.textIn(r, self.value, 12.5, c.theme.destructive, .start);
}

test "a short wait reads in tenths, a long one in minutes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("0.4s", duration(arena.allocator(), 420));
    try std.testing.expectEqualStrings("12s", duration(arena.allocator(), 12_300));
    try std.testing.expectEqualStrings("1:24", duration(arena.allocator(), 84_000));
}

test "the first compile error is found, its path made absolute" {
    const gpa = std.testing.allocator;
    const output =
        \\install
        \\└─ compile exe space_editor Debug native 1 errors
        \\src/main.zig:42:17: error: expected ';' after statement
        \\    const speed = 4.0
        \\                ^
        \\
    ;
    const found = (try findFirstError(gpa, output, "/home/me/space")).?;
    defer {
        gpa.free(found.where);
        gpa.free(found.message);
        gpa.free(found.path);
    }
    try std.testing.expectEqualStrings("src/main.zig:42:17", found.where);
    try std.testing.expectEqualStrings("expected ';' after statement", found.message);
    try std.testing.expectEqual(@as(u32, 42), found.line);
    try std.testing.expect(std.mem.endsWith(u8, found.path, "main.zig"));
    try std.testing.expect(std.fs.path.isAbsolute(found.path));
}

test "output without a compile error has none" {
    try std.testing.expectEqual(@as(?FirstError, null), try findFirstError(std.testing.allocator, "error: the following command failed\n", "/home/me/space"));
}
