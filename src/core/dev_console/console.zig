//! The dev console's state: the lines typed into it, run as commands, and what they said.
const std = @import("std");
const ui = @import("weeoui");
const App = @import("../app.zig").App;
const Key = @import("../input/input.zig").Key;
const builtin_commands = @import("builtin_commands.zig");
const completion = @import("completion.zig");
const prompt_zig = @import("prompt.zig");

const commands = @import("commands.zig");
const Call = commands.Call;
const Commands = commands.Commands;
const Prompt = prompt_zig.Prompt;

const log = std.log.scoped(.console);

/// The most lines of output kept; older ones are forgotten.
const max_lines = 500;

/// A line of the console's output.
pub const Line = struct {
    kind: Kind,
    text: []u8,

    pub const Kind = enum {
        /// A line typed, echoed.
        input,
        /// What it said.
        output,
        /// What went wrong.
        failure,
    };
};

pub const DevConsole = struct {
    /// The key that shows and hides it over the game; null for none (the game opens it itself).
    toggle_key: ?Key = .grave,
    /// Whether it can show over the game at all: the project's `.dev_console` (`setEnabled`).
    enabled: bool = true,
    showing: bool = false,
    /// What the last `sync` saw, so gameplay input is dropped once per opening and closing.
    synced: bool = false,
    /// Also log each line of output (the editor's Console then shows it).
    log_output: bool = false,
    lines: std.ArrayList(Line) = .empty,
    /// Bumped whenever `lines` changes, for views that keep a copy.
    revision: u64 = 0,
    /// How many lines the overlay is scrolled back from the newest.
    scrolled_back: usize = 0,
    prompt: Prompt = .{},

    /// Free the output and the history. `gpa` is the one lines were run with
    /// (`app.world.allocator`).
    pub fn deinit(self: *DevConsole, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.lines.deinit(gpa);
        self.prompt.deinit(gpa);
    }

    /// Show it over the game, its prompt taking the keyboard. Takes effect at the next event or frame.
    ///
    /// ```zig
    /// if (cheats_allowed) app.dev_console.open();
    /// ```
    pub fn open(self: *DevConsole) void {
        self.showing = self.enabled;
    }

    pub fn close(self: *DevConsole) void {
        self.showing = false;
    }

    pub fn toggle(self: *DevConsole) void {
        self.showing = self.enabled and !self.showing;
    }

    /// Let it show over the game, or not (hiding it if it shows): what the project's
    /// `.dev_console` says. Lines typed elsewhere (the editor's Console panel) still run.
    pub fn setEnabled(self: *DevConsole, enabled: bool) void {
        self.enabled = enabled;
        if (!enabled) self.showing = false;
    }

    pub fn isOpen(self: *const DevConsole) bool {
        return self.showing;
    }

    /// Run `line` as the user typed it, echoing it and keeping what it says: a command when its
    /// first word names one (Eggy's first, then `game`'s). Failures are shown,
    /// never returned. Host-only, on the main thread.
    ///
    /// ```zig
    /// app.dev_console.submit(app, commands, "timescale 0.5");
    /// ```
    pub fn submit(self: *DevConsole, app: *App, game: Commands, line: []const u8) void {
        const gpa = app.world.allocator;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) return;
        self.scrolled_back = 0;
        self.say(gpa, .input, trimmed);

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const ran = self.runCommand(app, game, trimmed, &out.writer, arena.allocator()) catch |err| {
            self.say(gpa, .failure, @errorName(err));
            return;
        };
        const said = ran orelse no_command: {
            out.writer.print("{s}: no such command (type help)\n", .{trimmed[0 .. std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len]}) catch {};
            break :no_command .failure;
        };
        self.sayAll(gpa, said, out.written());
    }

    /// Run `line` if its first word names a command, returning what kind of output it wrote to
    /// `out`; null (having run nothing) if it doesn't.
    fn runCommand(self: *DevConsole, app: *App, game: Commands, line: []const u8, out: *std.Io.Writer, arena: std.mem.Allocator) !?Line.Kind {
        const words = try commands.split(arena, line);
        if (words.len == 0) return null;
        var call = Call{ .line = line, .args = words[1..], .out = out, .arena = arena };
        inline for (@typeInfo(builtin_commands.Builtin).@"enum".field_names) |name| if (std.mem.eql(u8, words[0], name)) {
            switch (@field(builtin_commands.Builtin, name)) {
                .clear => self.clear(app.world.allocator),
                else => |builtin| try builtin_commands.run(builtin, app, &call, game.list),
            }
            return .output;
        };
        for (game.list, 0..) |command, index| if (std.mem.eql(u8, command.name, words[0])) {
            if (game.run(game.context, index, app, &call)) return .output;
            call.print("{s} failed (see the log)", .{command.name});
            return .failure;
        };
        return null;
    }

    /// What the word at `cursor` in `line` could become (see `completion.complete`), in `arena`.
    pub fn complete(_: *const DevConsole, app: *App, game: Commands, arena: std.mem.Allocator, line: []const u8, cursor: usize) !completion.Completion {
        var names: std.ArrayList([]const u8) = .empty;
        for (builtin_commands.list) |command| try names.append(arena, command.name);
        for (game.list) |command| try names.append(arena, command.name);
        return completion.complete(arena, line, cursor, .{
            .commands = names.items,
            .entities = try builtin_commands.entityNames(arena, app),
            .fields = try builtin_commands.fieldPaths(arena, app.scene_access),
        });
    }

    /// Declare the prompt in `context` for this frame, completing from `app` and `game` and
    /// running the line Enter gives. It takes the keyboard when the console has just opened.
    /// Host-only, between the context's frame start and its render.
    ///
    /// ```zig
    /// app.dev_console.buildPrompt(app, commands, &layer.context, .{});
    /// ```
    pub fn buildPrompt(self: *DevConsole, app: *App, game: Commands, context: *ui.Context, options: prompt_zig.Options) void {
        const Through = struct {
            console: *DevConsole,
            app: *App,
            game: Commands,
            fn complete(through_ptr: *anyopaque, arena: std.mem.Allocator, line: []const u8, cursor: usize) anyerror!completion.Completion {
                const through: *@This() = @ptrCast(@alignCast(through_ptr));
                return through.console.complete(through.app, through.game, arena, line, cursor);
            }
        };
        var through = Through{ .console = self, .app = app, .game = game };
        const line = self.prompt.build(app.world.allocator, context, .{ .context = &through, .complete = Through.complete }, options) orelse return;
        self.submit(app, game, line);
    }

    /// Forget the output.
    pub fn clear(self: *DevConsole, gpa: std.mem.Allocator) void {
        for (self.lines.items) |line| gpa.free(line.text);
        self.lines.clearRetainingCapacity();
        self.scrolled_back = 0;
        self.revision +%= 1;
    }

    /// Keep each line of `text` as output of `kind`.
    fn sayAll(self: *DevConsole, gpa: std.mem.Allocator, kind: Line.Kind, text: []const u8) void {
        var rows = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        if (std.mem.trim(u8, text, " \n").len == 0) return;
        while (rows.next()) |row| self.say(gpa, kind, row);
    }

    /// Keep `text` (one line) as output of `kind`, and log it if asked to.
    fn say(self: *DevConsole, gpa: std.mem.Allocator, kind: Line.Kind, text: []const u8) void {
        if (self.log_output) switch (kind) {
            .input => log.info("> {s}", .{text}),
            .output => log.info("{s}", .{text}),
            .failure => log.err("{s}", .{text}),
        };
        const owned = gpa.dupe(u8, text) catch return;
        self.lines.append(gpa, .{ .kind = kind, .text = owned }) catch return gpa.free(owned);
        if (self.lines.items.len > max_lines) gpa.free(self.lines.orderedRemove(0).text);
        self.revision +%= 1;
    }
};

test "a line naming no command says so" {
    const gpa = std.testing.allocator;
    var app: App = undefined;
    app.world.allocator = gpa;
    var console = DevConsole{};
    defer console.deinit(gpa);
    console.submit(&app, .none, "fly faster");
    try std.testing.expectEqual(@as(usize, 2), console.lines.items.len);
    try std.testing.expectEqual(Line.Kind.failure, console.lines.items[1].kind);
    try std.testing.expectEqualStrings("fly: no such command (type help)", console.lines.items[1].text);
}
