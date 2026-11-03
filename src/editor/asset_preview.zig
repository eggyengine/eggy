//! The Asset Preview panel: the file selected in Assets, shown as itself on a stage between a
//! header (its kind, name, and buttons to keep it in a tab or find it in Assets) and a status
//! bar (what it is and where). Images fit the stage over a backdrop, zoom and pan, and can be cut
//! into a sprite sheet's numbered frames to play; UI scenes are drawn as the game draws them;
//! fonts show a sample to type; files that read as text show in a terminal view. Models turn in a
//! viewer (`model_preview.zig`) and sounds play from their waveform (`sound_preview.zig`). It
//! reads the file again when it changes.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ui_scenes = eggy.ui_scenes;
const ProjectAssets = @import("assets/project_assets.zig").ProjectAssets;
const Icons = @import("assets/icons.zig").Icons;
const Icon = @import("assets/icons.zig").Icon;
const listing = @import("assets/listing.zig");
const TerminalView = @import("terminal_view.zig").TerminalView;
const ModelPreview = @import("model_preview.zig").ModelPreview;
const ModelRequest = @import("model_preview.zig").Request;
const SoundPreview = @import("sound_preview.zig").SoundPreview;
const page_style = @import("page_style.zig");

/// The most of a text file shown.
const max_text_bytes = 256 * 1024;
const video_extensions = [_][]const u8{ ".mp4", ".webm", ".mov", ".mkv", ".avi", ".ogv" };

/// The panel's bars, in logical points; the stage takes what they leave.
const header_height: f32 = 30;
const toolbar_height: f32 = 30;
const status_height: f32 = 20;
const bar_gap: f32 = 6;

const pin_glyph = "\u{f08d}";
const reveal_glyph = "\u{f07c}";
const edit_glyph = "\u{f040}";
const play_glyph = "\u{f04b}";
const pause_glyph = "\u{f04c}";

/// What the panel shows of the file selected.
const Shown = union(enum) {
    image: []const u8,
    ui_scene: []const u8,
    /// A font, by asset key: a sample of text in it.
    font: []const u8,
    /// A sound, by asset key: its waveform, to play.
    sound: []const u8,
    /// A model file (its own, or the one a selected part is in), playing `clip` if one was picked.
    model: struct { path: []const u8, clip: ?[]const u8 = null },
    text,
    /// A file it can't show, described.
    described: []const u8,
};

/// What `build` reads from, borrowed for the call.
pub const Request = struct {
    /// The Assets panel's selection: a project path, and whether it is inside a model.
    selection: ?struct { path: []const u8, virtual: bool },
    /// Whether this preview is a tab of the file's own, so it needn't offer to keep it in one.
    kept: bool = false,
    assets: *ProjectAssets,
    icons: *const Icons,
    project_dir: []const u8,
    app: *eggy.App,
    time_ms: u64,
};

/// What the panel asks the editor to do; paths borrow the request's selection.
pub const Action = union(enum) {
    /// Show the file in an Asset Preview tab of its own.
    keep_in_tab: []const u8,
    /// Select the file in Assets and bring Assets forward.
    show_in_assets: struct { path: []const u8, virtual: bool },
    /// Open the file in the code editor people chose.
    edit: []const u8,
};

/// How large the image is drawn: to fit the stage, or at a whole multiple of its pixels.
const Zoom = enum(usize) { fit, x1, x2, x4 };
/// What shows through an image's see-through parts.
const Backdrop = enum { checker, dark, light };

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
    sound: SoundPreview = .{},
    /// How the image is drawn: its zoom, backdrop and how far it is dragged from the middle.
    zoom: usize = @backingInt(Zoom.fit),
    backdrop: Backdrop = .checker,
    pan: ui.Vec2 = .zero,
    /// Where the image's stage was laid out last frame (zero: no image shown), and where the
    /// pointer was last while dragging it.
    image_stage: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    panning: ?ui.Vec2 = null,
    /// The grid an image is cut into, when it is shown as a sprite sheet, and its frames playing.
    sheet: Sheet = .{},
    /// What a font's sample says.
    sample: SampleEdit = SampleEdit.init("The quick brown fox") catch unreachable,

    const SampleEdit = ui.TextEdit(64);

    const Sheet = struct {
        shown: bool = false,
        columns: u16 = 1,
        rows: u16 = 1,
        /// The frame lit, counted as a `SpriteAnimator` counts them, and whether they play.
        frame: u16 = 0,
        playing: bool = false,
        fps: u16 = 12,
        /// When play started, and from which frame.
        started_ms: u64 = 0,
        started_frame: u16 = 0,

        fn count(self: Sheet) u16 {
            return self.columns * self.rows;
        }

        /// The frame lit at `time_ms`.
        fn frameAt(self: Sheet, time_ms: u64) u16 {
            if (!self.playing) return @min(self.frame, self.count() - 1);
            const elapsed: u64 = (time_ms -| self.started_ms) * self.fps / 1000;
            return @intCast((self.started_frame + elapsed) % self.count());
        }
    };

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

    /// An event over the panel: the model turns, the image pans and zooms, the text view scrolls,
    /// selects and copies. Returns whether it was used.
    pub fn handle(self: *AssetPreview, event: ui.input.Event) bool {
        if (self.model.handle(event)) return true;
        if (self.handleImage(event)) return true;
        if (self.contents.items.len == 0) return false;
        return self.text.handle(event);
    }

    /// Drag the image to move it, scroll to zoom it, double-click to fit it again.
    fn handleImage(self: *AssetPreview, event: ui.input.Event) bool {
        const area = self.image_stage;
        if (area.w <= 0) return false;
        switch (event) {
            .pointer_down => |down| {
                if (down.button != .left or !area.contains(down.position.x, down.position.y)) return false;
                if (down.clicks >= 2) {
                    self.zoom = @backingInt(Zoom.fit);
                    self.pan = .zero;
                }
                self.panning = down.position;
                return true;
            },
            .pointer_move => |at| {
                const from = self.panning orelse return false;
                self.pan = .init(self.pan.x + at.x - from.x, self.pan.y + at.y - from.y);
                self.panning = at;
                return true;
            },
            .pointer_up => {
                const was_panning = self.panning != null;
                self.panning = null;
                return was_panning;
            },
            .wheel => |wheel| {
                if (!area.contains(wheel.position.x, wheel.position.y)) return false;
                const last = @typeInfo(Zoom).@"enum".field_names.len - 1;
                self.zoom = if (wheel.delta.y > 0) @min(last, self.zoom + 1) else self.zoom -| 1;
                return true;
            },
            else => return false,
        }
    }

    /// Draw the selected file, or that none is. Returns what the header's buttons asked for.
    pub fn build(self: *AssetPreview, context: *ui.Context, request: Request) ?Action {
        self.model.shown = false;
        self.image_stage = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const selection = request.selection orelse {
            self.sound.stop(request.app);
            return emptyState(context, request.icons);
        };
        const path = selection.path;
        const arena = context.builder().allocator;
        if (!selection.virtual) self.refresh(request.project_dir, path);
        const shown = if (selection.virtual) self.partOf(arena, request.assets, path) else self.kindOf(arena, request.assets, path);
        // What plays stops once another file shows.
        if (shown != .sound) self.sound.stop(request.app);

        var action: ?Action = null;
        context.begin(.column);
        if (header(context, request, path, selection.virtual, shown)) |asked| action = asked;
        const bars = self.toolbars(context, request, shown);
        const stage_height = @max(80, page_style.pageHeight(context) - header_height - status_height - @as(f32, @floatFromInt(bars)) * (toolbar_height + bar_gap) - 2 * bar_gap);
        self.stage(context, request, shown, path, stage_height);
        statusBar(context, if (selection.virtual) partNote(arena, path) else self.details(context, request, shown, path), path);
        context.end();
        page_style.restyle(context, .{ .grow = 1, .gap = bar_gap });
        return action;
    }

    /// The bars above the stage that `shown` has (an image's zoom and sheet, a font's sample),
    /// returning how many.
    fn toolbars(self: *AssetPreview, context: *ui.Context, request: Request, shown: Shown) usize {
        switch (shown) {
            .image => |key| {
                const loaded = self.images.get(request.app.resources(), context.font, key) orelse return 0;
                self.imageToolbar(context);
                if (!self.sheet.shown) return 1;
                self.sheetToolbar(context, loaded);
                return 2;
            },
            .font => {
                _ = context.textInput("##font sample", &self.sample, "Sample text");
                page_style.restyle(context, .{ .height = toolbar_height });
                return 1;
            },
            else => return 0,
        }
    }

    /// Zoom, the backdrop, and the switch that cuts the image into a sprite sheet.
    fn imageToolbar(self: *AssetPreview, context: *ui.Context) void {
        context.begin(.row);
        if (context.tabs(&.{ "Fit##image zoom", "1\u{d7}##image zoom", "2\u{d7}##image zoom", "4\u{d7}##image zoom" }, &self.zoom)) self.pan = .zero;
        inline for (comptime std.enums.values(Backdrop)) |backdrop| {
            if (backdropButton(context, backdrop, self.backdrop == backdrop)) self.backdrop = backdrop;
        }
        page_style.spacer(context);
        if (context.toggle("Sprite sheet", &self.sheet.shown) and !self.sheet.shown) self.sheet.playing = false;
        page_style.endRow(context);
        page_style.restyle(context, .{ .height = toolbar_height });
    }

    /// How many frames across and down, and how large each one is.
    fn sheetToolbar(self: *AssetPreview, context: *ui.Context, loaded: *const ui.Image) void {
        const before = self.sheet.count();
        context.begin(.row);
        stepper(context, "Columns", &self.sheet.columns, 256);
        stepper(context, "Rows", &self.sheet.rows, 256);
        page_style.spacer(context);
        context.muted(std.fmt.allocPrint(context.builder().allocator, "{d} \u{d7} {d} each", .{ loaded.width / self.sheet.columns, loaded.height / self.sheet.rows }) catch "");
        page_style.smallText(context, 11);
        page_style.endRow(context);
        page_style.restyle(context, .{ .height = toolbar_height });
        if (self.sheet.count() != before) self.sheet.frame = 0;
    }

    /// The file itself, in `height` points under the bars.
    fn stage(self: *AssetPreview, context: *ui.Context, request: Request, shown: Shown, path: []const u8, height: f32) void {
        switch (shown) {
            .image => |key| self.image(context, request, key, height),
            .ui_scene => |key| self.uiScene(context, request, key, height),
            .font => |key| self.fontSample(context, request, key, height),
            .sound => |key| self.sound.build(self.gpa, context, .{ .key = key, .version = self.version, .app = request.app, .height = height }),
            .model => |model| self.model.build(context, .{ .path = model.path, .clip = model.clip, .assets = request.assets, .app = request.app, .images = &self.images, .time_ms = request.time_ms, .height = height }),
            .text => self.text.add(context, self.contents.items, self.version, height),
            .described => |note| centredNote(context, request.icons, iconOf(path), note, height),
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
        // A UI scene, image or model drawn from the old file is drawn from the new one, and
        // another file starts fitted, uncut.
        self.images.forgetAll();
        self.model.key_len = 0;
        if (!same_file) {
            self.zoom = @backingInt(Zoom.fit);
            self.pan = .zero;
            self.sheet = .{};
        }
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
        if (kind == .font and key.len > 0) return .{ .font = key };
        if (kind == .folder) return .{ .described = "A folder." };
        if (kind == .model) return .{ .model = .{ .path = path } };
        if (kind == .audio and key.len > 0) return .{ .sound = key };
        for (video_extensions) |video| if (std.ascii.eqlIgnoreCase(extension, video)) {
            return .{ .described = "Eggy can't play videos yet." };
        };
        if (self.contents.items.len > 0) return .text;
        return .{ .described = "This file isn't an image or text, so there is nothing to show of it." };
    }

    /// How the part of a model at `path` is shown: its geometry as the model, an animation
    /// playing on it, a material's texture as the image it is.
    fn partOf(self: *AssetPreview, arena: std.mem.Allocator, assets: *ProjectAssets, path: []const u8) Shown {
        const model_path = std.fs.path.dirname(path) orelse path;
        const reference = assets.referenceAt(path) orelse return .{ .described = "This part isn't in the project's assets yet." };
        switch (reference.kind) {
            .model => return .{ .model = .{ .path = model_path } },
            .animation => return .{ .model = .{ .path = model_path, .clip = std.fs.path.basename(path) } },
            .image => {
                // A texture is its own file to the cache: a new one starts fitted.
                if (!std.mem.eql(u8, self.path.items, path)) {
                    self.path.clearRetainingCapacity();
                    self.path.appendSlice(self.gpa, path) catch {};
                    self.images.forgetAll();
                    self.zoom = @backingInt(Zoom.fit);
                    self.pan = .zero;
                    self.sheet = .{};
                }
                return .{ .image = arena.dupe(u8, reference.key()) catch "" };
            },
            else => return .{ .described = "There is nothing to show of this part." },
        }
    }

    /// One line on the file: its kind and size, and what it holds where that is known.
    fn details(self: *AssetPreview, context: *ui.Context, request: Request, shown: Shown, path: []const u8) []const u8 {
        const arena = context.builder().allocator;
        const extension = std.fs.path.extension(path);
        const kind = std.ascii.allocUpperString(arena, if (extension.len > 1) extension[1..] else "file") catch "File";
        var size_buffer: [32]u8 = undefined;
        const size = sizeText(&size_buffer, self.size);
        switch (shown) {
            .image => |key| if (self.images.get(request.app.resources(), context.font, key)) |loaded| {
                const frames = loaded.frames.len;
                const animated = if (frames > 1) std.fmt.allocPrint(arena, " \u{b7} {d} frames", .{frames}) catch "" else "";
                return std.fmt.allocPrint(arena, "{s} \u{b7} {d} \u{d7} {d}{s} \u{b7} {s}", .{ kind, loaded.width, loaded.height, animated, size }) catch size;
            },
            .sound => |key| if (self.sound.infoOf(self.gpa, .{ .key = key, .version = self.version, .app = request.app })) |info| {
                const layout = switch (info.channels) {
                    1 => "mono",
                    2 => "stereo",
                    else => std.fmt.allocPrint(arena, "{d} channels", .{info.channels}) catch "",
                };
                return std.fmt.allocPrint(arena, "{s} \u{b7} {d:.1} s \u{b7} {s} \u{b7} {d:.1} kHz \u{b7} {s}", .{ kind, info.duration_s, layout, @as(f32, @floatFromInt(info.sample_rate_hz)) / 1000, size }) catch size;
            },
            .model => if (self.model.counts()) |counts| {
                return std.fmt.allocPrint(arena, "{s} \u{b7} {d} triangles \u{b7} {d} clips \u{b7} {s}", .{ kind, counts.triangles, counts.clips, size }) catch size;
            },
            .text => {
                const lines = std.mem.count(u8, self.contents.items, "\n") + @intFromBool(self.contents.items.len > 0 and self.contents.items[self.contents.items.len - 1] != '\n');
                if (self.contents.items.len < self.size) return std.fmt.allocPrint(arena, "{s} \u{b7} {s} \u{b7} the first {d} KB shown", .{ kind, size, max_text_bytes / 1024 }) catch size;
                return std.fmt.allocPrint(arena, "{s} \u{b7} {d} lines \u{b7} {s}", .{ kind, lines, size }) catch size;
            },
            else => {},
        }
        return std.fmt.allocPrint(arena, "{s} \u{b7} {s}", .{ kind, size }) catch size;
    }

    /// The sample typed, the alphabet and a pangram in the font with `key`, each beside its size.
    fn fontSample(self: *AssetPreview, context: *ui.Context, request: Request, key: []const u8, height: f32) void {
        const face = self.images.textFont(request.app.resources(), context.font, key) orelse {
            return centredNote(context, request.icons, .font, "This font couldn't be loaded: see the Console.", height);
        };
        const sample = context.builder().allocator.create(FontSample) catch return;
        const typed = if (self.sample.text().len > 0) self.sample.text() else "The quick brown fox";
        sample.* = .{ .face = face, .lines = .{
            .{ .text = typed, .size = 48 },
            .{ .text = typed, .size = 24 },
            .{ .text = "ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789 !?&", .size = 16 },
            .{ .text = "The quick brown fox jumps over the lazy dog", .size = 12 },
        } };
        context.element(context.builder().node(0, .{ .width = context.contentWidth(), .height = height }, .{ .custom = .{ .context = sample, .draw = drawFontSample } }, &.{}) catch return);
    }

    /// The image on its stage, at the zoom chosen and where it was dragged; as a sprite sheet,
    /// its grid over it and its frames to play under it.
    fn image(self: *AssetPreview, context: *ui.Context, request: Request, key: []const u8, height: f32) void {
        const loaded = self.images.get(request.app.resources(), context.font, key) orelse {
            return centredNote(context, request.icons, .image, "This image couldn't be loaded: see the Console.", height);
        };
        const frame_bar = self.sheet.shown and self.sheet.count() > 1;
        const stage_height = if (frame_bar) height - toolbar_height - bar_gap else height;
        const shown = context.builder().allocator.create(ImageStage) catch return;
        shown.* = .{
            .preview = self,
            .sprite = loaded.frameAt(request.time_ms),
            .size = .{ @floatFromInt(loaded.width), @floatFromInt(loaded.height) },
            .zoom = @fromBackingInt(@intCast(self.zoom)),
            .backdrop = self.backdrop,
            .sheet = if (self.sheet.shown) self.sheet else null,
            .lit = self.sheet.frameAt(request.time_ms),
        };
        const element = context.builder().node(0, .{ .width = context.contentWidth(), .height = stage_height }, .{ .custom = .{ .context = shown, .draw = drawImageStage } }, &.{}) catch return;
        element.accessibility = .{ .role = .image, .label = std.fs.path.basename(self.path.items) };
        element.cursor = .move;
        context.element(element);
        if (frame_bar) self.frameBar(context, request.time_ms);
    }

    /// Play and pause the sheet's frames, each frame to pick, and how fast they play.
    fn frameBar(self: *AssetPreview, context: *ui.Context, time_ms: u64) void {
        const sheet = &self.sheet;
        const lit = sheet.frameAt(time_ms);
        const b = context.builder();
        context.begin(.row);
        if (page_style.iconButton(context, if (sheet.playing) pause_glyph else play_glyph, if (sheet.playing) "Pause the frames" else "Play the frames", sheet.playing)) {
            sheet.frame = lit;
            sheet.started_frame = lit;
            sheet.started_ms = time_ms;
            sheet.playing = !sheet.playing;
        }
        // A chip per frame while they fit; past that, which frame of how many.
        const chip_width: f32 = 24;
        const room = context.contentWidth() - 26 - 140;
        if (@as(f32, @floatFromInt(sheet.count())) * (chip_width + 3) <= room) {
            for (0..sheet.count()) |index| {
                const label = std.fmt.allocPrint(b.allocator, "{d}", .{index}) catch continue;
                const id = context.idFor(std.fmt.allocPrint(b.allocator, "frame chip {d}", .{index}) catch continue);
                if (context.activated(id)) {
                    sheet.playing = false;
                    sheet.frame = @intCast(index);
                }
                const chip = b.node(id, .{ .width = chip_width, .height = 22, .align_items = .center, .justify = .center }, page_style.highlight(b.allocator, id, index == lit, false), &.{
                    b.node(0, .{}, .{ .text = .{ .value = label, .size = 10, .tone = if (index == lit) .foreground else .muted } }, &.{}) catch continue,
                }) catch continue;
                chip.cursor = .pointer;
                chip.accessibility = .{ .role = .button, .label = label };
                context.element(chip);
            }
        } else {
            context.muted(std.fmt.allocPrint(b.allocator, "Frame {d} of {d}", .{ lit, sheet.count() }) catch "");
            page_style.smallText(context, 11);
        }
        page_style.spacer(context);
        const fps_before = sheet.fps;
        stepper(context, "fps", &sheet.fps, 60);
        // A new speed carries on from the frame shown.
        if (sheet.fps != fps_before and sheet.playing) {
            sheet.started_frame = lit;
            sheet.started_ms = time_ms;
        }
        page_style.endRow(context);
        page_style.restyle(context, .{ .height = toolbar_height, .gap = 3 });
    }

    /// The UI scene drawn across the stage as a screen of its design size would show it.
    fn uiScene(self: *AssetPreview, context: *ui.Context, request: Request, key: []const u8, height: f32) void {
        const state = &request.app.ui_scenes;
        const resources = request.app.resources();
        const scene = state.sceneCache().get(resources, key) orelse {
            return centredNote(context, request.icons, .ui, "This UI scene couldn't be read: see the Console.", height);
        };
        const fit = @min(context.contentWidth() / scene.design_size[0], height / scene.design_size[1]);
        const size = [2]f32{ scene.design_size[0] * fit, scene.design_size[1] * fit };
        const b = context.builder();
        const placeholder = b.node(0, .{ .width = size[0], .height = size[1] }, .{ .custom = .{ .context = &self.scene_area, .draw = recordArea } }, &.{}) catch return;
        context.element(b.node(0, .{ .width = context.contentWidth(), .height = height, .align_items = .center, .justify = .center }, .none, &.{placeholder}) catch return);
        if (self.scene_area.w <= 0) return;
        // Drawn where its placeholder was laid out last frame: a frame late when the panel moves.
        const area = ui.Rect{ .x = self.scene_area.x, .y = self.scene_area.y, .w = size[0], .h = size[1] };
        const backdrop = b.node(0, .{ .width = area.w, .height = area.h }, .{ .surface = .track }, &.{}) catch return;
        backdrop.overlay = .{ .point = .init(area.x, area.y) };
        context.element(backdrop);
        _ = ui_scenes.scene_ui.build(context, state, resources, &self.images, scene, .{ .id = std.math.maxInt(u32), .generation = 0 }, .{ .viewport = area, .scale = scene.scaling.scale(scene.design_size, .{ area.w, area.h }), .z_index = 1, .interactive = false, .clip = area }, request.time_ms) catch |err| {
            std.log.err("cannot preview the UI scene: {t}", .{err});
        };
    }
};

/// The header: the file's kind and name, Edit for text, and buttons to keep it in a tab and to
/// find it in Assets. Returns what was pressed.
fn header(context: *ui.Context, request: Request, path: []const u8, virtual: bool, shown: Shown) ?Action {
    var action: ?Action = null;
    const b = context.builder();
    const icon: Icon = switch (shown) {
        .model => |model| if (model.clip != null) .clip else .model,
        .image => .image,
        else => iconOf(path),
    };
    context.begin(.row);
    context.element(b.node(0, .{ .width = 22, .height = 22, .align_items = .center, .justify = .center }, .{ .custom = .{ .context = context, .draw = drawIconTile } }, &.{
        b.node(0, .{ .width = 14, .height = 14 }, request.icons.paint(icon, context.theme), &.{}) catch return null,
    }) catch return null);
    // The name takes what the tile and buttons leave, cut short to fit.
    const editable = shown == .text and !virtual;
    const keepable = !request.kept and !virtual;
    // The tile, name, spacer and Show in Assets, then Edit and Keep when offered, 8 apart.
    const edit_width = @max(48, context.font.measure(edit_glyph ++ "  Edit", 12) + 16);
    const others: f32 = 22 + 26 + 3 * 8 + (if (keepable) @as(f32, 26 + 8) else 0) + (if (editable) edit_width + 8 else 0);
    context.text(page_style.fitText(b.allocator, context.font, std.fs.path.basename(path), 13, @max(24, context.contentWidth() - others)));
    page_style.smallText(context, 13);
    page_style.spacer(context);
    if (editable and context.buttonVariant(edit_glyph ++ "  Edit##preview edit", .outline)) action = .{ .edit = path };
    if (keepable and page_style.iconButton(context, pin_glyph, "Keep in a tab of its own", false)) action = .{ .keep_in_tab = path };
    if (page_style.iconButton(context, reveal_glyph, "Show in Assets", false)) action = .{ .show_in_assets = .{ .path = path, .virtual = virtual } };
    page_style.endRow(context);
    page_style.restyle(context, .{ .height = header_height });
    return action;
}

/// The status bar: what the file is on the left, its path on the right, cut to fit.
fn statusBar(context: *ui.Context, what: []const u8, path: []const u8) void {
    const b = context.builder();
    const width = context.contentWidth();
    const what_width = context.font.measure(what, 11);
    // Inside its padding (8 a side) and the two 12-point gaps around the spacer.
    const room = @max(0, width - what_width - 16 - 24);
    const shown_path = page_style.fitText(b.allocator, context.font, path, 11, room);
    context.element(b.node(0, .{ .width = width, .height = status_height, .direction = .row, .align_items = .center, .gap = 12, .padding = .{ .left = 8, .right = 8 } }, .{ .custom = .{ .context = context, .draw = drawStatusBar } }, &.{
        b.node(0, .{}, .{ .text = .{ .value = what, .size = 11, .tone = .muted } }, &.{}) catch return,
        b.node(0, .{ .grow = 1 }, .none, &.{}) catch return,
        b.node(0, .{}, .{ .text = .{ .value = shown_path, .size = 11, .tone = .muted } }, &.{}) catch return,
    }) catch return);
}

/// The panel with nothing selected: a file's outline over that state, in the middle.
fn emptyState(context: *ui.Context, icons: *const Icons) ?Action {
    centredNote(context, icons, .file, "No file selected", page_style.pageHeight(context));
    return null;
}

/// `icon` large over `note`, in the middle of `height` points.
fn centredNote(context: *ui.Context, icons: *const Icons, icon: Icon, note: []const u8, height: f32) void {
    const b = context.builder();
    const width = context.contentWidth();
    const text = b.node(0, .{ .max_width = @min(width, 320) }, .{ .text = .{ .value = note, .size = 12, .tone = .muted, .wrap = true, .alignment = .center } }, &.{}) catch return;
    context.element(b.node(0, .{ .width = width, .height = height, .align_items = .center, .justify = .center, .gap = 12 }, .none, &.{
        b.node(0, .{ .width = 40, .height = 40 }, icons.paint(icon, context.theme), &.{}) catch return,
        text,
    }) catch return);
}

/// The Assets icon for the file at `path`.
fn iconOf(path: []const u8) Icon {
    if (eggy.assets.Kind.of(path) == .folder) return .folder;
    return Icon.of(listing.Kind.ofFile(std.fs.path.basename(path)));
}

/// What the status bar says of a part of a model.
fn partNote(arena: std.mem.Allocator, path: []const u8) []const u8 {
    const model_path = std.fs.path.dirname(path) orelse path;
    return std.fmt.allocPrint(arena, "Part of {s}", .{std.fs.path.basename(model_path)}) catch "Part of a model";
}

/// A swatch of `backdrop` that chooses it, ringed while `chosen`.
fn backdropButton(context: *ui.Context, comptime backdrop: Backdrop, chosen: bool) bool {
    const label = switch (backdrop) {
        .checker => "Checkerboard behind the image",
        .dark => "Dark behind the image",
        .light => "Light behind the image",
    };
    const b = context.builder();
    const id = context.idFor(label);
    const look = b.allocator.create(Swatch) catch return false;
    look.* = .{ .backdrop = backdrop, .chosen = chosen };
    const swatch = b.node(id, .{ .width = 22, .height = 22 }, .{ .custom = .{ .context = look, .draw = Swatch.draw } }, &.{}) catch return false;
    swatch.cursor = .pointer;
    swatch.accessibility = .{ .role = .radio, .label = label };
    context.element(swatch);
    context.tooltip(label);
    return context.activated(id);
}

const Swatch = struct {
    backdrop: Backdrop,
    chosen: bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Swatch = @ptrCast(@alignCast(context));
        const inner = ui.Rect{ .x = r.x + 3, .y = r.y + 3, .w = r.w - 6, .h = r.h - 6 };
        try drawBackdrop(c, inner, self.backdrop, 4);
        try c.roundRectStroke(r, if (self.chosen) c.theme.primary else c.theme.input, c.theme.radiusSm(), if (self.chosen) 2 else 1);
    }
};

/// `backdrop` over `r`, checkered in squares of `square` points.
fn drawBackdrop(c: *ui.Canvas, r: ui.Rect, backdrop: Backdrop, square: f32) !void {
    switch (backdrop) {
        .dark => return c.rect(r, .{ 0.04, 0.04, 0.035 }),
        .light => return c.rect(r, .{ 0.96, 0.95, 0.93 }),
        .checker => {},
    }
    try c.rect(r, .{ 0.72, 0.72, 0.72 });
    var y: f32 = 0;
    var row: usize = 0;
    while (y < r.h) : ({
        y += square;
        row += 1;
    }) {
        var x: f32 = if (row % 2 == 0) 0 else square;
        while (x < r.w) : (x += 2 * square) {
            try c.rect(.{ .x = r.x + x, .y = r.y + y, .w = @min(square, r.w - x), .h = @min(square, r.h - y) }, .{ 0.54, 0.54, 0.54 });
        }
    }
}

/// What `drawImageStage` draws, for one frame.
const ImageStage = struct {
    /// Where the stage was laid out goes back here, for dragging and scrolling over it.
    preview: *AssetPreview,
    sprite: ui.Glyph,
    size: [2]f32,
    zoom: Zoom,
    backdrop: Backdrop,
    sheet: ?AssetPreview.Sheet,
    lit: u16,
};

/// How many points each of an image's pixels takes at `zoom` on a stage of `stage` points:
/// fitting shrinks a large image and enlarges a small one by whole multiples, keeping pixel art
/// crisp.
fn imageScale(zoom: Zoom, size: [2]f32, stage: [2]f32) f32 {
    return switch (zoom) {
        .fit => blk: {
            const fit = @min(stage[0] / size[0], stage[1] / size[1]);
            break :blk if (fit > 1) @floor(fit) else fit;
        },
        .x1 => 1,
        .x2 => 2,
        .x4 => 4,
    };
}

/// How far an image `drawn` points wide can be dragged on a stage `stage` points wide: none
/// when it fits, else until its edge meets the stage's.
fn clampPan(pan: f32, drawn: f32, stage: f32) f32 {
    const slack = @max(0, (drawn - stage) / 2);
    return std.math.clamp(pan, -slack, slack);
}

// The stage darkened, the image centred on its backdrop at its zoom and pan and clipped to the
// stage, and a sprite sheet's grid over it with its lit frame marked.
fn drawImageStage(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const shown: *const ImageStage = @ptrCast(@alignCast(context));
    const preview = shown.preview;
    preview.image_stage = r;
    try c.roundRectAlpha(r, .{ 0, 0, 0 }, c.theme.radiusSm(), 0.22);

    const scale = imageScale(shown.zoom, shown.size, .{ r.w, r.h });
    const w = shown.size[0] * scale;
    const h = shown.size[1] * scale;
    preview.pan = .init(clampPan(preview.pan.x, w, r.w), clampPan(preview.pan.y, h, r.h));
    const picture = ui.Rect{ .x = r.x + (r.w - w) / 2 + preview.pan.x, .y = r.y + (r.h - h) / 2 + preview.pan.y, .w = w, .h = h };

    const outer_clip = c.clip;
    defer c.clip = outer_clip;
    c.clip = if (outer_clip) |clip| clip.intersection(r) else r;
    try drawBackdrop(c, picture, shown.backdrop, 8);
    try c.image(picture, shown.sprite, 1);
    if (shown.sheet) |sheet| try drawSheetGrid(c, picture, sheet, shown.lit);
}

/// The sheet's grid over the image at `r`, `lit` filled faintly and ringed, each frame numbered
/// in its top-left corner where the numbers fit.
fn drawSheetGrid(c: *ui.Canvas, r: ui.Rect, sheet: AssetPreview.Sheet, lit: u16) !void {
    const columns: f32 = @floatFromInt(sheet.columns);
    const rows: f32 = @floatFromInt(sheet.rows);
    const cell_w = r.w / columns;
    const cell_h = r.h / rows;
    for (1..sheet.columns) |i| try c.rectAlpha(.{ .x = r.x + cell_w * @as(f32, @floatFromInt(i)), .y = r.y, .w = 1, .h = r.h }, c.theme.primary, 0.85);
    for (1..sheet.rows) |i| try c.rectAlpha(.{ .x = r.x, .y = r.y + cell_h * @as(f32, @floatFromInt(i)), .w = r.w, .h = 1 }, c.theme.primary, 0.85);
    const lit_cell = ui.Rect{ .x = r.x + cell_w * @as(f32, @floatFromInt(lit % sheet.columns)), .y = r.y + cell_h * @as(f32, @floatFromInt(lit / sheet.columns)), .w = cell_w, .h = cell_h };
    try c.rectAlpha(lit_cell, c.theme.primary, 0.14);
    try c.roundRectStroke(lit_cell, c.theme.primary, 0, 2);
    if (cell_w < 16 or cell_h < 14) return;
    var buffer: [8]u8 = undefined;
    for (0..sheet.rows) |row| for (0..sheet.columns) |column| {
        const index = row * sheet.columns + column;
        const label = std.fmt.bufPrint(&buffer, "{d}", .{index}) catch continue;
        const x = r.x + cell_w * @as(f32, @floatFromInt(column)) + 2;
        const y = r.y + cell_h * @as(f32, @floatFromInt(row)) + 2;
        const chip = ui.Rect{ .x = x, .y = y, .w = c.font.measure(label, 10) + 6, .h = 13 };
        if (index == lit) {
            try c.roundRect(chip, c.theme.primary, 3);
            try c.text(x + 3, y + 1, label, 10, c.theme.primary_foreground);
        } else {
            try c.roundRectAlpha(chip, .{ 0, 0, 0 }, 3, 0.6);
            try c.text(x + 3, y + 1, label, 10, .{ 1, 1, 1 });
        }
    };
}

/// What a font's stage shows: lines of text in `face`, largest first.
const FontSample = struct {
    face: *const ui.Font,
    lines: [4]struct { text: []const u8, size: f32 },
};
const font_sample_gap: f32 = 14;
const font_size_column: f32 = 26;

// Each line beside its size in the panel's font, wrapped to the stage, one under the next.
fn drawFontSample(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    const sample: *const FontSample = @ptrCast(@alignCast(context));
    try c.roundRectAlpha(r, .{ 0, 0, 0 }, c.theme.radiusSm(), 0.22);
    const panel_font = c.font;
    defer c.font = panel_font;
    const text_x = r.x + 12 + font_size_column;
    const text_w = @max(1, r.w - 24 - font_size_column);
    var y = r.y + 16;
    var size_buffer: [4]u8 = undefined;
    for (sample.lines) |line| {
        c.font = sample.face;
        const height = sample.face.wrappedHeight(line.text, line.size, text_w);
        if (y + height > r.y + r.h) break;
        try c.textWrappedIn(.{ .x = text_x, .y = y, .w = text_w, .h = height }, line.text, line.size, c.theme.foreground);
        c.font = panel_font;
        const label = std.fmt.bufPrint(&size_buffer, "{d}", .{@as(u32, @intFromFloat(line.size))}) catch "";
        try c.text(r.x + 12, y + 2, label, 10, c.theme.muted_foreground);
        y += height + font_sample_gap;
    }
}

// The kind's tile behind the header's icon.
fn drawIconTile(_: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    try c.roundRect(r, c.theme.accent, c.theme.radiusSm());
}

// The status bar's ground: the card colour with a line along its top.
fn drawStatusBar(_: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
    try c.roundRect(r, c.theme.card, c.theme.radiusSm());
    try c.roundRectStroke(r, c.theme.border, c.theme.radiusSm(), 1);
}

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

/// `label` and its value, between buttons taking one from and adding one to it (1 to `max`).
fn stepper(context: *ui.Context, comptime label: []const u8, value: *u16, max: u16) void {
    context.muted(label);
    page_style.smallText(context, 12);
    if (page_style.iconButton(context, "\u{f068}", "Fewer " ++ label, false)) value.* = @max(1, value.* - 1);
    context.text(std.fmt.allocPrint(context.builder().allocator, "{d}", .{value.*}) catch "");
    page_style.smallText(context, 12);
    if (page_style.iconButton(context, "\u{f067}", "More " ++ label, false)) value.* = @min(max, value.* + 1);
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

test "fitting enlarges small images by whole multiples and shrinks large ones to fit" {
    try std.testing.expectEqual(@as(f32, 4), imageScale(.fit, .{ 32, 32 }, .{ 150, 140 }));
    try std.testing.expectEqual(@as(f32, 0.5), imageScale(.fit, .{ 400, 200 }, .{ 200, 300 }));
    try std.testing.expectEqual(@as(f32, 2), imageScale(.x2, .{ 400, 200 }, .{ 200, 300 }));
}

test "an image drags only as far as its edges, and not at all when it fits" {
    try std.testing.expectEqual(@as(f32, 0), clampPan(30, 100, 200));
    try std.testing.expectEqual(@as(f32, 50), clampPan(80, 300, 200));
    try std.testing.expectEqual(@as(f32, -50), clampPan(-80, 300, 200));
}

test "a playing sheet steps through its frames at its speed and wraps" {
    const sheet: AssetPreview.Sheet = .{ .columns = 3, .rows = 2, .playing = true, .fps = 10, .started_ms = 1000, .started_frame = 4 };
    try std.testing.expectEqual(@as(u16, 4), sheet.frameAt(1000));
    try std.testing.expectEqual(@as(u16, 5), sheet.frameAt(1100));
    try std.testing.expectEqual(@as(u16, 0), sheet.frameAt(1200));
    const paused: AssetPreview.Sheet = .{ .columns = 2, .rows = 1, .frame = 7 };
    try std.testing.expectEqual(@as(u16, 1), paused.frameAt(0));
}

test "the empty, text and can't-show states fit a narrow dock, and the header offers what fits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try @import("assets/project_fixtures.zig").Fixture.open(gpa, io);
    defer fixture.close(gpa, io);
    try fixture.dir.writeFile(io, .{ .sub_path = "a_script_with_a_long_name_that_keeps_going.zig", .data = "const a = 1;\nconst b = 2;\n" });
    try fixture.dir.writeFile(io, .{ .sub_path = "intro.mp4", .data = "\x00\x00\x00\x18ftypmp42" });
    var assets = try ProjectAssets.init(gpa, io, fixture.path);
    defer assets.deinit();

    var context = try ui.Context.init(gpa);
    defer context.deinit();
    // As the editor's pages are.
    context.density = .compact;
    var icons = Icons.load(gpa, context.font);
    defer icons.deinit(gpa);
    var preview = AssetPreview.init(gpa, context.font);
    defer preview.deinit();
    // Nothing here plays or loads through the app, so none is needed.
    var app: eggy.App = undefined;
    const paths = [_]?[]const u8{ null, "a_script_with_a_long_name_that_keeps_going.zig", "intro.mp4" };
    for (paths) |path| for ([_]f32{ 240, 360, 720 }) |width| {
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = width, .h = 520 };
        context.newFrame(viewport);
        const selection: @FieldType(Request, "selection") = if (path) |found| .{ .path = found, .virtual = false } else null;
        _ = preview.build(&context, .{ .selection = selection, .assets = &assets, .icons = &icons, .project_dir = fixture.path, .app = &app, .time_ms = 0 });
        _ = try context.render();
        try @import("ui_checks.zig").expectFits(context.last_root.?, context.font, viewport);
    };
    // The video held no text; the script reads as its two lines, which Edit is offered for.
    try std.testing.expectEqual(@as(usize, 0), preview.contents.items.len);
    context.newFrame(.{ .x = 0, .y = 0, .w = 360, .h = 520 });
    _ = preview.build(&context, .{ .selection = .{ .path = paths[1].?, .virtual = false }, .assets = &assets, .icons = &icons, .project_dir = fixture.path, .app = &app, .time_ms = 0 });
    _ = try context.render();
    try std.testing.expectEqualStrings("const a = 1;\nconst b = 2;\n", preview.contents.items);
}
