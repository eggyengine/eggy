//! The graph editor: one open animation graph (`.graph.zon`) in the Animation Graph panel, its
//! layers and parameters on the left, a layer's state machine on a canvas in the middle, and
//! the settings of what is selected on the right. Every edit is
//! written to the file once it settles (a node let go) and recorded in History as the file's
//! text before and after; running graphs load the new version.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const format = eggy.assets.animation_graph;
const ProjectAssets = @import("../assets/project_assets.zig").ProjectAssets;
const History = @import("../history.zig").History;
const page_style = @import("../page_style.zig");
const Document = @import("document.zig").Document;
const Canvas = @import("canvas.zig").Canvas;
const outline = @import("outline.zig");
const details_zig = @import("details.zig");
const Details = details_zig.Details;

const key_len = eggy.assets.id.key_len;
const plus_glyph = "\u{f067}";
const toolbar_height: f32 = 48;
const outline_width: f32 = 220;
const details_width: f32 = 340;

/// What the panels work with, borrowed for one call.
pub const Env = struct {
    gpa: std.mem.Allocator,
    app: *eggy.App,
    assets: *ProjectAssets,
    project_dir: []const u8,
    history: *History,
    now_ms: u64,
};

pub const GraphEditor = struct {
    document: ?Document = null,
    canvas: Canvas = .{},
    details: ?Details = null,
    /// Edits not yet written: they wait while a node is dragged.
    dirty: bool = false,
    message: [200]u8 = undefined,
    message_len: usize = 0,

    pub fn deinit(self: *GraphEditor) void {
        if (self.document) |*document| document.deinit();
        if (self.details) |*details| details.deinit();
        self.* = .{};
    }

    /// Open the graph at `path` (project-relative), replacing the one open.
    pub fn open(self: *GraphEditor, env: Env, path: []const u8) !void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var project = try std.Io.Dir.cwd().openDir(io, env.project_dir, .{});
        defer project.close(io);
        const text = try project.readFileAlloc(io, path, env.gpa, .limited(4 * 1024 * 1024));
        defer env.gpa.free(text);
        var key_buffer: [key_len]u8 = undefined;
        const key = env.assets.keyOf(&key_buffer, path) orelse "";
        const document = try Document.init(env.gpa, path, key, text);
        if (self.document) |*old| old.deinit();
        self.document = document;
        self.canvas = .{};
        self.dirty = false;
        self.message_len = 0;
        if (self.details) |*details| details.forget();
    }

    /// Carry out an undo or redo of an edit to the graph at `path`: `text` becomes the file,
    /// and the open document shows it when it is that file.
    pub fn restore(self: *GraphEditor, env: Env, io: std.Io, project: std.Io.Dir, path: []const u8, text: []const u8) !void {
        try project.writeFile(io, .{ .sub_path = path, .data = text });
        var key_buffer: [key_len]u8 = undefined;
        if (env.assets.keyOf(&key_buffer, path)) |key| env.app.graphics.graphs.forget(key);
        if (self.document) |*document| if (std.mem.eql(u8, document.path, path)) {
            try document.replace(text);
            self.dirty = false;
            if (self.details) |*details| details.forget();
        };
    }

    /// A file moved from `from` to `to`: follow it when it is the open one.
    pub fn moved(self: *GraphEditor, from: []const u8, to: []const u8) void {
        const document = if (self.document) |*open_one| open_one else return;
        if (!std.mem.eql(u8, document.path, from)) return;
        const path = document.gpa.dupe(u8, to) catch return;
        document.gpa.free(document.path);
        document.path = path;
    }

    /// The file at `path` is gone: close it if it is the open one.
    pub fn deleted(self: *GraphEditor, path: []const u8) void {
        const document = if (self.document) |*open_one| open_one else return;
        if (!std.mem.eql(u8, document.path, path)) return;
        document.deinit();
        self.document = null;
    }

    /// The Animation Graph panel: the outline on the left, the toolbar and canvas in the middle,
    /// and the selection's details on the right.
    pub fn build(self: *GraphEditor, context: *ui.Context, env: Env) void {
        self.buildPanes(context, env) catch {};
        self.settle(env);
    }

    fn buildPanes(self: *GraphEditor, context: *ui.Context, env: Env) !void {
        const height = page_style.pageHeight(context);
        const width = context.contentWidth();
        context.begin(.row);
        if (self.document) |*document| {
            if (try outline.build(context, document, outline_width)) self.dirty = true;
            page_style.restyle(context, .{ .width = outline_width, .height = height });
        }

        context.begin(.column);
        try self.toolbar(context, env);
        if (self.message_len > 0) {
            context.muted(self.message[0..self.message_len]);
            page_style.smallText(context, 12);
        }
        if (self.document) |*document| {
            const message_height: f32 = if (self.message_len > 0) 20 else 0;
            try self.canvas.build(context, document, @max(120, height - toolbar_height - message_height));
        } else context.muted("No animation graph is open.");
        context.end();
        page_style.restyle(context, .{ .grow = 1, .gap = 8, .height = height });

        if (self.document) |*document| if (width > outline_width + details_width + 240) {
            if (self.details == null) self.details = .{ .gpa = env.gpa };
            const clips = clipChoices(context.builder().allocator, env.assets) catch details_zig.Clips{ .keys = &.{}, .names = &.{} };
            if (try self.details.?.build(context, document, clips, details_width)) self.dirty = true;
            page_style.restyle(context, .{ .width = details_width });
        };
        page_style.endRow(context);
        page_style.restyle(context, .{ .gap = 0, .width = width, .height = height, .align_items = .start });
    }

    fn toolbar(self: *GraphEditor, context: *ui.Context, env: Env) !void {
        const arena = context.builder().allocator;
        const graphs = env.assets.pathsOfKind(arena, .animation_graph) catch &.{};
        var chosen: usize = graphs.len;
        if (self.document) |*document| for (graphs, 0..) |path, i| if (std.mem.eql(u8, path, document.path)) {
            chosen = i;
        };
        var labels: std.ArrayList([]const u8) = .empty;
        try labels.appendSlice(arena, graphs);
        if (chosen == graphs.len) try labels.append(arena, if (self.document) |document| document.path else "Choose an animation graph");
        context.begin(.row);
        if (context.select("##graph file", labels.items, &chosen) and chosen < graphs.len) self.open(env, graphs[chosen]) catch |err| self.say("Couldn't open {s}: {t}", .{ graphs[chosen], err });
        page_style.restyle(context, .{ .grow = 1 });
        if (self.document) |*document| {
            const adds = [_]struct { label: []const u8, base: []const u8, motion: format.Motion }{
                .{ .label = plus_glyph ++ "  State##graph add clip state", .base = "State", .motion = .{ .clip = .{} } },
                .{ .label = plus_glyph ++ "  Blend##graph add blend 1d", .base = "Blend", .motion = .{ .blend_1d = .{} } },
                .{ .label = plus_glyph ++ "  Blend space##graph add blend 2d", .base = "Blend space", .motion = .{ .blend_2d = .{} } },
            };
            for (adds) |add| if (context.buttonVariant(add.label, .outline)) {
                document.addState(add.base, add.motion, self.canvas.middle()) catch |err| self.say("Couldn't add a state: {t}", .{err});
                self.dirty = true;
            };
        }
        page_style.endRow(context);
    }

    /// A pointer event over the Animation Graph panel, before its UI sees it. Returns whether it
    /// was used.
    pub fn canvasPointer(self: *GraphEditor, env: Env, event: ui.input.Event) bool {
        const document = if (self.document) |*open_one| open_one else return false;
        // The blend plot first: it sits over the details, beside the canvas.
        if (self.details) |*details| {
            const plotted = details.plotPointer(document, event);
            if (plotted.changed) self.dirty = true;
            if (plotted.used) {
                self.settle(env);
                return true;
            }
        }
        const result = self.canvas.pointer(document, event);
        if (result.changed) self.dirty = true;
        self.settle(env);
        return result.used;
    }

    /// A key over the Animation Graph panel: Delete removes the state or transition selected.
    /// Returns whether it was used.
    pub fn canvasKey(self: *GraphEditor, env: Env, key: @FieldType(ui.input.Event, "key_down"), typing: bool) bool {
        if (typing or (key.key != .delete and key.key != .backspace)) return false;
        const document = if (self.document) |*open_one| open_one else return false;
        switch (document.selection) {
            .state => |index| document.removeState(index) catch return false,
            .transition => |index| document.removeTransition(index) catch return false,
            .layer, .parameter => return false,
        }
        self.dirty = true;
        self.settle(env);
        return true;
    }

    /// Write the document's edits once nothing holds them.
    fn settle(self: *GraphEditor, env: Env) void {
        if (!self.dirty or self.canvas.holding()) return;
        if (self.details) |*details| if (details.holding()) return;
        self.dirty = false;
        if (self.document) |*document| self.commit(env, document);
    }

    /// Write the document's edits to its file and record them; one the format refuses goes back.
    fn commit(self: *GraphEditor, env: Env, document: *Document) void {
        const change = document.take() catch |err| {
            self.say("That change can't be kept ({t}); it was put back.", .{err});
            document.replace(document.saved) catch {};
            if (self.details) |*details| details.forget();
            return;
        } orelse return;
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const written = blk: {
            var project = std.Io.Dir.cwd().openDir(io, env.project_dir, .{}) catch |err| break :blk err;
            defer project.close(io);
            project.writeFile(io, .{ .sub_path = document.path, .data = change.after }) catch |err| break :blk err;
        };
        written catch |err| {
            self.say("Couldn't save {s}: {t}", .{ document.path, err });
            env.gpa.free(change.before);
            env.gpa.free(change.after);
            return;
        };
        env.app.graphics.graphs.forget(document.key());
        const path = env.gpa.dupe(u8, document.path) catch {
            env.gpa.free(change.before);
            env.gpa.free(change.after);
            return;
        };
        env.history.recordFileEdit(.animation_graph, path, change.before, change.after, env.now_ms);
        self.message_len = 0;
    }

    fn say(self: *GraphEditor, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.message, fmt, args) catch self.message[0..];
        self.message_len = written.len;
    }
};

/// The project's animation clips, by key and by what Assets calls them.
fn clipChoices(arena: std.mem.Allocator, assets: *ProjectAssets) !details_zig.Clips {
    const paths = try assets.pathsOfKind(arena, .animation);
    var keys: std.ArrayList([]const u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    for (paths) |path| {
        var buffer: [key_len]u8 = undefined;
        const key = assets.keyOf(&buffer, path) orelse continue;
        try keys.append(arena, try arena.dupe(u8, key));
        try names.append(arena, std.mem.trimStart(u8, path, "resources/"));
    }
    return .{ .keys = keys.items, .names = names.items };
}
