//! File > Project Settings: the open project's `eggy.zon`, edited in a window of its own: its
//! title and version, the scene the built game starts in (the default scene, which exports start
//! in unless told otherwise), and what the game's executable says about itself (company,
//! description, copyright and any more of the project's own, by name). Every change is written
//! as it is made, and handed back to the editor as a step to undo.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const ToolWindow = @import("tool_window.zig").ToolWindow;
const listing = @import("assets/listing.zig");
const log = std.log.scoped(.project_settings);

const ShortEdit = ui.TextEdit(64);
const LongEdit = ui.TextEdit(256);
/// The most entries of the project's own it holds.
const max_extra = 32;

/// `eggy.zon` changed from `before` to `after` (both its text, owned by `gpa`).
pub const Change = struct { before: []u8, after: []u8 };

pub const ProjectSettingsWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    /// The project's folder, owned.
    project_dir: []u8,
    /// What doesn't change here: the package name (in `name_arena`).
    name: []const u8 = "",
    name_arena: std.heap.ArenaAllocator,
    /// `eggy.zon` as last written or read, owned.
    written: []u8 = &.{},
    title: LongEdit = LongEdit.init("") catch unreachable,
    version: ShortEdit = ShortEdit.init("") catch unreachable,
    company: LongEdit = LongEdit.init("") catch unreachable,
    description: LongEdit = LongEdit.init("") catch unreachable,
    copyright: LongEdit = LongEdit.init("") catch unreachable,
    extra: std.ArrayList(struct { name: ShortEdit, value: LongEdit }) = .empty,
    /// The project's scenes, "None" first (in `scenes_arena`), and which is the default.
    scenes: []const []const u8 = &.{},
    scenes_arena: std.heap.ArenaAllocator,
    scene: usize = 0,
    /// Whether the window asked to close.
    closing: bool = false,

    /// Open the window on the project in `project_dir`. On the heap, as its page keeps a pointer
    /// to it.
    pub fn open(gpa: std.mem.Allocator, graphics: *eggy.Graphics, font: *ui.Font, project_dir: []const u8) !*ProjectSettingsWindow {
        const self = made: {
            const self = try gpa.create(ProjectSettingsWindow);
            errdefer gpa.destroy(self);
            const dir = try gpa.dupe(u8, project_dir);
            errdefer gpa.free(dir);
            const window = try ToolWindow.open(gpa, graphics, font, "Project Settings", .{ 560, 560 }, .{ .resizable = true });
            self.* = .{ .gpa = gpa, .window = window, .project_dir = dir, .name_arena = .init(gpa), .scenes_arena = .init(gpa) };
            break :made self;
        };
        // From here `close` frees all of it.
        self.reload() catch |err| {
            self.close(graphics);
            return err;
        };
        return self;
    }

    pub fn close(self: *ProjectSettingsWindow, graphics: *eggy.Graphics) void {
        self.window.close(graphics);
        self.gpa.free(self.project_dir);
        self.gpa.free(self.written);
        self.extra.deinit(self.gpa);
        self.name_arena.deinit();
        self.scenes_arena.deinit();
        self.gpa.destroy(self);
    }

    /// Read `eggy.zon` and the project's scenes again into the fields: they changed elsewhere
    /// (undo, say).
    pub fn reload(self: *ProjectSettingsWindow) !void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer project.close(io);
        _ = self.name_arena.reset(.retain_capacity);
        const arena = self.name_arena.allocator();
        const text = try project.readFileAllocOptions(io, eggy.project.file_name, arena, .limited(1 << 20), .of(u8), 0);
        const config = try eggy.project.parse(arena, text);
        self.name = config.name;
        self.gpa.free(self.written);
        self.written = try self.gpa.dupe(u8, text);

        // Each field as the file has it.
        try self.title.set(config.title);
        try self.version.set(config.version);
        try self.company.set(config.metadata.company);
        try self.description.set(config.metadata.description);
        try self.copyright.set(config.metadata.copyright);
        self.extra.clearRetainingCapacity();
        for (config.metadata.extra[0..@min(config.metadata.extra.len, max_extra)]) |entry| try self.extra.append(self.gpa, .{ .name = try ShortEdit.init(entry.name), .value = try LongEdit.init(entry.value) });

        // The scenes to pick from, the file's default among them.
        _ = self.scenes_arena.reset(.retain_capacity);
        var scenes: std.ArrayList([]const u8) = .empty;
        try scenes.append(self.scenes_arena.allocator(), "None");
        try scenes.appendSlice(self.scenes_arena.allocator(), try listing.scenes(self.scenes_arena.allocator(), io, project, eggy.project.resources_dir));
        self.scenes = scenes.items;
        self.scene = 0;
        if (config.default_scene) |default| for (self.scenes, 0..) |scene, i| {
            if (std.mem.eql(u8, scene, default)) self.scene = i;
        };
    }

    /// Handle `curr_event` if it is for this window; returns whether it was. Closing it, or
    /// Escape, asks to close it.
    pub fn handle(self: *ProjectSettingsWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (curr_event == .window_close_requested) self.closing = true;
        if (weeoui_sdl3.translate(curr_event)) |input| if (input == .key_down and input.key_down.key == .escape) {
            self.closing = true;
        };
        self.window.handle(curr_event);
        return true;
    }

    /// Draw a frame. Returns what changed in `eggy.zon` this frame, which it wrote, for the
    /// editor to record (the caller owns it), and whether the window should stay open.
    pub fn update(self: *ProjectSettingsWindow, graphics: *eggy.Graphics, style: *const ui.Context) !struct { change: ?Change, open: bool } {
        const Page = struct {
            window: *ProjectSettingsWindow,
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.window.build(context);
            }
        };
        var page = Page{ .window = self };
        try self.window.present(graphics, style, &page);
        return .{ .change = self.save() catch |err| blk: {
            log.err("cannot write {s}: {t}", .{ eggy.project.file_name, err });
            break :blk null;
        }, .open = !self.closing };
    }

    fn build(self: *ProjectSettingsWindow, context: *ui.Context) void {
        context.heading(3, "Project Settings");
        context.muted("Saved in eggy.zon as you change them, and Edit > Undo takes them back.");

        context.heading(4, "Game");
        _ = context.textInput("Title", &self.title, "What players see");
        _ = context.textInput("Version", &self.version, "0.0.1");
        _ = context.select("Default scene", self.scenes, &self.scene);
        context.muted("Where the built game starts, and exports unless you pick another.");

        context.heading(4, "Executable");
        context.muted("What the game's executable says about itself: on Windows, in its Properties.");
        _ = context.textInput("Company", &self.company, "");
        _ = context.textInput("Description", &self.description, "");
        _ = context.textInput("Copyright", &self.copyright, "");

        // The project's own, a row each: name, value, and a button taking it away.
        var removed: ?usize = null;
        const arena = context.builder().allocator;
        for (self.extra.items, 0..) |*entry, i| {
            context.begin(.row);
            _ = context.textInput(std.fmt.allocPrint(arena, "##extra name {d}", .{i}) catch return, &entry.name, "Name");
            _ = context.textInput(std.fmt.allocPrint(arena, "##extra value {d}", .{i}) catch return, &entry.value, "Value");
            if (context.buttonVariant(std.fmt.allocPrint(arena, "Remove##extra {d}", .{i}) catch return, .ghost)) removed = i;
            context.end();
        }
        if (removed) |i| _ = self.extra.orderedRemove(i);
        if (self.extra.items.len < max_extra and context.buttonVariant("Add an entry", .outline)) {
            self.extra.append(self.gpa, .{ .name = ShortEdit.init("") catch unreachable, .value = LongEdit.init("") catch unreachable }) catch {};
        }
    }

    /// Write `eggy.zon` from the fields if they changed it; what changed, caller-owned.
    fn save(self: *ProjectSettingsWindow) !?Change {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var extra: std.ArrayList(eggy.project.Metadata.Entry) = .empty;
        for (self.extra.items) |entry| {
            if (entry.name.text().len == 0) continue; // still being written
            try extra.append(arena, .{ .name = entry.name.text(), .value = entry.value.text() });
        }
        const config = eggy.project.Config{
            .name = self.name,
            .title = self.title.text(),
            .version = self.version.text(),
            .default_scene = if (self.scene == 0) null else self.scenes[self.scene],
            .metadata = .{ .company = self.company.text(), .description = self.description.text(), .copyright = self.copyright.text(), .extra = extra.items },
        };
        var text: std.Io.Writer.Allocating = .init(arena);
        try eggy.project.write(&text.writer, config);
        if (std.mem.eql(u8, text.written(), self.written)) return null;

        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer project.close(io);
        try project.writeFile(io, .{ .sub_path = eggy.project.file_name, .data = text.written() });
        const after = try self.gpa.dupe(u8, text.written());
        const before = self.written;
        self.written = try self.gpa.dupe(u8, after);
        return .{ .before = before, .after = after };
    }
};
