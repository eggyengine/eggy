//! The Preferences window's Project section: the open project's `eggy.zon`: its title, version
//! and icon (shown, and as the editor's badged egg), the scene the built game starts in (the default scene, which exports start in unless
//! told otherwise), and what the game's executable says about itself (company, description,
//! copyright and any more of the project's own, by name), and the graphics the game starts with
//! (which players can change in the game). Every change is written as it is made, and handed back
//! to the editor as a step to undo.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const listing = @import("assets/listing.zig");
const icon = @import("icon.zig");
const page_style = @import("page_style.zig");
const restyle = page_style.restyle;
const smallText = page_style.smallText;
const setting_rows = eggy.setting_rows;
const SettingRows = setting_rows.SettingRows;

const render_settings = eggy.render_settings;
const ShortEdit = ui.TextEdit(64);
const ImageFrame = @typeInfo(@FieldType(ui.Image, "frames")).pointer.child;
/// How big the icon previews are drawn.
const preview_px: f32 = 56;
const LongEdit = ui.TextEdit(256);
/// The most entries of the project's own it holds.
const max_extra = 32;

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
    /// The project's images, "None" first (in `scenes_arena`), and which is the icon.
    icons: []const []const u8 = &.{},
    icon: usize = 0,
    /// The chosen icon and the editor's egg badged with it, as last loaded (for `preview_for`,
    /// an index into `icons`) into the window's font; null where it didn't load.
    preview_for: ?usize = null,
    preview: ?ui.Image = null,
    badge_frame: [1]ImageFrame = undefined,
    badge_preview: ?ui.Image = null,
    /// The graphics the game starts with, as the form edits them; `saved_graphics` is what the
    /// file has (the last valid choice, while a number field is half typed).
    graphics: eggy.graphics_settings.Form = .{},
    saved_graphics: render_settings.Settings = .{},
    /// What this machine offers, with the game's window and frame limit choices always shown:
    /// they are for the built game, not the editor's own window.
    caps: render_settings.Capabilities,

    /// Read the project in `project_dir`'s `eggy.zon` into a new form, offering the graphics `caps` allows.
    /// Editor-only heap state: copies the path and owns field/scene storage until `close`.
    /// Allocation/read/parse/field-capacity errors propagate, cleaning partially opened state.
    ///
    /// ```zig
    /// const settings = try ProjectSettings.open(gpa, project_dir, app.graphics.capabilities());
    /// defer settings.close();
    /// ```
    pub fn open(gpa: std.mem.Allocator, project_dir: []const u8, caps: render_settings.Capabilities) !*ProjectSettings {
        const self = try gpa.create(ProjectSettings);
        errdefer gpa.destroy(self);
        const dir = try gpa.dupe(u8, project_dir);
        errdefer gpa.free(dir);
        self.* = .{ .gpa = gpa, .project_dir = dir, .name_arena = .init(gpa), .scenes_arena = .init(gpa), .caps = caps };
        // ponytail: backends, present modes and antialiasing are this machine's, not every player's; list the build target's when addGame knows it.
        self.caps.window_settings = true;
        self.caps.frame_limit = true;
        // From here `close` frees all of it.
        self.reload() catch |err| {
            self.close();
            return err;
        };
        return self;
    }

    /// Free the form, its copied project path, cached config/scene lists, and `self`.
    /// Does not save pending field edits or free changes already returned by `save`.
    ///
    /// ```zig
    /// settings.close(); // Editor preferences window is no longer using its fields.
    /// ```
    pub fn close(self: *ProjectSettings) void {
        if (self.preview) |*image| image.deinit(self.gpa);
        self.gpa.free(self.project_dir);
        self.gpa.free(self.written);
        self.extra.deinit(self.gpa);
        self.name_arena.deinit();
        self.scenes_arena.deinit();
        self.gpa.destroy(self);
    }

    /// Read `eggy.zon` and the project's scenes again into the fields: they changed elsewhere
    /// (undo, say).
    /// Replaces cached strings/fields, invalidating old borrowed names and scene labels.
    /// I/O/parse/allocation/field-capacity errors propagate; it is not a transactional reload.
    ///
    /// ```zig
    /// try settings.reload(); // After the host restores eggy.zon through undo.
    /// ```
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
        self.graphics.load(config.graphics);
        self.saved_graphics = config.graphics;
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

        // The images to pick the icon from; an icon that isn't among them is kept as it is.
        var images: std.ArrayList([]const u8) = .empty;
        try images.append(self.scenes_arena.allocator(), "None");
        try images.appendSlice(self.scenes_arena.allocator(), try listing.images(self.scenes_arena.allocator(), io, project, eggy.project.resources_dir));
        self.icon = 0;
        if (config.icon) |chosen| {
            self.icon = for (images.items, 0..) |image, i| {
                if (std.mem.eql(u8, image, chosen)) break i;
            } else blk: {
                try images.append(self.scenes_arena.allocator(), try self.scenes_arena.allocator().dupe(u8, chosen));
                break :blk images.items.len - 1;
            };
        }
        self.icons = images.items;
        self.preview_for = null;
    }

    /// The section's settings, in groups of rows (`eggy.setting_rows`): the game, its starting
    /// graphics, and its executable.
    /// Builds in an active editor UI frame, mutating draft fields only; call `save` afterward
    /// to persist and obtain undo text. Frame elements borrow the form through rendering.
    ///
    /// ```zig
    /// settings.build(context);
    /// if (try settings.save()) |change|
    ///     history.recordProjectSettings(change.before, change.after, now_ms);
    /// ```
    pub fn build(self: *ProjectSettings, context: *ui.Context) void {
        var general = SettingRows{};
        setting_rows.beginGroup(context);
        general.begin(context, "Title", "What players see in the window's title, and the executable's name for itself.");
        _ = context.textInput("##title", &self.title, "My Game");
        general.end(context);
        general.begin(context, "Version", "The game's version, shown in its executable.");
        _ = context.textInput("##version", &self.version, "0.0.1");
        general.end(context);
        general.begin(context, "Default scene", "Where the built game starts, and exports unless you pick another.");
        _ = context.select("##default scene", self.scenes, &self.scene);
        general.end(context);
        general.begin(context, "Icon", "An image of the project's. The editor's egg wears it in its corner.");
        _ = context.select("##icon", self.icons, &self.icon);
        general.end(context);
        if (self.icon != 0) self.iconPreviews(context);
        setting_rows.endGroup(context);

        groupHeading(context, "Graphics", "What the game starts with. Players can change these in the game.");
        setting_rows.beginGroup(context);
        _ = self.graphics.build(context, .{ .caps = &self.caps, .adapter = false });
        setting_rows.endGroup(context);
        self.graphics.notice(context);

        groupHeading(context, "Executable", "What the game's executable says about itself: on Windows, in its Properties.");
        var executable = SettingRows{};
        setting_rows.beginGroup(context);
        executable.begin(context, "Company", "");
        _ = context.textInput("##company", &self.company, "");
        executable.end(context);
        executable.begin(context, "Description", "");
        _ = context.textInput("##description", &self.description, "");
        executable.end(context);
        executable.begin(context, "Copyright", "");
        _ = context.textInput("##copyright", &self.copyright, "");
        executable.end(context);

        // The project's own, a row each: name, value, and a button taking it away.
        var removed: ?usize = null;
        const arena = context.builder().allocator;
        for (self.extra.items, 0..) |*entry, i| {
            const name_id = std.fmt.allocPrint(arena, "##extra name {d}", .{i}) catch continue;
            const value_id = std.fmt.allocPrint(arena, "##extra value {d}", .{i}) catch continue;
            const remove_label = std.fmt.allocPrint(arena, "Remove##extra {d}", .{i}) catch continue;
            executable.divide(context);
            context.begin(.row);
            _ = context.textInput(name_id, &entry.name, "Name");
            restyle(context, .{ .width = 160 });
            _ = context.textInput(value_id, &entry.value, "Value");
            restyle(context, .{ .grow = 1 });
            if (context.buttonVariant(remove_label, .ghost)) removed = i;
            context.end();
            restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center, .padding = .{ .top = 8, .bottom = 8 } });
        }
        setting_rows.endGroup(context);
        if (removed) |i| _ = self.extra.orderedRemove(i);
        if (self.extra.items.len < max_extra and context.buttonVariant("Add an entry", .outline)) {
            self.extra.append(self.gpa, .{ .name = ShortEdit.init("") catch unreachable, .value = LongEdit.init("") catch unreachable }) catch {};
        }
    }

    /// The chosen icon beside the editor's egg wearing it, loaded again when the choice changed.
    fn iconPreviews(self: *ProjectSettings, context: *ui.Context) void {
        if (self.preview_for != self.icon) self.loadPreviews(context.font);
        context.begin(.row);
        previewTile(context, if (self.preview) |*image| image else null, "Icon");
        previewTile(context, if (self.badge_preview) |*image| image else null, "Editor");
        context.end();
        restyle(context, .{ .direction = .row, .gap = 16, .padding = .{ .top = 4, .bottom = 8 } });
    }

    /// Decode the chosen icon and the badged egg into `font`'s color atlas; a file that won't
    /// decode leaves its preview empty, which the tile says.
    fn loadPreviews(self: *ProjectSettings, font: *ui.Font) void {
        if (self.preview) |*image| image.deinit(self.gpa);
        self.preview = null;
        self.badge_preview = null;
        self.preview_for = self.icon;
        const path = self.icons[self.icon];

        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        if (std.Io.Dir.cwd().openDir(io, self.project_dir, .{})) |dir| {
            var project = dir;
            defer project.close(io);
            if (project.readFileAlloc(io, path, self.gpa, .limited(32 << 20))) |bytes| {
                defer self.gpa.free(bytes);
                self.preview = ui.Image.load(self.gpa, font, bytes) catch null;
            } else |_| {}
        } else |_| {}

        const badged = self.gpa.create(icon.Badged) catch return;
        defer self.gpa.destroy(badged);
        icon.decodeBadge(self.gpa, self.project_dir, path, badged) catch return;
        const sprite = font.addSprite(badged, icon.badged_size, icon.badged_size) catch return;
        self.badge_frame = .{.{ .sprite = sprite, .delay_ms = 0 }};
        self.badge_preview = .{ .width = icon.badged_size, .height = icon.badged_size, .frames = &self.badge_frame, .duration_ms = 0 };
    }

    /// Write `eggy.zon` from the fields if they changed it; what changed, caller-owned.
    /// Null means identical serialized settings. Returned before/after buffers use `self.gpa`;
    /// transfer them to matching-allocator history or free both. Serialization/I/O/allocation
    /// failures propagate; the disk write can precede a later allocation failure.
    ///
    /// ```zig
    /// if (try settings.save()) |change| {
    ///     defer gpa.free(change.before);
    ///     defer gpa.free(change.after);
    ///     std.log.info("Project settings saved", .{});
    /// }
    /// ```
    pub fn save(self: *ProjectSettings) !?Change {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var extra: std.ArrayList(eggy.project.Metadata.Entry) = .empty;
        for (self.extra.items) |entry| {
            if (entry.name.text().len == 0) continue; // still being written
            try extra.append(arena, .{ .name = entry.name.text(), .value = entry.value.text() });
        }
        // A number half typed keeps the last valid choice, and an invalid one isn't written.
        var graphics = self.graphics.read() catch self.graphics.draft;
        graphics.validateValues() catch |err| {
            self.graphics.report(err);
            graphics = self.saved_graphics;
        };
        // What the form doesn't edit (installed plugins, a plugin manifest) stays as the file has it.
        const kept = try eggy.project.parse(arena, try arena.dupeZ(u8, self.written));
        const config = eggy.project.Config{
            .plugins = kept.plugins,
            .plugin = kept.plugin,
            .name = self.name,
            .title = self.title.text(),
            .version = self.version.text(),
            .default_scene = if (self.scene == 0) null else self.scenes[self.scene],
            .icon = if (self.icon == 0) null else self.icons[self.icon],
            .graphics = graphics,
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
        self.saved_graphics = graphics;
        return .{ .before = before, .after = after };
    }
};

/// The graphics `eggy.zon`'s `text` asks for (the project's defaults), for applying the
/// config that undo or redo just wrote. Parse and allocation errors propagate.
///
/// ```zig
/// _ = try app.setGraphicsDefaults(try graphicsIn(gpa, change.value(direction)));
/// ```
pub fn graphicsIn(gpa: std.mem.Allocator, text: []const u8) !render_settings.Settings {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return (try eggy.project.parse(arena, try arena.dupeZ(u8, text))).graphics;
}

/// The graphics in the `eggy.zon` of the project in `project_dir`, which the editor makes its
/// defaults as it opens the project. I/O and parse errors propagate.
pub fn loadGraphics(gpa: std.mem.Allocator, project_dir: []const u8) !render_settings.Settings {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var project = try std.Io.Dir.cwd().openDir(io, project_dir, .{});
    defer project.close(io);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    return (try eggy.project.load(arena_state.allocator(), io, project)).graphics;
}

/// One icon preview with its caption under it, or a note where it didn't load.
fn previewTile(context: *ui.Context, image: ?*const ui.Image, caption: []const u8) void {
    context.begin(.column);
    if (image) |shown| context.image(shown, preview_px) else {
        context.muted("Can't read this image");
        smallText(context, 12);
    }
    context.muted(caption);
    smallText(context, 12);
    context.end();
    restyle(context, .{ .gap = 4, .align_items = .center });
}

/// A heading over a group of rows, with a line on what the group is.
fn groupHeading(context: *ui.Context, title: []const u8, note: []const u8) void {
    context.begin(.column);
    context.heading(4, title);
    context.muted(note);
    smallText(context, 12);
    context.end();
    restyle(context, .{ .gap = 2, .padding = .{ .top = 8 } });
}

/// Make `scene` the default scene in the `eggy.zon` of the project in `project_dir`; what changed
/// (caller-owned), or null when it already was.
/// Editor export helper: `scene` is a trusted project-relative scene path, not validated here.
/// Borrows paths, reads/parses and rewrites the config, returning two `gpa`-owned buffers.
/// Errors propagate, possibly after the file was written; transfer returned texts to history
/// or free both.
///
/// ```zig
/// if (try project_settings.setDefaultScene(gpa, project_dir, "resources/scene/main.scene.zon")) |change|
///     history.recordProjectSettings(change.before, change.after, now_ms);
/// ```
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
    const settings = try ProjectSettings.open(gpa, dir, .{});
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

test "the project's icon is picked from its images and written to eggy.zon" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = eggy.project.file_name, .data = ".{ .name = \"rats\", .title = \"Rats\" }\n" });
    try tmp.dir.createDirPath(std.testing.io, "resources/art");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "resources/art/rat.png", .data = "not really a png" });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    const settings = try ProjectSettings.open(gpa, dir, .{});
    defer settings.close();
    try std.testing.expectEqualStrings("None", settings.icons[0]);
    try std.testing.expectEqualStrings("resources/art/rat.png", settings.icons[1]);
    settings.icon = 1;
    const change = (try settings.save()).?;
    defer gpa.free(change.before);
    defer gpa.free(change.after);
    try std.testing.expect(std.mem.indexOf(u8, change.after, ".icon = \"resources/art/rat.png\"") != null);
    try settings.reload();
    try std.testing.expectEqual(@as(usize, 1), settings.icon);
}

test "saving the Project section keeps the installed plugins" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = eggy.project.file_name, .data = ".{ .name = \"rats\", .title = \"Rats\", .plugins = .{ .{ .module = \"eggy_git\" }, .{ .module = \"eggy_frame_stats\" } } }\n" });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    const settings = try ProjectSettings.open(gpa, dir, .{});
    defer settings.close();
    try settings.title.set("Sewer Rats");
    const change = (try settings.save()).?;
    defer gpa.free(change.before);
    defer gpa.free(change.after);
    try std.testing.expect(std.mem.indexOf(u8, change.after, "eggy_git") != null);
    try std.testing.expect(std.mem.indexOf(u8, change.after, "eggy_frame_stats") != null);
}

test "graphics are saved in eggy.zon, kept by other edits, and read back after undo" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = eggy.project.file_name, .data = ".{ .name = \"rats\", .title = \"Rats\" }\n" });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    const settings = try ProjectSettings.open(gpa, dir, .{});
    defer settings.close();
    // A project that says nothing gets the engine's defaults.
    try std.testing.expectEqual(render_settings.Settings{}, settings.saved_graphics);

    // Choices are written, and a later unrelated edit keeps them.
    const chosen = render_settings.Settings{ .mipmaps = false, .anti_aliasing = .fxaa, .frame_limit = 60, .width = 1280, .height = 720 };
    settings.graphics.load(chosen);
    const first = (try settings.save()).?;
    defer gpa.free(first.before);
    defer gpa.free(first.after);
    try settings.title.set("Sewer Rats");
    const second = (try settings.save()).?;
    defer gpa.free(second.before);
    defer gpa.free(second.after);
    try std.testing.expectEqual(chosen, try loadGraphics(gpa, dir));

    // Undo restores the earlier file, whose graphics the editor then makes the defaults.
    try std.testing.expectEqual(render_settings.Settings{}, try graphicsIn(gpa, first.before));
    try std.testing.expectEqual(chosen, try graphicsIn(gpa, second.before));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = eggy.project.file_name, .data = first.before });
    try settings.reload();
    try std.testing.expectEqual(render_settings.Settings{}, settings.saved_graphics);
    try std.testing.expectEqual(render_settings.Settings{}, settings.graphics.draft);
}

test "a half typed or invalid number is not written to eggy.zon, and says why" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = eggy.project.file_name, .data = ".{ .name = \"rats\", .title = \"Rats\" }\n" });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    const settings = try ProjectSettings.open(gpa, dir, .{});
    defer settings.close();

    // Too small a window is refused, and the file keeps the last good choice.
    try settings.graphics.width.set("10");
    settings.graphics.draft.width = 10;
    const change = (try settings.save()).?; // only the file's normal form, not the window
    defer gpa.free(change.before);
    defer gpa.free(change.after);
    try std.testing.expect(settings.graphics.message_kind == .failed);
    try std.testing.expectEqual(render_settings.Settings{}, try loadGraphics(gpa, dir));
    try std.testing.expect(try settings.save() == null);

    // A number half typed keeps the last good choice too.
    try settings.graphics.width.set("12x");
    try std.testing.expect(try settings.save() == null);
    try std.testing.expectEqual(render_settings.Settings{}, try loadGraphics(gpa, dir));
}
