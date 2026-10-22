//! The Asset Preview panel: the file selected in Assets, shown as itself. Images fit the panel
//! over a checkerboard (GIFs play), UI scenes are drawn as the game draws them, and any file that
//! reads as text (code, scenes, settings) shows in a terminal view to scroll, select and copy.
//! Models can be turned and played in a viewer (`model_preview.zig`); sounds and videos show
//! what they are. It reads the file again when it changes.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ui_scenes = eggy.ui_scenes;
const ProjectAssets = @import("assets/project_assets.zig").ProjectAssets;
const TerminalView = @import("terminal_view.zig").TerminalView;
const ModelPreview = @import("model_preview.zig").ModelPreview;
const page_style = @import("page_style.zig");

/// The most of a text file shown.
const max_text_bytes = 256 * 1024;
const video_extensions = [_][]const u8{ ".mp4", ".webm", ".mov", ".mkv", ".avi", ".ogv" };

/// What the panel shows of the file selected.
const Shown = union(enum) {
    nothing,
    image: []const u8,
    ui_scene: []const u8,
    model,
    text,
    /// A file it can't show, described.
    described: []const u8,
};

/// What `build` reads from, borrowed for the call.
pub const Request = struct {
    /// The Assets panel's selection: a project path, and whether it is inside a model.
    selection: ?struct { path: []const u8, virtual: bool },
    assets: *ProjectAssets,
    project_dir: []const u8,
    app: *eggy.App,
    time_ms: u64,
};

pub const AssetPreview = struct {
    gpa: std.mem.Allocator,
    images: ui_scenes.cache.Images,
    text: TerminalView,
    model: ModelPreview,
    /// The file shown, and what it was when read: a change reads it again.
    path: std.ArrayList(u8) = .empty,
    stamp: ?struct { size: u64, modified: i96 } = null,
    /// Its size, and its text (empty: it isn't text) for the text view, bumping `version`.
    size: u64 = 0,
    contents: std.ArrayList(u8) = .empty,
    version: u64 = 0,
    /// Where the UI scene's area went in the last frame's layout.
    scene_area: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn init(gpa: std.mem.Allocator, mono: *const ui.Font) AssetPreview {
        return .{ .gpa = gpa, .images = .{ .gpa = gpa }, .text = .init(gpa, mono), .model = .init(gpa) };
    }

    pub fn deinit(self: *AssetPreview) void {
        self.images.deinit();
        self.text.deinit();
        self.model.deinit();
        self.path.deinit(self.gpa);
        self.contents.deinit(self.gpa);
    }

    /// An event over the panel: the text view scrolls, selects and copies. Returns whether it
    /// was used.
    pub fn handle(self: *AssetPreview, event: ui.input.Event) bool {
        if (self.model.handle(event)) return true;
        if (self.contents.items.len == 0) return false;
        return self.text.handle(event);
    }

    /// Draw the selected file.
    pub fn build(self: *AssetPreview, context: *ui.Context, request: Request) void {
        self.model.shown = false;
        const arena = context.builder().allocator;
        const selection = request.selection orelse {
            context.muted("Select a file in Assets to see it here.");
            page_style.smallText(context, 13);
            return;
        };
        const path = selection.path;

        // Its name and where it is.
        context.text(std.fs.path.basename(path));
        page_style.smallText(context, 15);
        context.muted(path);
        page_style.smallText(context, 11);
        if (context.last_added) |text| text.paint_kind.text.wrap = true;

        if (selection.virtual) {
            context.muted(std.fmt.allocPrint(arena, "Part of {s}: drop it on a field to use it.", .{std.fs.path.dirname(path) orelse path}) catch "Part of a model.");
            page_style.smallText(context, 13);
            // A material's texture shows as the image it is.
            const reference = request.assets.referenceAt(path) orelse return;
            if (reference.kind != .image) return;
            if (!std.mem.eql(u8, self.path.items, path)) {
                self.path.clearRetainingCapacity();
                self.path.appendSlice(self.gpa, path) catch {};
                self.images.forgetAll();
            }
            context.muted("Drag it onto a folder in Assets to save it as a PNG you can edit.");
            page_style.smallText(context, 12);
            self.image(context, request, arena.dupe(u8, reference.key()) catch return, @max(80, page_style.pageHeight(context) - 84));
            return;
        }
        self.refresh(request.project_dir, path);
        const shown = self.kindOf(arena, request.assets, path);
        context.muted(self.details(context, request, shown, path));
        page_style.smallText(context, 12);

        const height = @max(80, page_style.pageHeight(context) - 64);
        switch (shown) {
            .nothing => {},
            .image => |key| self.image(context, request, key, height),
            .ui_scene => |key| self.uiScene(context, request, key, height),
            .model => self.model.build(context, .{ .path = path, .assets = request.assets, .app = request.app, .time_ms = request.time_ms, .height = height }),
            .text => self.text.add(context, self.contents.items, self.version, height),
            .described => |note| {
                context.muted(note);
                page_style.smallText(context, 13);
                if (context.last_added) |text| text.paint_kind.text.wrap = true;
            },
        }
    }

    /// Read `path` again when it is another file or it changed: its size, and its text if it is
    /// text.
    fn refresh(self: *AssetPreview, project_dir: []const u8, path: []const u8) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = std.Io.Dir.cwd().openDir(io, project_dir, .{}) catch return;
        defer project.close(io);
        const stat = project.statFile(io, path, .{}) catch null;
        const Stamp = @typeInfo(@TypeOf(self.stamp)).optional.child;
        const stamp: ?Stamp = if (stat) |found| .{ .size = found.size, .modified = found.mtime.nanoseconds } else null;
        const same_file = std.mem.eql(u8, self.path.items, path);
        if (same_file and std.meta.eql(stamp, self.stamp)) return;

        self.path.clearRetainingCapacity();
        self.path.appendSlice(self.gpa, path) catch {};
        self.stamp = stamp;
        self.size = if (stat) |found| found.size else 0;
        self.contents.clearRetainingCapacity();
        self.version +%= 1;
        // A UI scene, image or model drawn from the old file is drawn from the new one.
        self.images.forgetAll();
        self.model.key_len = 0;
        // The first `max_text_bytes`, kept when they read as text.
        var file = project.openFile(io, path, .{}) catch return;
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        reader.interface.appendRemaining(self.gpa, &self.contents, .limited(max_text_bytes)) catch |err| switch (err) {
            error.StreamTooLong => {},
            else => return self.contents.clearRetainingCapacity(),
        };
        if (!readsAsText(self.contents.items)) self.contents.clearRetainingCapacity();
    }

    /// How the file at `path` is shown.
    fn kindOf(self: *const AssetPreview, arena: std.mem.Allocator, assets: *ProjectAssets, path: []const u8) Shown {
        const reference = assets.referenceAt(path);
        const kind = if (reference) |found| found.kind else eggy.assets.Kind.of(path);
        const key = if (reference) |found| arena.dupe(u8, found.key()) catch "" else "";
        const extension = std.fs.path.extension(path);
        if (kind == .image and key.len > 0 and eggy.assets.Kind.isTexture(path)) return .{ .image = key };
        if (kind == .ui and key.len > 0) return .{ .ui_scene = key };
        if (kind == .folder) return .{ .described = "A folder: open it in Assets to see what it holds." };
        if (kind == .model) return .model;
        if (kind == .audio) return .{ .described = "A sound. Eggy can't play sounds yet, so it can't be listened to here." };
        for (video_extensions) |video| if (std.ascii.eqlIgnoreCase(extension, video)) {
            return .{ .described = "A video. Eggy can't play videos yet, so it can't be watched here." };
        };
        if (self.contents.items.len > 0) return .text;
        return .{ .described = "This file isn't an image or text, so there is nothing to show of it." };
    }

    /// One line on the file: its kind and size, and an image's pixels and frames.
    fn details(self: *AssetPreview, context: *ui.Context, request: Request, shown: Shown, path: []const u8) []const u8 {
        const arena = context.builder().allocator;
        const extension = std.fs.path.extension(path);
        const kind = if (extension.len > 1) extension[1..] else "file";
        var size_buffer: [32]u8 = undefined;
        const size = sizeText(&size_buffer, self.size);
        if (shown == .image) if (self.images.get(request.app.resources(), context.font, shown.image)) |loaded| {
            const frames = loaded.frames.len;
            return std.fmt.allocPrint(arena, "{s} image, {d} x {d}{s}, {s}", .{ kind, loaded.width, loaded.height, if (frames > 1) std.fmt.allocPrint(arena, ", {d} frames", .{frames}) catch "" else "", size }) catch size;
        };
        if (shown == .text and self.contents.items.len < self.size) return std.fmt.allocPrint(arena, "{s}, {s} (the first {d} KB shown)", .{ kind, size, max_text_bytes / 1024 }) catch size;
        return std.fmt.allocPrint(arena, "{s}, {s}", .{ kind, size }) catch size;
    }

    /// The image fit to the panel's width and `height`, over a checkerboard; a GIF plays.
    fn image(self: *AssetPreview, context: *ui.Context, request: Request, key: []const u8, height: f32) void {
        const loaded = self.images.get(request.app.resources(), context.font, key) orelse {
            context.muted("This image couldn't be loaded: see the Console.");
            return;
        };
        const width = context.contentWidth();
        const w: f32 = @floatFromInt(loaded.width);
        const h: f32 = @floatFromInt(loaded.height);
        // Small images are enlarged to whole multiples, so pixel art stays crisp.
        var fit = @min(width / w, height / h);
        if (fit > 1) fit = @floor(fit);
        const b = context.builder();
        const picture = b.node(0, .{ .width = w * fit, .height = h * fit }, .{ .image = loaded.frameAt(request.time_ms) }, &.{}) catch return;
        picture.accessibility = .{ .role = .image, .label = std.fs.path.basename(self.path.items) };
        const board = b.node(0, .{ .width = w * fit, .height = h * fit }, .{ .custom = .{ .context = context, .draw = drawCheckerboard } }, &.{picture}) catch return;
        context.element(board);
    }

    /// The UI scene drawn across the panel as a screen of its design size would show it.
    fn uiScene(self: *AssetPreview, context: *ui.Context, request: Request, key: []const u8, height: f32) void {
        const state = &request.app.ui_scenes;
        const resources = request.app.resources();
        const scene = state.sceneCache().get(resources, key) orelse {
            context.muted("This UI scene couldn't be read: see the Console.");
            return;
        };
        const fit = @min(context.contentWidth() / scene.design_size[0], height / scene.design_size[1]);
        const size = [2]f32{ scene.design_size[0] * fit, scene.design_size[1] * fit };
        context.element(context.builder().node(0, .{ .width = size[0], .height = size[1] }, .{ .custom = .{ .context = &self.scene_area, .draw = recordArea } }, &.{}) catch return);
        if (self.scene_area.w <= 0) return;
        // Drawn where its placeholder was laid out last frame: a frame late when the panel moves.
        const area = ui.Rect{ .x = self.scene_area.x, .y = self.scene_area.y, .w = size[0], .h = size[1] };
        const backdrop = context.builder().node(0, .{ .width = area.w, .height = area.h }, .{ .surface = .track }, &.{}) catch return;
        backdrop.overlay = .{ .point = .init(area.x, area.y) };
        context.element(backdrop);
        _ = ui_scenes.scene_ui.build(context, state, resources, &self.images, scene, .{ .id = std.math.maxInt(u32), .generation = 0 }, .{ .viewport = area, .scale = scene.scaling.scale(scene.design_size, .{ area.w, area.h }), .z_index = 1, .interactive = false, .clip = area }, request.time_ms) catch |err| {
            std.log.err("cannot preview the UI scene: {t}", .{err});
        };
    }
};

/// Whether `bytes` read as text: UTF-8 without the NULs binary files are full of.
fn readsAsText(bytes: []const u8) bool {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return false;
    // A file cut off at the limit may end inside a character.
    var end = bytes.len;
    while (end > 0 and end + 4 > bytes.len and (bytes[end - 1] & 0xC0) == 0x80) end -= 1;
    if (end > 0 and end + 4 > bytes.len and bytes[end - 1] >= 0xC0) end -= 1;
    return std.unicode.utf8ValidateSlice(bytes[0..end]);
}

/// `bytes` as people read a file's size: "8.2 KB".
fn sizeText(buffer: []u8, bytes: u64) []const u8 {
    const value: f64 = @floatFromInt(bytes);
    return (if (bytes < 1024)
        std.fmt.bufPrint(buffer, "{d} bytes", .{bytes})
    else if (bytes < 1024 * 1024)
        std.fmt.bufPrint(buffer, "{d:.1} KB", .{value / 1024})
    else
        std.fmt.bufPrint(buffer, "{d:.1} MB", .{value / (1024 * 1024)})) catch "";
}

// Grey squares under an image, so its see-through parts show as see-through.
fn drawCheckerboard(_: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const square: f32 = 8;
    try c.rect(r, .{ 0.8, 0.8, 0.8 });
    var y: f32 = 0;
    var row: usize = 0;
    while (y < r.h) : ({
        y += square;
        row += 1;
    }) {
        var x: f32 = if (row % 2 == 0) 0 else square;
        while (x < r.w) : (x += 2 * square) {
            try c.rect(.{ .x = r.x + x, .y = r.y + y, .w = @min(square, r.w - x), .h = @min(square, r.h - y) }, .{ 0.6, 0.6, 0.6 });
        }
    }
}

// Keep where the UI scene's placeholder was laid out, for the next frame.
fn recordArea(context: *const anyopaque, _: *ui.Canvas, rect: ui.Rect) anyerror!void {
    const area: *ui.Rect = @ptrCast(@alignCast(@constCast(context)));
    area.* = rect;
}

test "text is told from binary, and a cut-off character still reads as text" {
    try std.testing.expect(readsAsText(".{ .name = \"caf\xc3\xa9\" }"));
    try std.testing.expect(!readsAsText("\x89PNG\r\n\x1a\n\x00\x00"));
    try std.testing.expect(readsAsText("caf\xc3"));
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("8.0 KB", sizeText(&buffer, 8192));
    try std.testing.expectEqualStrings("12 bytes", sizeText(&buffer, 12));
}
