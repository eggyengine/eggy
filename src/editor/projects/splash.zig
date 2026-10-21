//! The loading screen while a project is made or opened, and built: what is happening and how
//! far along it is (`build_progress.zig`, as the Build window shows it), or, if it failed, why.
const std = @import("std");
const ui = @import("eggy").ui;
const Status = @import("job.zig").Status;
const terminal_view = @import("../terminal_view.zig");
const BuildProgress = @import("../build_progress.zig").BuildProgress;

/// What the screen's buttons asked for this frame.
pub const Action = enum { none, close, cancel };

pub const Splash = struct {
    /// The heading ("Creating ...", "Opening ..."), kept here since the page reads it after
    /// `build` returns.
    heading_buffer: [96]u8 = undefined,
    heading_len: usize = 0,
    /// The egg, drawn from the window icon.
    egg: ?ui.Image,
    progress: BuildProgress,

    /// Create an editor loading page, copying up to 96 heading bytes and borrowing font/image.
    /// The owner calls `deinit` after UI use ends. The monospace font must outlive it.
    ///
    /// ```zig
    /// // Given allocator gpa and a live monospace UI font:
    /// var splash = Splash.init(gpa, mono, "Opening project", null);
    /// defer splash.deinit(gpa);
    /// ```
    pub fn init(gpa: std.mem.Allocator, mono: *const ui.Font, heading: []const u8, egg: ?ui.Image) Splash {
        var self = Splash{ .egg = egg, .progress = .init(gpa, mono) };
        self.heading_len = @min(heading.len, self.heading_buffer.len);
        @memcpy(self.heading_buffer[0..self.heading_len], heading[0..self.heading_len]);
        return self;
    }

    /// Free the progress view and the egg; `gpa` is the egg's allocator.
    pub fn deinit(self: *Splash, gpa: std.mem.Allocator) void {
        self.progress.deinit();
        if (self.egg) |*egg| egg.deinit(gpa);
    }

    /// Build one editor loading frame from a job status snapshot; return close/cancel intent.
    /// Borrows `status.detail`/`log` for the UI frame, so keep their arena/job storage alive
    /// through rendering. Does not cancel the job; Copy all writes the system clipboard.
    ///
    /// ```zig
    /// const action = splash.build(context, status); // Building UI context and live job Status.
    /// ```
    pub fn build(self: *Splash, context: *ui.Context, status: Status) Action {
        if (self.egg) |*egg| context.image(egg, 56);
        context.heading(2, self.heading_buffer[0..self.heading_len]);

        // The output takes the screen's height less the egg, heading, status lines and buttons.
        self.progress.add(context, status, .{ .failed = "Couldn't open the project" }, @max(150, context.viewport.h - 290));

        context.begin(.row);
        defer context.end();
        if (context.buttonVariant("Copy all", .ghost)) terminal_view.copyToClipboard(status.log);
        if (status.stage == .failed) return if (context.button("Close")) .close else .none;
        return if (context.buttonVariant("Cancel", .outline)) .cancel else .none;
    }
};
