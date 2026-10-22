//! The UI scene the UI Designer edits: the file's text as last written, a parsed copy edited in
//! place, which node is selected, and the edits that reshape the node tree. An edit changes the
//! copy; `take` turns it into the file's text before and after, for the file and for History.
const std = @import("std");
const eggy = @import("eggy");
const ui_scene = eggy.assets.ui_scene;
const Node = ui_scene.Node;
const UiScene = ui_scene.UiScene;

const key_len = eggy.assets.id.key_len;

/// The file's text before and after an edit, owned by the document's allocator.
pub const Change = struct { before: []u8, after: []u8 };

pub const Document = struct {
    gpa: std.mem.Allocator,
    /// Project-relative, owned.
    path: []u8,
    /// The file's asset key, so caches drawing it can forget it after an edit.
    key_buffer: [key_len]u8 = undefined,
    key_len: usize = 0,
    /// The file's text as last read or written.
    saved: []u8,
    /// `saved` as `write` puts it, which edits are compared with: a hand-written file isn't
    /// changed until something in it is.
    normal: []u8,
    parsed: ui_scene.Parsed,
    /// The selected node's path from the root (empty: the root).
    selected: [ui_scene.max_depth]u16 = undefined,
    selected_len: usize = 0,

    /// The document for `text`, the file at `path` (copied) with asset `key` (may be empty).
    /// Fails when `text` isn't a UI scene this build reads.
    pub fn init(gpa: std.mem.Allocator, path: []const u8, asset_key: []const u8, text: []const u8) !Document {
        const source = try gpa.dupeZ(u8, text);
        defer gpa.free(source);
        var parsed = try ui_scene.parse(gpa, source);
        errdefer parsed.deinit();
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        const saved = try gpa.dupe(u8, text);
        errdefer gpa.free(saved);
        const normal = try serialize(gpa, parsed.scene);
        var self = Document{ .gpa = gpa, .path = owned_path, .saved = saved, .normal = normal, .parsed = parsed };
        self.key_len = @min(asset_key.len, key_len);
        @memcpy(self.key_buffer[0..self.key_len], asset_key[0..self.key_len]);
        return self;
    }

    pub fn deinit(self: *Document) void {
        self.parsed.deinit();
        self.gpa.free(self.saved);
        self.gpa.free(self.normal);
        self.gpa.free(self.path);
    }

    pub fn key(self: *const Document) []const u8 {
        return self.key_buffer[0..self.key_len];
    }

    pub fn scene(self: *Document) *UiScene {
        return &self.parsed.scene;
    }

    /// Where edited strings and node lists live until the next `take`.
    pub fn arena(self: *Document) std.mem.Allocator {
        return self.parsed.arena.allocator();
    }

    pub fn selection(self: *const Document) ui_scene.Path {
        return self.selected[0..self.selected_len];
    }

    /// The selected node; the root when the selection no longer names one.
    pub fn selectedNode(self: *Document) *Node {
        if (ui_scene.nodeAt(&self.parsed.scene.root, self.selection())) |node| return node;
        self.selected_len = 0;
        return &self.parsed.scene.root;
    }

    pub fn select(self: *Document, path: ui_scene.Path) void {
        self.selected_len = @min(path.len, self.selected.len);
        @memcpy(self.selected[0..self.selected_len], path[0..self.selected_len]);
    }

    /// The edits since the last `take`, as the file's text before and after; null when nothing
    /// changed. The copy is parsed again from the new text, which frees what edits left behind.
    /// Fails with `error.InvalidUiScene` when an edit made a value the format refuses.
    pub fn take(self: *Document) !?Change {
        try self.parsed.scene.validate();
        const text = try serialize(self.gpa, self.parsed.scene);
        defer self.gpa.free(text);
        if (std.mem.eql(u8, text, self.normal)) return null;

        // Parse the new text into a fresh arena, so the copy holds only what the file says.
        const source = try self.gpa.dupeZ(u8, text);
        defer self.gpa.free(source);
        var parsed = try ui_scene.parse(self.gpa, source);
        errdefer parsed.deinit();
        const after = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(after);
        const saved = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(saved);
        const normal = try self.gpa.dupe(u8, text);
        self.parsed.deinit();
        self.parsed = parsed;
        self.gpa.free(self.normal);
        self.normal = normal;
        const before = self.saved;
        self.saved = saved;
        return .{ .before = before, .after = after };
    }

    /// Show `text` instead (an undo or redo, or the file changed), keeping the selection when
    /// it still names a node.
    pub fn replace(self: *Document, text: []const u8) !void {
        const source = try self.gpa.dupeZ(u8, text);
        defer self.gpa.free(source);
        var parsed = try ui_scene.parse(self.gpa, source);
        errdefer parsed.deinit();
        const saved = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(saved);
        const normal = try serialize(self.gpa, parsed.scene);
        self.parsed.deinit();
        self.parsed = parsed;
        self.gpa.free(self.saved);
        self.saved = saved;
        self.gpa.free(self.normal);
        self.normal = normal;
        _ = self.selectedNode();
    }

    // Reshaping the tree -------------------------------------------------------------------

    /// Add `node` as the selected node's last child, and select it.
    pub fn addChild(self: *Document, node: Node) !void {
        if (self.selected_len + 1 >= ui_scene.max_depth) return error.TooDeep;
        const parent = self.selectedNode();
        const index = parent.children.len;
        try ui_scene.insertChild(self.arena(), parent, index, node);
        self.selected[self.selected_len] = @intCast(index);
        self.selected_len += 1;
    }

    /// Delete the selected node and its children, selecting its parent. The root stays.
    pub fn deleteSelected(self: *Document) !void {
        const place = self.parentOfSelected() orelse return;
        _ = try ui_scene.removeChild(self.arena(), place.parent, place.index);
        self.selected_len -= 1;
    }

    /// Put a copy of the selected node (with its children) after it, and select the copy.
    pub fn duplicateSelected(self: *Document) !void {
        const place = self.parentOfSelected() orelse return;
        const copy = try copyNode(self.arena(), place.parent.children[place.index]);
        try ui_scene.insertChild(self.arena(), place.parent, place.index + 1, copy);
        self.selected[self.selected_len - 1] += 1;
    }

    /// Move the selected node (with its children) to be child `index` of the node at `parent`
    /// (counted before it was taken out), and select it there. Moving the root, or a node into
    /// itself, does nothing.
    pub fn moveSelected(self: *Document, parent: ui_scene.Path, index: usize) !void {
        const from = self.parentOfSelected() orelse return;
        const own = self.selection();
        if (parent.len >= own.len and std.mem.eql(u16, parent[0..own.len], own)) return;
        if (parent.len + 1 >= ui_scene.max_depth) return error.TooDeep;

        // Taking the node out shifts its later siblings, and any path through them, back by one.
        var target: [ui_scene.max_depth]u16 = undefined;
        @memcpy(target[0..parent.len], parent);
        var at = index;
        const depth = own.len - 1;
        const same_parent = parent.len == depth and std.mem.eql(u16, parent, own[0..depth]);
        if (same_parent and at > from.index) at -= 1;
        if (parent.len > depth and std.mem.eql(u16, parent[0..depth], own[0..depth]) and parent[depth] > from.index) target[depth] -= 1;

        const taken = try ui_scene.removeChild(self.arena(), from.parent, from.index);
        const new_parent = ui_scene.nodeAt(&self.parsed.scene.root, target[0..parent.len]).?;
        at = @min(at, new_parent.children.len);
        try ui_scene.insertChild(self.arena(), new_parent, at, taken);
        target[parent.len] = @intCast(at);
        self.select(target[0 .. parent.len + 1]);
    }

    const Place = struct { parent: *Node, index: usize };

    fn parentOfSelected(self: *Document) ?Place {
        _ = self.selectedNode();
        if (self.selected_len == 0) return null;
        const parent = ui_scene.nodeAt(&self.parsed.scene.root, self.selected[0 .. self.selected_len - 1]).?;
        return .{ .parent = parent, .index = self.selected[self.selected_len - 1] };
    }
};

/// `scene` as `.ui.zon` text, owned by `gpa`.
fn serialize(gpa: std.mem.Allocator, scene: UiScene) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    scene.write(&text.writer) catch return error.OutOfMemory;
    return text.toOwnedSlice();
}

/// `node` and its children copied into `arena`.
fn copyNode(arena: std.mem.Allocator, node: Node) !Node {
    const scene = try (UiScene{ .root = node }).clone(arena);
    return scene.root;
}

test "nodes are added, duplicated, moved in and out of parents and deleted, and taken as text" {
    const gpa = std.testing.allocator;
    var document = try Document.init(gpa, "resources/hud.ui.zon", "", ui_scene.template);
    defer document.deinit();
    try std.testing.expect(try document.take() == null);

    try document.addChild(.{ .name = "bar", .widget = .{ .progress = .{} } });
    try std.testing.expectEqualSlices(u16, &.{1}, document.selection());
    try document.duplicateSelected();
    try std.testing.expectEqualSlices(u16, &.{2}, document.selection());
    // Into the template's first node, then back out to the end of the root.
    try document.moveSelected(&.{0}, 0);
    try std.testing.expectEqualSlices(u16, &.{ 0, 0 }, document.selection());
    try std.testing.expectEqualStrings("bar", document.selectedNode().name);
    try document.moveSelected(&.{}, 3);
    try std.testing.expectEqualSlices(u16, &.{2}, document.selection());
    // Before an earlier sibling; into itself does nothing.
    try document.moveSelected(&.{}, 1);
    try std.testing.expectEqualSlices(u16, &.{1}, document.selection());
    try document.moveSelected(&.{1}, 0);
    try std.testing.expectEqualSlices(u16, &.{1}, document.selection());
    try document.deleteSelected();
    try std.testing.expectEqual(@as(usize, 2), document.scene().root.children.len);

    const change = (try document.take()).?;
    defer gpa.free(change.before);
    defer gpa.free(change.after);
    try std.testing.expectEqualStrings(ui_scene.template, change.before);
    try std.testing.expect(std.mem.indexOf(u8, change.after, "bar") != null);
    // Undone, the scene is the template again.
    try document.replace(change.before);
    try std.testing.expectEqual(@as(usize, 1), document.scene().root.children.len);
}
