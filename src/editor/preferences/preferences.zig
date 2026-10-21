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
    autosave_seconds: u32 = 60,
    code_editor: @import("../code_editor.zig").Choice = .vscode,
    stop_play_key: eggy.Key = .escape,
    /// In `std.log.Level`'s order.
    log_level: enum { err, warn, info, debug } = .info,

    pub const descriptions = .{
        .code_editor = "What double-clicking a code or text file in Assets opens it in. System uses the app your desktop opens it with.",
        .autosave_seconds = "How often the open scene saves itself while it has changes, in seconds. 0 turns it off.",
        .assets_view = "Whether the Assets panel shows files as a tree or as a grid of icons. Its buttons set it too.",
        .theme = "The editor's colours. System follows the desktop's light or dark setting.",
        .rebuild_on_focus = "Rebuild the project when you come back to the editor after changing its code.",
        .show_debug_logs = "Show debug messages in the Console when the editor starts.",
        .log_level = "The quietest messages printed to the terminal and written to the log file, in Eggy's data folder under logs. The Console keeps every message. --log-level=<level> overrides it.",
        .stop_play_key = "Press this key once to stop Play or Simulate and release the mouse. Click the binding to choose another key.",
    };
};

/// The editor's manifest, kept under `editor_key` in `preferences.zon`.
pub const editor_key = "editor";
pub const editor_manifest = prefs.manifest(Editor, editor_key);

/// The editor's preferences in `store`.
/// Return a value copy with store layering/defaults applied; no file read or borrowed fields.
///
/// ```zig
/// const settings = editor(&app.preference_values); // Existing editor App pointer.
/// ```
pub fn editor(store: *const Store) Editor {
    return store.getKeyed(Editor, editor_key);
}

/// `key` (`snake_case`, as module and field names are) as people read it: `straight_bullshit`
/// is "Straight bullshit". In `arena`.
/// Editor label helper: replaces underscores and uppercases the first ASCII character.
/// The result lives in `arena`; allocation failure propagates.
///
/// ```zig
/// const title = try displayName(arena, "rebuild_on_focus"); // Existing arena allocator.
/// ```
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
    /// Editor-only: `project_dir`, when present, should be absolute. Owns copies allocated
    /// by `gpa`; SDL path/allocation failures propagate. Does not create project folders.
    ///
    /// ```zig
    /// const folders = try Folders.init(gpa, project_dir); // Existing allocator/optional path.
    /// defer folders.deinit(gpa);
    /// ```
    pub fn init(gpa: std.mem.Allocator, project_dir: ?[]const u8) !Folders {
        const sdl3 = eggy.sdl_adapter.sdl;
        const pref = try sdl3.filesystem.getPrefPath("eggy", "eggy");
        defer sdl3.free(pref);
        const global = try gpa.dupe(u8, pref);
        errdefer gpa.free(global);
        return .{ .global = global, .project = if (project_dir) |dir| try std.fs.path.join(gpa, &.{ dir, ".eggy" }) else null };
    }

    /// Free editor preference paths once with the allocator passed to `init`.
    /// Invalidates all slices previously returned by `of`; the by-value struct is not reset.
    ///
    /// ```zig
    /// const folders = try Folders.init(gpa, null); // Existing allocator.
    /// defer folders.deinit(gpa);
    /// ```
    pub fn deinit(self: Folders, gpa: std.mem.Allocator) void {
        gpa.free(self.global);
        if (self.project) |project| gpa.free(project);
    }

    /// The folder for `layer`; null for a project layer without a project.
    /// Editor-only: returns a borrowed path valid until `deinit`, without creating it.
    ///
    /// ```zig
    /// const project_preferences = folders.of(.project); // Existing Folders.
    /// ```
    pub fn of(self: Folders, layer: Store.Layer) ?[]const u8 {
        return switch (layer) {
            .global => self.global,
            .project => self.project,
        };
    }
};

/// Read every preferences file into `store`: the editor's from both layers, the plugins' from
/// the project's. A file that can't be read is logged and skipped.
/// Editor-only: reads at most 1 MiB per file and mutates the supplied store; no borrowed disk
/// buffers escape. Missing directories/iteration failures are skipped; malformed values and
/// read/allocation failures are logged where detected, not returned.
///
/// ```zig
/// load(gpa, &app.preference_values, folders); // Existing editor App, allocator and Folders.
/// ```
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
/// Editor-only: use a trusted registered key; only the requested layer is serialized, not
/// effective merged values. Missing project layer returns NoProject; allocation/I/O errors
/// propagate. This writes directly rather than atomically replacing the destination.
///
/// ```zig
/// try save(gpa, &app.preference_values, folders, .project, editor_key);
/// // Existing editor App, allocator and project-backed Folders.
/// ```
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

/// Keep the project's `plugins.zon` (`eggy.plugins.registry_file`) listing its plugins (`keys`,
/// the game first), whether each is on (those in `off` aren't), and the preferences each declares
/// (`manifests`), rewriting it only when that changed, so the file's time says when they did.
/// Editor-only: borrows metadata for the call, creates missing preference folders and no-ops
/// without a project. Returns no owned memory; formatting/allocation/write errors propagate.
///
/// ```zig
/// // Given current game's keys/manifests, disabled keys, allocator and preference Folders:
/// try writeRegistry(gpa, folders, game.plugin_keys, game.preference_manifests, off);
/// ```
pub fn writeRegistry(gpa: std.mem.Allocator, folders: Folders, keys: []const [:0]const u8, manifests: []const prefs.Manifest, off: []const []const u8) !void {
    const folder = folders.project orelse return;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try formatRegistry(&text.writer, keys, manifests, off);

    var dir = try openMaking(io, folder);
    defer dir.close(io);
    const old = dir.readFileAlloc(io, "plugins.zon", gpa, .limited(1 << 20)) catch null;
    defer if (old) |bytes| gpa.free(bytes);
    if (old != null and std.mem.eql(u8, old.?, text.written())) return;
    try dir.writeFile(io, .{ .sub_path = "plugins.zon", .data = text.written() });
}

fn formatRegistry(writer: *std.Io.Writer, keys: []const [:0]const u8, manifests: []const prefs.Manifest, off: []const []const u8) !void {
    try writer.writeAll("// Kept up to date by the Eggy editor: the plugins this project has, whether each is on\n// (Preferences > Plugins), and the preferences each declares (set them in plugins/<plugin>.zon,\n// or in the editor). The game is built with the plugins that are off left out.\n.{\n    .plugins = .{\n");
    for (keys) |key| {
        const on = for (off) |off_key| {
            if (std.mem.eql(u8, off_key, key)) break false;
        } else true;
        try writer.print("        .{{ .key = \"{f}\", .on = {}, .preferences = .{{", .{ std.zig.fmtString(key), on });
        const fields: []const prefs.Field = for (manifests) |manifest| {
            if (std.mem.eql(u8, manifest.key, key)) break manifest.fields;
        } else &.{};
        for (fields, 0..) |field, i| try writer.print("{s}\"{f}\"", .{ if (i == 0) " " else ", ", std.zig.fmtString(field.name) });
        try writer.writeAll(if (fields.len > 0) " } },\n" else "} },\n");
    }
    try writer.writeAll("    },\n}\n");
}

fn openMaking(io: std.Io, path: []const u8) !std.Io.Dir {
    try std.Io.Dir.cwd().createDirPath(io, path);
    return std.Io.Dir.cwd().openDir(io, path, .{});
}

test "the registry lists each plugin, whether it is on, and its preferences" {
    const Example = struct { volume: f32 = 1, muted: bool = false };
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try formatRegistry(&text.writer, &.{ "game", "example" }, &.{prefs.manifest(Example, "example")}, &.{"example"});
    try std.testing.expect(std.mem.indexOf(u8, text.written(), ".{ .key = \"game\", .on = true, .preferences = .{} },") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), ".{ .key = \"example\", .on = false, .preferences = .{ \"volume\", \"muted\" } },") != null);

    // The runtime reads it back the same.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().dupeZ(u8, text.written());
    const off = try eggy.plugins.parseOff(arena.allocator(), source);
    try std.testing.expectEqualStrings("example", off[0]);
}

test "the editor's preferences have a manifest" {
    try std.testing.expectEqual(@as(usize, 8), editor_manifest.fields.len);
    try std.testing.expectEqualStrings("system", editor_manifest.fields[0].options[0]);
    try std.testing.expectEqualStrings("vscode", editor_manifest.fields[5].default[1..]);
    try std.testing.expectEqualStrings(".escape", editor_manifest.fields[6].default);
    try std.testing.expectEqualStrings(".info", editor_manifest.fields[7].default);
}

test "the stop key defaults to Escape and follows preference scopes" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectEqual(eggy.Key.escape, editor(&store).stop_play_key);
    try store.set(.global, editor_key, "stop_play_key", ".func8");
    try std.testing.expectEqual(eggy.Key.func8, editor(&store).stop_play_key);
    try store.set(.project, editor_key, "stop_play_key", ".func10");
    try std.testing.expectEqual(eggy.Key.func10, editor(&store).stop_play_key);
    try store.set(.project, editor_key, "stop_play_key", null);
    try std.testing.expectEqual(eggy.Key.func8, editor(&store).stop_play_key);
}
