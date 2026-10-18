//! The New Project wizard's steps: name the project, choose where it goes, then review and
//! create it. `build` draws the current step each frame and says when to create or cancel.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const template = @import("template.zig");

pub const Step = enum { name, location, review };

/// What the wizard's buttons asked for this frame.
pub const Action = union(enum) {
    none,
    cancel,
    /// Create the project in `dir` (absolute).
    create: struct { title: []const u8, name: []const u8, dir: []const u8 },
};

pub const Wizard = struct {
    step: Step = .name,
    title: ui.TextEdit(64),
    name: ui.TextEdit(template.max_name_len),
    /// The package name follows the title until someone edits it.
    name_edited: bool = false,
    derived: [template.max_name_len]u8 = undefined,
    derived_len: usize = 0,
    /// The folder the project's folder goes in.
    location: ui.TextEdit(1024),
    /// Why the wizard won't go on, shown under the fields.
    problem: ?[]const u8 = null,
    /// A folder the system's picker chose; it may call back from another thread, so the next
    /// frame takes it from here.
    picked: std.atomic.Value(?[*:0]u8) = .init(null),
    /// The project's folder, built when the wizard leaves the location step.
    dir_buffer: [1100]u8 = undefined,
    dir: []const u8 = "",

    /// A wizard suggesting a project in `default_location`.
    /// Desktop editor only: copies/truncates the location to 1024 bytes and initializes fixed
    /// edit buffers. Keep the wizard at a stable address once a folder picker can reference it.
    ///
    /// ```zig
    /// var wizard = Wizard.init("/home/you/EggyProjects");
    /// defer wizard.deinit();
    /// ```
    pub fn init(default_location: []const u8) Wizard {
        var self = Wizard{
            .title = ui.TextEdit(64).init("My Game") catch unreachable,
            .name = ui.TextEdit(template.max_name_len).init("") catch unreachable,
            .location = ui.TextEdit(1024).init("") catch unreachable,
        };
        self.location.set(default_location[0..@min(default_location.len, 1024)]) catch {};
        return self;
    }

    /// Free any picked folder awaiting consumption by this desktop editor wizard.
    /// Ensure no asynchronous picker callback can still access the wizard before destroying
    /// its enclosing storage; this does not cancel an outstanding system picker.
    ///
    /// ```zig
    /// wizard.deinit(); // Existing Wizard after picker callbacks have finished.
    /// ```
    pub fn deinit(self: *Wizard) void {
        if (self.picked.swap(null, .acq_rel)) |path| std.heap.c_allocator.free(std.mem.span(path));
    }

    /// Draw the current step into `context`; `window` parents the folder picker.
    /// Desktop editor only: call during UI construction; may start an asynchronous folder
    /// picker referencing this stable wizard. A create action borrows title/name/directory
    /// buffers until further edits/destruction; copy them before transitioning the flow.
    /// This validates choices but does not create project files.
    ///
    /// ```zig
    /// const action = wizard.build(context, app.window.window);
    /// // Existing Wizard, building UI context and editor App pointer.
    /// ```
    pub fn build(self: *Wizard, context: *ui.Context, window: sdl3.video.Window) Action {
        self.followTitle();
        if (self.picked.swap(null, .acq_rel)) |path| {
            const chosen = std.mem.span(path);
            self.location.set(chosen[0..@min(chosen.len, 1024)]) catch {};
            std.heap.c_allocator.free(chosen);
        }

        context.heading(2, "New Project");
        context.muted(switch (self.step) {
            .name => "Step 1 of 3: name your project.",
            .location => "Step 2 of 3: choose where it goes.",
            .review => "Step 3 of 3: check, then create it.",
        });
        context.separator();
        switch (self.step) {
            .name => {
                context.label("Title", .{});
                _ = context.textInput("Title", &self.title, "My Game");
                context.muted("What players and the editor call it. Any text.");
                context.label("Package name", .{});
                _ = context.textInput("Package name", &self.name, "my_game");
                context.muted("The Zig package and executable name: lower case, digits and _.");
            },
            .location => {
                context.label("Location", .{});
                _ = context.textInput("Location", &self.location, "/home/you/EggyProjects");
                if (context.button("Browse...")) {
                    sdl3.dialog.showOpenFolder(Wizard, pickedFolder, self, window, null, false);
                }
                context.label("The project goes in {s}{c}{s}", .{ self.location.text(), std.fs.path.sep, self.name.text() });
            },
            .review => {
                context.label("Title: {s}", .{self.title.text()});
                context.label("Package: {s}", .{self.name.text()});
                context.label("Folder: {s}", .{self.dir});
                context.label("Eggy: the version bundled with this editor", .{});
                context.muted("The first build compiles Eggy and fetches its dependencies, which takes a few minutes. Later projects reuse that build.");
            },
        }
        if (self.problem) |problem| context.alert("Can't continue", problem, true);

        // Back, then Next or Create; Cancel on every step.
        context.begin(.row);
        defer context.end();
        if (context.buttonVariant("Cancel", .ghost)) return .cancel;
        if (self.step != .name and context.buttonVariant("Back", .outline)) {
            self.problem = null;
            self.step = @enumFromInt(@intFromEnum(self.step) - 1);
        }
        switch (self.step) {
            .name, .location => if (context.button("Next")) self.next(),
            .review => if (context.button("Create")) return .{ .create = .{ .title = self.title.text(), .name = self.name.text(), .dir = self.dir } },
        }
        return .none;
    }

    /// Move on if this step's fields are good, else say what's wrong.
    fn next(self: *Wizard) void {
        self.problem = self.check();
        if (self.problem == null) self.step = @enumFromInt(@intFromEnum(self.step) + 1);
    }

    fn check(self: *Wizard) ?[]const u8 {
        switch (self.step) {
            .name => {
                if (std.mem.trim(u8, self.title.text(), " ").len == 0) return "Give the project a title.";
                template.validateName(self.name.text()) catch |err| return switch (err) {
                    error.EmptyName => "Give the project a package name.",
                    error.NameTooLong => "The package name can be at most 32 characters.",
                    error.NameNotIdentifier => "The package name must start with a letter and hold only letters, digits and _, and not be a Zig keyword.",
                };
            },
            .location => {
                const location = self.location.text();
                if (!std.fs.path.isAbsolute(location)) return "Choose a full path, such as /home/you/EggyProjects.";
                self.dir = std.fmt.bufPrint(&self.dir_buffer, "{s}{c}{s}", .{ std.mem.trimEnd(u8, location, "/\\"), std.fs.path.sep, self.name.text() }) catch return "That path is too long.";
                if (folderInUse(self.dir)) return "There's already something in that folder. Choose another name or location.";
            },
            .review => {},
        }
        return null;
    }

    /// Keep the package name derived from the title until someone types their own.
    fn followTitle(self: *Wizard) void {
        if (!self.name_edited and !std.mem.eql(u8, self.name.text(), self.derived[0..self.derived_len])) self.name_edited = true;
        if (self.name_edited) return;
        const derived = template.packageName(&self.derived, self.title.text());
        self.derived_len = derived.len;
        self.name.set(derived) catch {};
    }

    fn pickedFolder(self: ?*Wizard, files: ?[]const [*:0]const u8, _: ?usize, failed: bool) void {
        const chosen = files orelse return;
        if (failed or chosen.len == 0) return;
        const copy = std.heap.c_allocator.dupeZ(u8, std.mem.span(chosen[0])) catch return;
        if (self.?.picked.swap(copy.ptr, .acq_rel)) |old| std.heap.c_allocator.free(std.mem.span(old));
    }
};

/// Whether `dir` exists and holds anything.
fn folderInUse(dir: []const u8) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var opened = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |err| return err != error.FileNotFound;
    defer opened.close(io);
    var entries = opened.iterate();
    return (entries.next(io) catch return true) != null;
}

test "the package name follows the title until it is edited" {
    var wizard = Wizard.init("/tmp");
    defer wizard.deinit();
    try wizard.title.set("Space Game");
    wizard.followTitle();
    try std.testing.expectEqualStrings("space_game", wizard.name.text());
    try wizard.name.set("rocket");
    wizard.followTitle();
    try wizard.title.set("Other");
    wizard.followTitle();
    try std.testing.expectEqualStrings("rocket", wizard.name.text());
}

test "the wizard won't leave a step until its fields are good" {
    var wizard = Wizard.init("relative/path");
    defer wizard.deinit();
    try wizard.name.set("2d");
    wizard.name_edited = true;
    wizard.next();
    try std.testing.expectEqual(Step.name, wizard.step);
    try wizard.name.set("space_game");
    wizard.next();
    try std.testing.expectEqual(Step.location, wizard.step);
    wizard.next();
    try std.testing.expect(wizard.problem != null); // not an absolute path
    try wizard.location.set("/nonexistent-eggy-test-location");
    wizard.next();
    try std.testing.expectEqual(Step.review, wizard.step);
    try std.testing.expectEqualStrings("/nonexistent-eggy-test-location/space_game", wizard.dir);
}
