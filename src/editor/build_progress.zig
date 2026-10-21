//! A build's progress as the Build window and the project loading screen both show it: what it is
//! doing and how far along, over its output with each step's progress pinned under it.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const Status = @import("projects/job.zig").Status;
const TerminalView = @import("terminal_view.zig").TerminalView;

/// What the progress says once the job has ended.
pub const Endings = struct {
    /// The alert's title when the job failed; its detail is the job's.
    failed: []const u8,
    /// The line shown over a full bar when the job is done.
    done: []const u8 = "Done.",
};

pub const BuildProgress = struct {
    /// The job's output, with the build's steps pinned under it.
    terminal: TerminalView,

    /// Create the view, borrowing `mono` (the monospace face), which must outlive `deinit`. The
    /// view must stay at one address while frames refer to it.
    ///
    /// ```zig
    /// var progress = BuildProgress.init(gpa, mono);
    /// defer progress.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator, mono: *const ui.Font) BuildProgress {
        return .{ .terminal = .init(gpa, mono) };
    }

    /// Free the output's copy; the font is not the view's.
    pub fn deinit(self: *BuildProgress) void {
        self.terminal.deinit();
    }

    /// Handle `input` for its window, before the page does; returns whether the output used it
    /// (selecting, copying, scrolling, or opening a step).
    pub fn handle(self: *BuildProgress, input: ui.input.Event) bool {
        return self.terminal.handle(input);
    }

    /// Show `status` on `context`'s page: a failure as an alert, else the stage (or
    /// `endings.done`) over a progress bar and the step under way; then the output, `output_height`
    /// points tall. `status` is borrowed until the frame is drawn.
    ///
    /// ```zig
    /// progress.add(context, status, .{ .failed = "The build failed" }, 240);
    /// ```
    pub fn add(self: *BuildProgress, context: *ui.Context, status: Status, endings: Endings, output_height: f32) void {
        // What happened, or what is happening and how far along it is.
        switch (status.stage) {
            .failed => context.alert(endings.failed, status.detail, true),
            .done => {
                context.label("{s}", .{endings.done});
                context.progress(1);
            },
            else => {
                context.label("{s}...", .{status.stage.label()});
                context.progress(status.fraction);
                context.muted(if (status.detail.len > 0) status.detail else " ");
            },
        }

        // The output so far; it only grows, so its length says when it changed.
        self.terminal.showSteps(status.steps, sdl3.timer.getMillisecondsSinceInit());
        self.terminal.add(context, status.log, status.log.len, output_height);
    }
};
