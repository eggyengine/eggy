//! The Preferences window's Project section: the open project's `eggy.zon`: its title and
//! version, the scene the built game starts in (the default scene, which exports start in unless
//! told otherwise), and what the game's executable says about itself (company, description,
//! copyright and any more of the project's own, by name). Every change is written as it is made,
//! and handed back to the editor as a step to undo.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const listing = @import("assets/listing.zig");
const page_style = @import("page_style.zig");
const restyle = page_style.restyle;
const smallText = page_style.smallText;

const ShortEdit = ui.TextEdit(64);
const LongEdit = ui.TextEdit(256);
/// The most entries of the project's own it holds.
const max_extra = 32;
const control_width: f32 = 240;

/// `eggy.zon` changed from `before` to `after` (both its text, owned by `gpa`).
pub const Change = struct { before: []u8, after: []u8 };

/// The form for one project's `eggy.zon`. On the heap while the Preferences window shows it, as
/// its fields' text lives here.
pub const ProjectSettings = struct {
    gpa: std.mem.Allocator,
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

    /// Read the project in `project_dir`'s `eggy.zon` into a new form.
    pub fn open(gpa: std.mem.Allocator, project_dir: []const u8) !*ProjectSettings {
        const self = try gpa.create(ProjectSettings);
        errdefer gpa.destroy(self);
        const dir = try gpa.dupe(u8, project_dir);
        errdefer gpa.free(dir);
        self.* = .{ .gpa = gpa, .project_dir = dir, .name_arena = .init(gpa), .scenes_arena = .init(gpa) };
        // From here `close` frees all of it.
        self.reload() catch |err| {
            self.close();
            return err;
        };
        return self;
    }

    pub fn close(self: *ProjectSettings) void {
        self.gpa.free(self.project_dir);
        self.gpa.free(self.written);
        self.extra.deinit(self.gpa);
        self.name_arena.deinit();
        self.scenes_arena.deinit();
        self.gpa.destroy(self);
    }

    /// Read `eggy.zon` and the project's scenes again into the fields: they changed elsewhere
    /// (undo, say).
    pub fn reload(self: *ProjectSettings) !void {
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

    /// The section's cards, in the Preferences window's style: a card per setting, its name and
    /// note on the left and its control on the right.
    pub fn build(self: *ProjectSettings, context: *ui.Context) void {
        context.muted("Saved in eggy.zon as you change them; Edit > Undo takes them back.");
        smallText(context, 12);

        beginCard(context, "Title", "What players see in the window's title and the executable's name for itself.");
        _ = context.textInput("##title", &self.title, "My Game");
        endCard(context);
        beginCard(context, "Version", "The game's version, shown in its executable.");
        _ = context.textInput("##version", &self.version, "0.0.1");
        endCard(context);
        beginCard(context, "Default scene", "Where the built game starts, and exports unless you pick another.");
        _ = context.select("##default scene", self.scenes, &self.scene);
        endCard(context);

        context.heading(4, "Executable");
        context.muted("What the game's executable says about itself: on Windows, in its Properties.");
        smallText(context, 12);
        beginCard(context, "Company", "");
        _ = context.textInput("##company", &self.company, "");
        endCard(context);
        beginCard(context, "Description", "");
        _ = context.textInput("##description", &self.description, "");
        endCard(context);
        beginCard(context, "Copyright", "");
        _ = context.textInput("##copyright", &self.copyright, "");
        endCard(context);

        // The project's own, a card each: name, value, and a button taking it away.
        var removed: ?usize = null;
        const arena = context.builder().allocator;
        for (self.extra.items, 0..) |*entry, i| {
            context.begin(.card);
            context.begin(.row);
            _ = context.textInput(std.fmt.allocPrint(arena, "##extra name {d}", .{i}) catch return, &entry.name, "Name");
            restyle(context, .{ .width = 160 });
            _ = context.textInput(std.fmt.allocPrint(arena, "##extra value {d}", .{i}) catch return, &entry.value, "Value");
            restyle(context, .{ .grow = 1 });
            if (context.buttonVariant(std.fmt.allocPrint(arena, "Remove##extra {d}", .{i}) catch return, .ghost)) removed = i;
            context.end();
            restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center });
            context.end();
            restyle(context, .{ .padding = .{ .left = 16, .right = 16, .top = 10, .bottom = 10 } });
        }
        if (removed) |i| _ = self.extra.orderedRemove(i);
        if (self.extra.items.len < max_extra and context.buttonVariant("Add an entry", .outline)) {
            self.extra.append(self.gpa, .{ .name = ShortEdit.init("") catch unreachable, .value = LongEdit.init("") catch unreachable }) catch {};
        }
    }

    /// Write `eggy.zon` from the fields if they changed it; what changed, caller-owned.
    pub fn save(self: *ProjectSettings) !?Change {
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

/// Open a setting's card: its name and `note` on the left; its control follows, then `endCard`.
fn beginCard(context: *ui.Context, title: []const u8, note: []const u8) void {
    context.begin(.card);
    context.begin(.row);
    context.begin(.column);
    context.text(title);
    if (note.len > 0) {
        context.muted(note);
        smallText(context, 13);
    }
    context.end();
    restyle(context, .{ .grow = 1, .gap = 4 });
    context.begin(.column);
}

/// Close the card `beginCard` opened, with its control right-aligned.
fn endCard(context: *ui.Context) void {
    context.end();
    restyle(context, .{ .width = control_width, .align_items = .end });
    context.end();
    restyle(context, .{ .direction = .row, .gap = 20, .align_items = .center });
    context.end();
    restyle(context, .{ .padding = .{ .left = 16, .right = 16, .top = 12, .bottom = 12 } });
}

/// Make `scene` the default scene in the `eggy.zon` of the project in `project_dir`; what changed
/// (caller-owned), or null when it already was.
pub fn setDefaultScene(gpa: std.mem.Allocator, project_dir: []const u8, scene: []const u8) !?Change {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var project = try std.Io.Dir.cwd().openDir(io, project_dir, .{});
    defer project.close(io);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try project.readFileAllocOptions(io, eggy.project.file_name, arena, .limited(1 << 20), .of(u8), 0);
    var config = try eggy.project.parse(arena, before);
    if (config.default_scene) |current| if (std.mem.eql(u8, current, scene)) return null;
    config.default_scene = scene;
    var after: std.Io.Writer.Allocating = .init(arena);
    try eggy.project.write(&after.writer, config);
    try project.writeFile(io, .{ .sub_path = eggy.project.file_name, .data = after.written() });
    const owned_before = try gpa.dupe(u8, before);
    errdefer gpa.free(owned_before);
    return .{ .before = owned_before, .after = try gpa.dupe(u8, after.written()) };
}

test "the default scene is written into eggy.zon, and an unchanged one is no change" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = eggy.project.file_name, .data = ".{ .name = \"rats\", .title = \"Rats\" }\n" });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    const change = (try setDefaultScene(gpa, dir, "resources/scene/sewer.scene.zon")).?;
    defer gpa.free(change.before);
    defer gpa.free(change.after);
    try std.testing.expect(std.mem.indexOf(u8, change.after, "sewer.scene.zon") != null);
    try std.testing.expect(try setDefaultScene(gpa, dir, "resources/scene/sewer.scene.zon") == null);
}

test "the Project section lays out every eggy.zon field in cards and writes a change once" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = eggy.project.file_name, .data = ".{ .name = \"rats\", .title = \"Rats\" }\n" });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    const settings = try ProjectSettings.open(gpa, dir);
    defer settings.close();
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    context.density = .compact;
    context.newFrame(.{ .x = 0, .y = 0, .w = 440, .h = 600 });
    settings.build(&context);
    try std.testing.expect((try context.render()).len > 0);
    try settings.title.set("Sewer Rats");
    const change = (try settings.save()).?;
    defer gpa.free(change.before);
    defer gpa.free(change.after);
    try std.testing.expect(std.mem.indexOf(u8, change.after, "Sewer Rats") != null);
    try std.testing.expect(try settings.save() == null);
}
