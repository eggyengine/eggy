//! The UI Designer: one open UI scene (`.ui.zon`) shown in three dock panels, the UI Designer
//! (the scene drawn at a chosen screen size, to pick and drag nodes in), the UI Tree (its nodes,
//! on the Hierarchy's page) and UI Properties (the selected node's settings, as the Inspector
//! draws them). Every edit is written to the file once it settles (a drag let go) and recorded
//! in History as the file's text before and after; the running game and billboards draw the new
//! version.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ui_scene = eggy.assets.ui_scene;
const ProjectAssets = @import("../assets/project_assets.zig").ProjectAssets;
const History = @import("../history.zig").History;
const Dragged = @import("../dragged.zig").Dragged;
const page_style = @import("../page_style.zig");
const Document = @import("document.zig").Document;
const preview_zig = @import("preview.zig");
const Preview = preview_zig.Preview;
const Tree = @import("tree.zig").Tree;
const Properties = @import("properties.zig").Properties;

const key_len = eggy.assets.id.key_len;

/// What the panels work with, borrowed for one call.
pub const Env = struct {
    gpa: std.mem.Allocator,
    app: *eggy.App,
    assets: *ProjectAssets,
    project_dir: []const u8,
    history: *History,
    /// The game's plugins' widgets, for Add and the properties.
    widgets: []const eggy.plugins.UiWidget,
    now_ms: u64,
};

pub const Designer = struct {
    document: ?Document = null,
    /// The panels' state, made when first drawn.
    preview: ?Preview = null,
    tree: ?Tree = null,
    properties: ?Properties = null,
    /// Edits not yet written: they wait while a drag or a scrub holds them.
    dirty: bool = false,
    /// Where the preview went in the last frame's layout, in the page's units.
    preview_area: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    message: [200]u8 = undefined,
    message_len: usize = 0,

    pub fn deinit(self: *Designer, gpa: std.mem.Allocator) void {
        _ = gpa;
        if (self.document) |*document| document.deinit();
        if (self.preview) |*preview| preview.deinit();
        if (self.tree) |*tree| tree.deinit();
        if (self.properties) |*properties| properties.deinit();
        self.* = .{};
    }

    /// Open the UI scene at `path` (project-relative), replacing the one open.
    pub fn open(self: *Designer, env: Env, path: []const u8) !void {
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
        self.dirty = false;
        self.message_len = 0;
    }

    /// Carry out an undo or redo of an edit to the UI scene at `path`: `text` becomes the file,
    /// and the open document shows it when it is that file.
    pub fn restore(self: *Designer, env: Env, io: std.Io, project: std.Io.Dir, path: []const u8, text: []const u8) !void {
        try project.writeFile(io, .{ .sub_path = path, .data = text });
        var key_buffer: [key_len]u8 = undefined;
        if (env.assets.keyOf(&key_buffer, path)) |key| env.app.ui_scenes.forget(key);
        if (self.document) |*document| if (std.mem.eql(u8, document.path, path)) {
            try document.replace(text);
            self.dirty = false;
        };
    }

    /// A file moved from `from` to `to`: follow it when it is the open one.
    pub fn moved(self: *Designer, from: []const u8, to: []const u8) void {
        const document = if (self.document) |*open_one| open_one else return;
        if (!std.mem.eql(u8, document.path, from)) return;
        const path = document.gpa.dupe(u8, to) catch return;
        document.gpa.free(document.path);
        document.path = path;
    }

    /// The project-relative path of the UI scene open, if one is; borrowed until it changes.
    pub fn openPath(self: *const Designer) ?[]const u8 {
        return if (self.document) |document| document.path else null;
    }

    /// Close the UI scene open, if one is, for another UI tab's. Its edits are on disk already:
    /// they wait only while a drag holds them, and a drag ends before the tab can change.
    pub fn close(self: *Designer) void {
        if (self.document) |*document| document.deinit();
        self.document = null;
        self.dirty = false;
    }

    /// The file at `path` is gone: close it if it is the open one.
    pub fn deleted(self: *Designer, path: []const u8) void {
        const document = if (self.document) |*open_one| open_one else return;
        if (!std.mem.eql(u8, document.path, path)) return;
        document.deinit();
        self.document = null;
    }

    /// The UI Designer panel: which scene, at which screen size, then the scene to pick and
    /// drag nodes in.
    pub fn buildPreview(self: *Designer, context: *ui.Context, env: Env) void {
        const arena = context.builder().allocator;
        if (self.preview == null) self.preview = .{ .images = .{ .gpa = env.gpa } };
        const preview = &self.preview.?;

        // The toolbar: the scene, the screen it is shown on, and the grid.
        const scenes = env.assets.pathsOfKind(arena, .ui) catch &.{};
        var chosen: usize = scenes.len;
        if (self.document) |*document| for (scenes, 0..) |path, i| if (std.mem.eql(u8, path, document.path)) {
            chosen = i;
        };
        var labels: std.ArrayList([]const u8) = .empty;
        labels.appendSlice(arena, scenes) catch {};
        if (chosen == scenes.len) labels.append(arena, if (self.document) |document| document.path else "Choose a UI scene") catch {};
        context.begin(.row);
        if (context.select("##ui scene file", labels.items, &chosen) and chosen < scenes.len) self.open(env, scenes[chosen]) catch |err| self.say("Couldn't open {s}: {t}", .{ scenes[chosen], err });
        page_style.restyle(context, .{ .grow = 1 });
        var screen_labels: [preview_zig.screens.len][]const u8 = undefined;
        for (preview_zig.screens, &screen_labels) |screen, *label| label.* = screen.label;
        _ = context.select("##ui preview screen", &screen_labels, &preview.screen);
        page_style.restyle(context, .{ .width = 190 });
        _ = context.toggle("Grid##ui preview grid", &preview.grid);
        context.tooltip("Lines every 10 design pixels; dragged nodes snap to them");
        page_style.endRow(context);
        if (self.message_len > 0) {
            context.muted(self.message[0..self.message_len]);
            page_style.smallText(context, 12);
        }

        const document = if (self.document) |*open_one| open_one else {
            context.muted("Double-click a UI scene in Assets, or make one with New > UI Scene. Show it over the game with a UiScreen component, or in the world with a UiBillboard.");
            if (context.last_added) |text| text.paint_kind.text.wrap = true;
            return;
        };

        // The scene, in what is left of the panel.
        const height = @max(120, page_style.pageHeight(context) - 44 - @as(f32, if (self.message_len > 0) 20 else 0));
        context.element(context.builder().node(0, .{ .grow = 1, .height = height }, .{ .custom = .{ .context = &self.preview_area, .draw = recordArea } }, &.{}) catch return);
        const outcome = preview.build(context, document, &env.app.ui_scenes, env.app.resources(), self.preview_area, env.now_ms);
        if (outcome.picked) |index| {
            var buffer: [ui_scene.max_depth]u16 = undefined;
            if (eggy.ui_scenes.layout.pathOf(&document.scene().root, index, &buffer)) |path| document.select(path);
        }
        if (outcome.moved) self.dirty = true;
        self.settle(env);
    }

    /// The UI Tree panel.
    pub fn buildTree(self: *Designer, context: *ui.Context, env: Env) void {
        const document = if (self.document) |*open_one| open_one else {
            context.muted("No UI scene is open. Double-click one in Assets.");
            page_style.smallText(context, 13);
            return;
        };
        if (self.tree == null) self.tree = .init(env.gpa);
        if (self.tree.?.build(context, document, env.widgets)) self.dirty = true;
        self.settle(env);
    }

    /// The UI Properties panel; `dragging` is what is being dragged from another panel.
    pub fn buildProperties(self: *Designer, context: *ui.Context, env: Env, dragging: ?Dragged) void {
        const document = if (self.document) |*open_one| open_one else {
            context.muted("Open a UI scene to see its nodes' properties.");
            page_style.smallText(context, 13);
            return;
        };
        if (self.properties == null) self.properties = .init(env.gpa);
        if (self.properties.?.build(context, document, .{ .widgets = env.widgets, .assets = env.assets, .dragging = dragging })) self.dirty = true;
        self.settle(env);
    }

    /// A pointer event over the UI Tree, before its UI sees it. Returns whether it was used.
    pub fn treePointer(self: *Designer, context: *const ui.Context, env: Env, event: ui.input.Event) bool {
        const document = if (self.document) |*open_one| open_one else return false;
        const tree = if (self.tree) |*made| made else return false;
        const result = tree.pointer(context, document, event);
        if (result.changed) self.dirty = true;
        self.settle(env);
        return result.used;
    }

    /// A key while the UI Tree has the keyboard. Returns whether it was used.
    pub fn treeKey(self: *Designer, env: Env, key: @FieldType(ui.input.Event, "key_down"), typing: bool) bool {
        const document = if (self.document) |*open_one| open_one else return false;
        const tree = if (self.tree) |*made| made else return false;
        const result = tree.key(document, key, typing);
        if (result.changed) self.dirty = true;
        self.settle(env);
        return result.used;
    }

    /// The chip beside the pointer while a node is dragged in the UI Tree.
    pub fn dragLabel(self: *const Designer, arena: std.mem.Allocator) ?[]const u8 {
        const tree = if (self.tree) |*made| made else return null;
        return tree.hierarchy.dragLabel(arena);
    }

    /// Close the UI Tree's right-click and Add menus: a press landed elsewhere.
    pub fn closeTreeMenus(self: *Designer) void {
        if (self.tree) |*tree| {
            tree.hierarchy.menu = null;
            tree.adding = null;
        }
    }

    /// `dragged` let go at `at` over UI Properties: set the slot there. Returns whether it did.
    pub fn dropOnProperties(self: *Designer, context: *const ui.Context, at: ui.Vec2, dragged: Dragged) bool {
        const properties = if (self.properties) |*made| made else return false;
        return properties.dropAt(context, at, dragged);
    }

    /// `dragged` let go at `at` over the UI Designer: an image or UI scene becomes a node pinned
    /// there, under the root. Returns whether it did.
    pub fn dropOnPreview(self: *Designer, env: Env, at: ui.Vec2, dragged: Dragged) bool {
        const document = if (self.document) |*open_one| open_one else return false;
        const preview = if (self.preview) |*made| made else return false;
        const reference = switch (dragged) {
            .asset => |asset| asset,
            .entity => return false,
        };
        const point = preview.designPoint(at) orelse return false;
        const key = document.arena().dupe(u8, reference.key()) catch return false;
        const name = document.arena().dupe(u8, std.fs.path.stem(std.fs.path.stem(std.fs.path.basename(reference.name)))) catch return false;
        const pinned = ui_scene.Anchor{ .offset = .{ @round(point[0]), @round(point[1]) } };
        const node: ui_scene.Node = switch (reference.kind) {
            .image => .{ .name = name, .widget = .{ .image = .{ .image = key } }, .layout = .{ .width = .{ .px = 64 }, .height = .{ .px = 64 }, .anchor = pinned } },
            .ui => .{ .name = name, .widget = .{ .scene = .{ .scene = key } }, .layout = .{ .width = .{ .px = 200 }, .height = .{ .px = 100 }, .anchor = pinned } },
            else => return false,
        };
        document.select(&.{});
        document.addChild(node) catch return false;
        self.dirty = true;
        self.settle(env);
        return true;
    }

    /// Write the document's edits once nothing holds them (a node or number being dragged).
    fn settle(self: *Designer, env: Env) void {
        if (!self.dirty) return;
        if (self.preview) |preview| if (preview.drag != null) return;
        if (self.properties) |*properties| if (properties.scrubbing()) return;
        self.dirty = false;
        if (self.document) |*document| self.commit(env, document);
    }

    /// Write the document's edits to its file and record them; a refused value goes back.
    fn commit(self: *Designer, env: Env, document: *Document) void {
        const change = document.take() catch |err| {
            self.say("That value can't be used ({t}); it was put back.", .{err});
            document.replace(document.saved) catch {};
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
        env.app.ui_scenes.forget(document.key());
        const path = env.gpa.dupe(u8, document.path) catch {
            env.gpa.free(change.before);
            env.gpa.free(change.after);
            return;
        };
        env.history.recordUiScene(path, change.before, change.after, env.now_ms);
        self.message_len = 0;
    }

    fn say(self: *Designer, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.message, fmt, args) catch self.message[0..];
        self.message_len = written.len;
    }
};

// Keep where the preview's placeholder was laid out, for the next frame's preview.
fn recordArea(context: *const anyopaque, _: *ui.Canvas, rect: ui.Rect) anyerror!void {
    const area: *ui.Rect = @ptrCast(@alignCast(@constCast(context)));
    area.* = rect;
}

test {
    _ = @import("document.zig");
    _ = @import("tree.zig");
    _ = @import("properties.zig");
}
