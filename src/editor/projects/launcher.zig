//! The window Eggy's own editor opens with when it has no project: a rail with Eggy's egg and the
//! New Project and Open Project buttons beside the projects opened lately (`recent.zig`), newest
//! first, each with its logo, one click from opening.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const ToolWindow = @import("../tool_window.zig").ToolWindow;
const page_style = @import("../page_style.zig");
const help_menu = @import("../help_menu.zig");
const recent = @import("recent.zig");
const project_tile = @import("project_tile.zig");
const engine = @import("engine.zig");
const job = @import("job.zig");
const PickedPaths = @import("../picked_paths.zig").PickedPaths;

/// What the launcher asked for this frame.
pub const Action = union(enum) {
    none,
    new_project,
    /// Open the project in this folder (absolute); it lives until the next `update`.
    open: []const u8,
};

/// A recent project as the list shows it.
const Shown = struct {
    dir: []const u8,
    /// From its `eggy.zon`, or the folder's name when that can't be read.
    title: []const u8,
    opened_s: i64,
    /// Whether its folder is still there; a missing one can't be opened.
    found: bool,
    /// Its `.icon`, packed into the font's atlas; null draws its initial on a tile instead.
    logo: ?ui.Glyph = null,
    /// The version of Eggy it builds against, when that can be told.
    eggy_version: ?[]const u8 = null,
    /// The Eggy codebase it is linked to (File > Link Developer Eggy), absolute.
    linked: ?[]const u8 = null,
};

/// The rail's width from the window's left edge, in points.
const rail_width = 248;
const row_height = 56;
const tile_size = 40;
const path_size = 12;
/// Nerd Font glyphs, which the editor's font draws from its symbols face.
const plus_glyph = "\u{f067}";
const folder_glyph = "\u{f07c}";
const search_glyph = "\u{f002}";
const link_glyph = "\u{f0c1}";
const remove_glyph = "\u{f00d}";

pub const Launcher = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    /// The editor's UI font, whose atlas holds the logos, and its monospace companion for paths.
    font: *ui.Font,
    mono: *const ui.Font,
    egg: ?ui.Image,
    /// Holds `shown` and the folder an `open` action hands out.
    arena: std.heap.ArenaAllocator,
    shown: []Shown = &.{},
    /// Eggy's data folder, where the list is kept.
    data_folder: []u8,
    /// Where packaged engines are unpacked, to tell a linked project from one using them.
    engines_dir: ?[]u8 = null,
    /// Whether this Eggy was built from a git checkout that is on this machine.
    developer_build: bool = false,
    search: ui.TextEdit(128) = ui.TextEdit(128).init("") catch unreachable,
    scroll: ui.Layout.ScrollState = .{},
    /// A folder Open Project's picker chose; it may call back from another thread, so the next
    /// frame takes it from here.
    picked: PickedPaths = .{},

    /// Open the launcher's window, reading the list from `data_folder` (copied) and each listed
    /// project's title and logo. The result is on the heap, since the folder picker keeps a
    /// pointer to it. Borrows `graphics`, `font` and `mono` until `close`; window and allocation
    /// errors propagate.
    ///
    /// ```zig
    /// const launcher = try Launcher.open(gpa, graphics, font, mono, preference_folders.global);
    /// defer launcher.close(graphics);
    /// ```
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, mono: *const ui.Font, data_folder: []const u8) !*Launcher {
        const self = try gpa.create(Launcher);
        errdefer gpa.destroy(self);
        const folder = try gpa.dupe(u8, data_folder);
        errdefer gpa.free(folder);
        self.* = .{
            .gpa = gpa,
            .window = try ToolWindow.open(gpa, graphics, font, "Eggy", .{ 880, 560 }, .{ .resizable = true }),
            .font = font,
            .mono = mono,
            .egg = ui.Image.load(gpa, font, @embedFile("editor_icon")) catch null,
            .arena = .init(gpa),
            .data_folder = folder,
        };
        if (job.editorFolders(gpa)) |folders| {
            gpa.free(folders.resources_dir);
            self.engines_dir = folders.engines_dir;
        } else |err| std.log.warn("cannot find Eggy's engines folder: {t}", .{err});
        self.developer_build = isCheckout(@import("build_options").source_dir);
        self.load();
        return self;
    }

    /// Close the window and free the launcher. Ensure the folder picker has finished first.
    ///
    /// ```zig
    /// launcher.close(graphics); // `launcher` is invalid afterward.
    /// ```
    pub fn close(self: *Launcher, graphics: *eggy.Graphics) void {
        self.picked.deinit();
        if (self.egg) |*egg| egg.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.free(self.data_folder);
        if (self.engines_dir) |dir| self.gpa.free(dir);
        self.window.close(graphics);
        self.gpa.destroy(self);
    }

    /// Whether `curr_event` asks to close the launcher, which quits Eggy.
    pub fn closeRequested(self: *const Launcher, curr_event: sdl3.events.Event) bool {
        return curr_event == .window_close_requested and self.window.owns(curr_event);
    }

    /// Feed `curr_event` to the launcher if it is for its window; returns whether it was.
    pub fn handle(self: *Launcher, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        self.window.handle(curr_event);
        return true;
    }

    /// Draw a frame, styled like `style` (the editor's own UI), and say what was asked for.
    /// Rendering errors propagate.
    ///
    /// ```zig
    /// switch (try launcher.update(graphics, style)) {
    ///     .none => {},
    ///     .new_project => {}, // open the wizard
    ///     .open => |dir| {}, // open the project in `dir`
    /// }
    /// ```
    pub fn update(self: *Launcher, graphics: *eggy.Graphics, style: *const ui.Context) !Action {
        if (self.picked.take()) |dir| {
            defer PickedPaths.free(dir);
            return .{ .open = try self.arena.allocator().dupe(u8, dir) };
        }
        var page = Page{ .launcher = self, .now_s = now() };
        try self.window.present(graphics, style, &page);
        switch (page.chosen) {
            .none => {},
            .new_project => return .new_project,
            .open => |dir| return .{ .open = dir },
            .browse => self.picked.showFolder(self.window.popout.window.window, null),
            .forget => |index| self.forget(index),
            .url => |url| sdl3.openURL(url) catch |err| std.log.err("cannot open {s}: {t}", .{ url, err }),
        }
        return .none;
    }

    /// Read the list, with each project's title, logo and whether its folder is still there.
    fn load(self: *Launcher) void {
        const arena = self.arena.allocator();
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const entries = recent.load(arena, io, self.data_folder);
        const shown = arena.alloc(Shown, entries.len) catch return;
        for (shown, entries) |*row, entry| row.* = self.describe(arena, io, entry);
        self.shown = shown;
    }

    /// `entry` with its project's title and logo, read from its `eggy.zon`.
    fn describe(self: *Launcher, arena: std.mem.Allocator, io: std.Io, entry: recent.Entry) Shown {
        var shown = Shown{ .dir = entry.dir, .title = std.fs.path.basename(entry.dir), .opened_s = entry.opened_s, .found = false };
        var dir = std.Io.Dir.cwd().openDir(io, entry.dir, .{}) catch return shown;
        defer dir.close(io);
        shown.found = true;
        // Which Eggy it builds with, and whether that is a codebase being developed.
        shown.eggy_version = engine.projectVersion(arena, io, entry.dir) catch null;
        if (self.engines_dir) |engines| if (engine.projectEngine(arena, io, entry.dir, engines)) |used| switch (used) {
            .linked => |codebase| shown.linked = codebase,
            .packaged, .fetched => {},
        } else |_| {};
        const config = eggy.project.load(arena, io, dir) catch return shown;
        shown.title = config.title;
        shown.logo = project_tile.loadLogo(self.gpa, self.font, entry.dir, config.icon orelse return shown);
        return shown;
    }

    /// Take the project at `index` in `shown` off the list.
    fn forget(self: *Launcher, index: usize) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        recent.forget(self.gpa, threaded.io(), self.data_folder, self.shown[index].dir);
        std.mem.copyForwards(Shown, self.shown[index..], self.shown[index + 1 ..]);
        self.shown.len -= 1;
    }
};

/// One frame of the launcher's page and what was clicked in it.
const Page = struct {
    launcher: *Launcher,
    now_s: i64,
    chosen: union(enum) { none, new_project, browse, open: []const u8, forget: usize, url: [:0]const u8 } = .none,

    /// ToolWindow callback: the rail on the left, the projects on the right, filling the window.
    pub fn build(page: *Page, context: *ui.Context) void {
        const height = page_style.pageHeight(context);
        context.begin(.row);
        page.buildRail(context, height);
        page.buildProjects(context, height);
        context.end();
        page_style.restyle(context, .{ .height = height, .gap = 0, .align_items = .start });
    }

    /// Eggy's egg, name and version at the top; the project buttons and links at the bottom.
    fn buildRail(page: *Page, context: *ui.Context, height: f32) void {
        const inset = context.pagePadding();
        const inner_width = rail_width - inset - 24;
        context.begin(.column);
        context.begin(.column);
        if (page.launcher.egg) |*egg| context.image(egg, 80);
        context.heading(1, "Eggy");
        // A launcher built from a checkout on this machine says so with the link projects get.
        const version = @import("build_options").version;
        context.muted(if (page.launcher.developer_build) "Version " ++ version ++ "  " ++ link_glyph else "Version " ++ version);
        if (page.launcher.developer_build) if (context.last_added) |line| {
            line.accessibility = .{ .role = .label, .label = "Version " ++ version ++ ", built from the Eggy codebase at " ++ @import("build_options").source_dir };
        };
        context.end();
        page_style.restyle(context, .{ .gap = 6 });

        context.begin(.column);
        if (context.button(plus_glyph ++ "  New Project")) page.chosen = .new_project;
        page_style.restyle(context, .{ .width = inner_width, .height = 36 });
        if (context.buttonVariant(folder_glyph ++ "  Open Project...", .secondary)) page.chosen = .browse;
        page_style.restyle(context, .{ .width = inner_width, .height = 36 });
        context.begin(.row);
        if (context.buttonVariant("Documentation", .link)) page.chosen = .{ .url = help_menu.documentation_url };
        if (context.buttonVariant("Source", .link)) page.chosen = .{ .url = "https://git.tirbo.fish/eggy/eggy" };
        context.end();
        page_style.restyle(context, .{ .gap = 16 });
        context.end();
        page_style.restyle(context, .{ .gap = 10 });
        context.end();

        // The rail's panel reaches past the page's padding to the window's edges.
        const rail = context.last_added orelse return;
        rail.style = .{ .width = rail_width - inset, .height = height, .justify = .space_between, .padding = .{ .top = 16, .bottom = 4 } };
        page_style.railBackdrop(context);
    }

    /// The search field over the list, or what to do while there is nothing to list.
    fn buildProjects(page: *Page, context: *ui.Context, height: f32) void {
        const launcher = page.launcher;
        const width = context.viewport.w - context.pagePadding() - rail_width - 20;
        context.begin(.column);
        defer {
            context.end();
            if (context.last_added) |column| column.style = .{ .width = width + 20, .height = height, .gap = 10, .padding = .{ .left = 20 }, .justify = if (launcher.shown.len == 0) .center else .start };
        }
        if (launcher.shown.len == 0) return buildEmpty(context, width);

        _ = context.textInput("Search projects", &launcher.search, search_glyph ++ "  Search projects");
        page_style.restyle(context, .{ .width = width });
        const query = std.mem.trim(u8, launcher.search.text(), " ");
        context.beginScroll(&launcher.scroll, @max(1, height - 46));
        var listed: usize = 0;
        for (launcher.shown, 0..) |*row, index| if (matches(row.*, query)) {
            listed += 1;
            page.buildRow(context, row, index, width - 6);
        };
        if (listed == 0) context.muted(std.fmt.allocPrint(context.builder().allocator, "No project's title or folder has \"{s}\" in it.", .{query}) catch "");
        context.end();
    }

    /// A project: its logo or initial, title and folder, and when it was opened, with a button that
    /// takes it off the list (its folder stays as it is). Clicking a found one opens it; a
    /// missing one says so.
    fn buildRow(page: *Page, context: *ui.Context, shown: *const Shown, index: usize, width: f32) void {
        const arena = context.builder().allocator;
        const b = context.builder();
        const id = if (shown.found) context.idFor(std.fmt.allocPrint(arena, "##project {s}", .{shown.dir}) catch shown.dir) else 0;
        if (id != 0 and context.activated(id)) page.chosen = .{ .open = shown.dir };

        const row = arena.create(Row) catch return;
        row.* = .{ .shown = shown, .id = id, .mono = page.launcher.mono, .when = if (shown.found) ago(arena, page.now_s, shown.opened_s) else "Folder missing", .path = "", .version_label = if (shown.eggy_version) |version| std.fmt.allocPrint(arena, "Eggy {s}", .{version}) catch "" else "" };
        // The folder, home shortened to ~, cut to fit beside the time.
        const right_width = page.launcher.font.measure(row.when, path_size) + remove_width;
        row.path = page_style.fitText(arena, page.launcher.mono, project_tile.homeRelative(arena, shown.dir), path_size, width - text_left - right_width - 36);

        // Checked after the row's own click, so removing a project doesn't also open it.
        const remove_id = context.idFor(std.fmt.allocPrint(arena, "##remove {s}", .{shown.dir}) catch shown.dir);
        if (context.activated(remove_id)) page.chosen = .{ .forget = index };
        const remove_label = std.fmt.allocPrint(arena, "Remove {s} from the list", .{shown.title}) catch "Remove from the list";
        const remove = page_style.iconButtonNode(b, remove_id, remove_glyph, remove_label, false) catch return;
        const children = arena.dupe(*ui.Layout.Element, &.{remove}) catch return;
        const element = b.node(id, .{ .width = width, .height = row_height, .direction = .row, .justify = .end, .align_items = .center, .padding = .{ .right = 6 } }, .{ .custom = .{ .context = row, .draw = Row.draw } }, children) catch return;
        if (id != 0) {
            element.cursor = .pointer;
            element.accessibility = .{ .role = .button, .label = std.fmt.allocPrint(arena, "Open {s}", .{shown.title}) catch shown.title };
            element.accessibility.description = if (shown.linked) |codebase| std.fmt.allocPrint(arena, "{s}, linked to the Eggy codebase at {s}", .{ row.version_label, codebase }) catch null else row.version_label;
        }
        context.element(element);
    }
};

/// Where the title and folder start, from the row's left edge.
const text_left = 8 + tile_size + 14;
const remove_width = 32;

/// What a row draws: its hover, its tile, its words.
const Row = struct {
    shown: *const Shown,
    id: u32,
    mono: *const ui.Font,
    when: []const u8,
    path: []const u8,
    /// "Eggy 0.1.0", or empty when the version can't be told.
    version_label: []const u8,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Row = @ptrCast(@alignCast(context));
        const t = c.theme;
        if (self.id != 0 and c.hot_id == self.id) try c.roundRect(r, t.muted, t.radiusMd());

        // The project's logo, else its initial on a tile coloured from its title.
        const tile = ui.Rect{ .x = r.x + 8, .y = r.y + (r.h - tile_size) / 2, .w = tile_size, .h = tile_size };
        try project_tile.draw(c, tile, self.shown.title, self.shown.logo, 8, if (self.shown.found) .normal else .missing);

        const text = ui.Rect{ .x = r.x + text_left, .y = r.y, .w = r.w - text_left, .h = r.h };
        const title_size = t.text_size + 1;
        try c.textIn(.{ .x = text.x, .y = r.y + 9, .w = text.w, .h = 20 }, self.shown.title, title_size, if (self.shown.found) t.foreground else t.muted_foreground, .start);
        // The Eggy it builds with after the title, and a link when that is a developer codebase.
        var after_title = text.x + c.font.measure(self.shown.title, title_size) + 10;
        if (self.version_label.len > 0) {
            try c.textIn(.{ .x = after_title, .y = r.y + 9, .w = text.w, .h = 20 }, self.version_label, path_size, t.muted_foreground, .start);
            after_title += c.font.measure(self.version_label, path_size) + 6;
        }
        if (self.shown.linked != null) try c.textIn(.{ .x = after_title, .y = r.y + 9, .w = 16, .h = 20 }, link_glyph, path_size, t.primary, .start);
        const ui_font = c.font;
        c.font = self.mono;
        try c.textIn(.{ .x = text.x, .y = r.y + 30, .w = text.w, .h = 16 }, self.path, path_size, t.muted_foreground, .start);
        c.font = ui_font;

        // When it was opened, or that its folder is gone, beside the remove button.
        const right_edge = r.w - 14 - remove_width;
        try c.textIn(.{ .x = r.x, .y = r.y, .w = right_edge, .h = r.h }, self.when, path_size, t.muted_foreground, .end);
    }
};

/// Nothing listed yet: faint rows standing in for projects, and how to get the first.
fn buildEmpty(context: *ui.Context, width: f32) void {
    const ghosts = context.builder().node(0, .{ .width = 260, .height = 3 * 46 }, .{ .custom = .{ .context = &ghost_widths, .draw = drawGhosts } }, &.{}) catch return;
    ghosts.accessibility = .{ .role = .ignored };
    context.element(ghosts);
    // A heading's size without its rule, which would cut the words off from the rows above.
    const heading = context.builder().node(0, .{ .padding = .{ .top = 12 } }, .{ .text = .{ .value = "No projects yet", .size = 20 } }, &.{}) catch return;
    heading.accessibility = .{ .role = .heading, .label = "No projects yet" };
    context.element(heading);
    context.muted("Start one with New Project, or open a folder with an eggy.zon.");
    page_style.restyle(context, .{ .width = @min(width, 400) });
}

const ghost_widths = [3][2]f32{ .{ 150, 230 }, .{ 110, 190 }, .{ 130, 210 } };

fn drawGhosts(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const widths: *const [3][2]f32 = @ptrCast(@alignCast(context));
    const t = c.theme;
    for (widths, 0..) |width, i| {
        const y = r.y + @as(f32, @floatFromInt(i)) * 46;
        const fade: f32 = switch (i) {
            0 => 0.55,
            1 => 0.4,
            else => 0.25,
        };
        try c.roundRectStroke(.{ .x = r.x, .y = y, .w = 36, .h = 36 }, t.border, 8, 1.5);
        try c.roundRectAlpha(.{ .x = r.x + 50, .y = y + 9, .w = width[0], .h = 9 }, t.muted_foreground, 4.5, fade * 0.35);
        try c.roundRectAlpha(.{ .x = r.x + 50, .y = y + 24, .w = width[1], .h = 7 }, t.muted_foreground, 3.5, fade * 0.2);
    }
}

/// Whether `dir` is a git checkout on this machine.
fn isCheckout(dir: []const u8) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var opened = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return false;
    defer opened.close(io);
    opened.access(io, ".git", .{}) catch return false;
    return true;
}

/// Whether `shown`'s title or folder holds `query`, ignoring case; an empty query matches all.
fn matches(shown: Shown, query: []const u8) bool {
    return query.len == 0 or std.ascii.findIgnoreCase(shown.title, query) != null or std.ascii.findIgnoreCase(shown.dir, query) != null;
}

/// `dir` with the home folder written as ~.
fn now() i64 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return std.Io.Clock.real.now(threaded.io()).toSeconds();
}

/// How long ago `then_s` was at `now_s`, in words.
fn ago(arena: std.mem.Allocator, now_s: i64, then_s: i64) []const u8 {
    const elapsed_s = @max(0, now_s - then_s);
    const minute = 60;
    const hour = 60 * minute;
    const day = 24 * hour;
    const counted: struct { n: i64, unit: []const u8 } = if (elapsed_s < minute)
        return "Just now"
    else if (elapsed_s < hour)
        .{ .n = @divFloor(elapsed_s, minute), .unit = "minute" }
    else if (elapsed_s < day)
        .{ .n = @divFloor(elapsed_s, hour), .unit = "hour" }
    else if (elapsed_s < 2 * day)
        return "Yesterday"
    else if (elapsed_s < 30 * day)
        .{ .n = @divFloor(elapsed_s, day), .unit = "day" }
    else if (elapsed_s < 365 * day)
        .{ .n = @divFloor(elapsed_s, 30 * day), .unit = "month" }
    else
        .{ .n = @divFloor(elapsed_s, 365 * day), .unit = "year" };
    return std.fmt.allocPrint(arena, "{d} {s}{s} ago", .{ counted.n, counted.unit, if (counted.n == 1) "" else "s" }) catch "";
}

test "when a project was opened reads in words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const day = 24 * 60 * 60;
    try std.testing.expectEqualStrings("Just now", ago(a, 1000, 990));
    try std.testing.expectEqualStrings("1 minute ago", ago(a, 1000, 1000 - 60));
    try std.testing.expectEqualStrings("3 hours ago", ago(a, 100_000, 100_000 - 3 * 3600));
    try std.testing.expectEqualStrings("Yesterday", ago(a, 10 * day, 9 * day - 100));
    try std.testing.expectEqualStrings("5 days ago", ago(a, 10 * day, 5 * day));
    try std.testing.expectEqualStrings("2 months ago", ago(a, 100 * day, 40 * day));
    try std.testing.expectEqualStrings("Just now", ago(a, 0, 50)); // a clock set back
}

test "search matches a title or folder regardless of case" {
    const shown = Shown{ .dir = "/home/you/space_game", .title = "Space Game", .opened_s = 0, .found = true };
    try std.testing.expect(matches(shown, ""));
    try std.testing.expect(matches(shown, "space g"));
    try std.testing.expect(matches(shown, "SPACE_GAME"));
    try std.testing.expect(!matches(shown, "rocket"));
}
