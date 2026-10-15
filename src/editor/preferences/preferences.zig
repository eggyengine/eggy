//! Preferences on disk. The editor's own (`Editor`) are in the user's global folder (Eggy's data
//! folder) and a project's `.eggy/` folder, which overrides it, as `preferences.zon`. Each
//! plugin's are the project's only, in `.eggy/plugins/<key>.zon`; `.eggy/plugins.zon`, which the
//! editor keeps up to date, lists the plugins the project has and the preferences each declares.
//! `window.zig` is the Preferences window that edits them.
const std = @import("std");
const eggy = @import("eggy");
const prefs = eggy.preferences;
const Store = prefs.Store;
const log = std.log.scoped(.preferences);

pub const PreferencesWindow = @import("window.zig").PreferencesWindow;
pub const Section = @import("window.zig").Section;
pub const Plugin = @import("window.zig").Plugin;
pub const Switch = @import("window.zig").Switch;

/// The editor's own preferences.
pub const Editor = struct {
    theme: enum { system, light, dark } = .system,
    rebuild_on_focus: bool = true,
    show_debug_logs: bool = false,
    assets_view: enum { list, grid } = .list,

    pub const descriptions = .{
        .assets_view = "Whether the Assets panel shows files as a tree or as a grid of icons. Its buttons set it too.",
        .theme = "The editor's colours. System follows the desktop's light or dark setting.",
        .rebuild_on_focus = "Rebuild the project when you come back to the editor after changing its code.",
        .show_debug_logs = "Show debug messages in the Console when the editor starts.",
    };
};

/// The editor's manifest, kept under `editor_key` in `preferences.zon`.
pub const editor_key = "editor";
pub const editor_manifest = prefs.manifest(Editor, editor_key);

/// The editor's preferences in `store`.
pub fn editor(store: *const Store) Editor {
    return store.getKeyed(Editor, editor_key);
}

/// `key` (`snake_case`, as module and field names are) as people read it: `straight_bullshit`
/// is "Straight bullshit". In `arena`.
pub fn displayName(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    const name = try arena.dupe(u8, key);
    for (name) |*char| if (char.* == '_') {
        char.* = ' ';
    };
    if (name.len > 0) name[0] = std.ascii.toUpper(name[0]);
    return name;
}

/// Where the two layers live, absolute; the project's is null without a project.
pub const Folders = struct {
    global: []u8,
    project: ?[]u8,

    /// The user's (in Eggy's data folder) and `project_dir`'s (`.eggy/`). Free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, project_dir: ?[]const u8) !Folders {
        const sdl3 = eggy.sdl_adapter.sdl;
        const pref = try sdl3.filesystem.getPrefPath("eggy", "eggy");
        defer sdl3.free(pref);
        const global = try gpa.dupe(u8, pref);
        errdefer gpa.free(global);
        return .{ .global = global, .project = if (project_dir) |dir| try std.fs.path.join(gpa, &.{ dir, ".eggy" }) else null };
    }

    pub fn deinit(self: Folders, gpa: std.mem.Allocator) void {
        gpa.free(self.global);
        if (self.project) |project| gpa.free(project);
    }

    /// The folder for `layer`; null for a project layer without a project.
    pub fn of(self: Folders, layer: Store.Layer) ?[]const u8 {
        return switch (layer) {
            .global => self.global,
            .project => self.project,
        };
    }
};

/// Read every preferences file into `store`: the editor's from both layers, the plugins' from
/// the project's. A file that can't be read is logged and skipped.
pub fn load(gpa: std.mem.Allocator, store: *Store, folders: Folders) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    for ([_]Store.Layer{ .global, .project }) |layer| {
        const folder = folders.of(layer) orelse continue;
        var dir = std.Io.Dir.cwd().openDir(io, folder, .{}) catch continue;
        defer dir.close(io);
        readFile(gpa, io, store, layer, dir, "preferences.zon", editor_manifest.key);
        if (layer == .global) continue;
        var plugins = dir.openDir(io, "plugins", .{ .iterate = true }) catch continue;
        defer plugins.close(io);
        var it = plugins.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zon")) continue;
            readFile(gpa, io, store, layer, plugins, entry.name, entry.name[0 .. entry.name.len - ".zon".len]);
        }
    }
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, store: *Store, layer: Store.Layer, dir: std.Io.Dir, name: []const u8, key: []const u8) void {
    const source = dir.readFileAllocOptions(io, name, gpa, .limited(1 << 20), .of(u8), 0) catch |err| {
        if (err != error.FileNotFound) log.warn("cannot read {s}: {t}", .{ name, err });
        return;
    };
    defer gpa.free(source);
    store.read(layer, key, source) catch |err| log.warn("{s} isn't a ZON struct of preferences ({t}): it is ignored", .{ name, err });
}

/// Write `key`'s values in `layer` to its file: `preferences.zon` for the editor's, else
/// `plugins/<key>.zon`, making the folders it needs.
pub fn save(gpa: std.mem.Allocator, store: *const Store, folders: Folders, layer: Store.Layer, key: []const u8) !void {
    const folder = folders.of(layer) orelse return error.NoProject;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const sub_path = if (std.mem.eql(u8, key, editor_manifest.key)) try gpa.dupe(u8, "preferences.zon") else try std.fmt.allocPrint(gpa, "plugins{c}{s}.zon", .{ std.fs.path.sep, key });
    defer gpa.free(sub_path);
    var dir = try openMaking(io, folder);
    defer dir.close(io);
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(io, parent);
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try store.write(layer, key, &text.writer);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = text.written() });
}

/// Keep the project's `plugins.zon` listing `manifests` (the game's plugins' preferences),
/// rewriting it only when that changed, so the file's time says when the plugins did.
pub fn writeRegistry(gpa: std.mem.Allocator, folders: Folders, manifests: []const prefs.Manifest) !void {
    const folder = folders.project orelse return;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try formatRegistry(&text.writer, manifests);

    var dir = try openMaking(io, folder);
    defer dir.close(io);
    const old = dir.readFileAlloc(io, "plugins.zon", gpa, .limited(1 << 20)) catch null;
    defer if (old) |bytes| gpa.free(bytes);
    if (old != null and std.mem.eql(u8, old.?, text.written())) return;
    try dir.writeFile(io, .{ .sub_path = "plugins.zon", .data = text.written() });
}

fn formatRegistry(writer: *std.Io.Writer, manifests: []const prefs.Manifest) !void {
    try writer.writeAll("// Kept up to date by the Eggy editor: the plugins this project has, and the preferences each\n// declares. Don't edit it; set preferences in plugins/<plugin>.zon, or in the editor.\n.{\n    .plugins = .{\n");
    for (manifests) |manifest| {
        try writer.print("        .{{ .key = \"{f}\", .preferences = .{{", .{std.zig.fmtString(manifest.key)});
        for (manifest.fields, 0..) |field, i| try writer.print("{s}\"{f}\"", .{ if (i == 0) " " else ", ", std.zig.fmtString(field.name) });
        try writer.writeAll(if (manifest.fields.len > 0) " } },\n" else "} },\n");
    }
    try writer.writeAll("    },\n}\n");
}

fn openMaking(io: std.Io, path: []const u8) !std.Io.Dir {
    try std.Io.Dir.cwd().createDirPath(io, path);
    return std.Io.Dir.cwd().openDir(io, path, .{});
}

test "the registry lists each plugin's preferences" {
    const Example = struct { volume: f32 = 1, muted: bool = false };
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try formatRegistry(&text.writer, &.{prefs.manifest(Example, "example")});
    try std.testing.expect(std.mem.indexOf(u8, text.written(), ".{ .key = \"example\", .preferences = .{ \"volume\", \"muted\" } },") != null);
}

test "the editor's preferences have a manifest" {
    try std.testing.expectEqual(@as(usize, 4), editor_manifest.fields.len);
    try std.testing.expectEqualStrings("system", editor_manifest.fields[0].options[0]);
}
