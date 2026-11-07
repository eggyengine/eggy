//! One manifest's preferences as rows to change, in cards by the struct's groups: a control for
//! each field, where an inherited value comes from, and a reset, each change saved and recorded
//! for undo. Settings shows one per page, and Edit > Plugins the chosen plugin's. A global-only
//! field always shows and sets the global layer, whichever layer the form is on.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const prefs = eggy.preferences;
const Store = prefs.Store;
const files = @import("preferences.zig");
const History = @import("../history.zig").History;
const page_style = @import("../page_style.zig");
const code_editor = @import("../code_editor.zig");
const setting_rows = eggy.setting_rows;
const SettingRows = setting_rows.SettingRows;
const restyle = page_style.restyle;
const log = std.log.scoped(.preferences);

/// The most fields a form shows.
pub const max_fields = 64;
/// A number or string field's text.
const FieldEdit = ui.TextEdit(256);

/// Where a form's values live and its changes go, for a frame.
pub const Target = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    folders: files.Folders,
    /// Whose values the rows show and set: all projects', or the project's.
    layer: Store.Layer,
    /// Where each change is recorded for undo, if anywhere.
    history: ?*History,
    now_ms: u64,
};

pub const PreferenceForm = struct {
    /// The number and string fields' text, filled from the values shown for `synced`.
    edits: [max_fields]FieldEdit = undefined,
    synced: ?Synced = null,
    capturing_stop_key: bool = false,
    captured_stop_key: ?eggy.Key = null,

    const Synced = struct { key_hash: u64, layer: Store.Layer };

    /// Fill the number fields from the store again on the next frame, as after an undo.
    pub fn forget(self: *PreferenceForm) void {
        self.synced = null;
    }

    /// Take `curr_event` while waiting for the key that stops Play; returns whether it was taken.
    pub fn takeKey(self: *PreferenceForm, curr_event: sdl3.events.Event) bool {
        if (!self.capturing_stop_key or curr_event != .key_down) return false;
        if (!curr_event.key_down.repeat) if (curr_event.key_down.scancode) |key| {
            self.captured_stop_key = key;
            self.capturing_stop_key = false;
        };
        return true;
    }

    /// Whether Escape should wait: it cancels nothing while a key is being chosen.
    pub fn wantsEscape(self: *const PreferenceForm) bool {
        return self.capturing_stop_key;
    }

    /// Draw `manifest`'s fields as rows, leaving out those `query_text` doesn't match; changes
    /// go to `target`. Draws nothing when no row shows.
    ///
    /// ```zig
    /// form.build(context, manifest, "", .{ .gpa = gpa, .store = store, .folders = folders, .layer = .project, .history = history, .now_ms = now });
    /// ```
    pub fn build(self: *PreferenceForm, context: *ui.Context, manifest: prefs.Manifest, query_text: []const u8, target: Target) void {
        const fields = manifest.fields[0..@min(manifest.fields.len, max_fields)];
        // The text fields start from the values shown, for each manifest and layer.
        const showing = Synced{ .key_hash = std.hash.Wyhash.hash(0, manifest.key), .layer = target.layer };
        if (self.synced == null or !std.meta.eql(self.synced.?, showing)) {
            for (fields, 0..) |field, i| {
                const literal = current(target.store, layerOf(target.layer, field), manifest.key, field);
                const text = if (field.kind == .string) prefs.stringValue(literal) orelse "" else literal;
                self.edits[i] = FieldEdit.init(text) catch FieldEdit.init("") catch unreachable;
            }
            self.synced = showing;
        }

        // A card for each of the struct's groups, holding its fields in their order.
        var last_group: u8 = 0;
        for (fields) |field| last_group = @max(last_group, field.group);
        const arena = context.builder().allocator;
        for (0..@as(usize, last_group) + 1) |group| {
            var rows = SettingRows{ .query = query_text };
            var card_open = false;
            for (fields, 0..) |field, i| {
                if (field.group != group) continue;
                if (!rows.shows(files.displayName(arena, field.name) catch field.name, field.description)) continue;
                if (!card_open) setting_rows.beginGroup(context);
                card_open = true;
                self.fieldRow(context, &rows, target, manifest.key, field, &self.edits[i]);
            }
            if (card_open) setting_rows.endGroup(context);
        }
    }

    /// One preference as a row: its name and description on the left, its control on the right
    /// with, under it, where an inherited or overridden value is from, and a reset beside it
    /// when this layer sets it.
    fn fieldRow(self: *PreferenceForm, context: *ui.Context, rows: *SettingRows, form_target: Target, key: []const u8, field: prefs.Field, edit: *FieldEdit) void {
        const arena = context.builder().allocator;
        var target = form_target;
        target.layer = layerOf(form_target.layer, field);
        const store = target.store;
        const layer = target.layer;
        const unit = unitOf(field.name);
        const title = files.displayName(arena, field.name[0 .. field.name.len - unit.suffix.len]) catch field.name;
        const value = current(store, layer, key, field);
        // Controls take their ids from their (hidden) label: the field's name.
        const hidden = std.fmt.allocPrint(arena, "##{s}", .{field.name}) catch return;
        const global_value = store.literal(.global, key, field.name);
        const set_here = store.literal(layer, key, field.name) != null;
        // What the value would be without this layer's: All projects', else the default.
        const inherited = if (layer == .project) global_value orelse field.default else field.default;

        rows.beginMarked(context, title, field.description, .{ .changed = set_here and !std.mem.eql(u8, value, inherited) });
        const changed: ?[]const u8 = switch (field.kind) {
            .bool => blk: {
                var on = std.mem.eql(u8, value, "true");
                break :blk if (context.toggle(hidden, &on)) (if (on) "true" else "false") else null;
            },
            .@"enum" => blk: {
                if (std.mem.eql(u8, key, files.editor_key) and std.mem.eql(u8, field.name, "stop_play_key")) break :blk self.stopKeyControl(context, value);
                const options = arena.alloc([]const u8, field.options.len) catch break :blk null;
                var selected: usize = 0;
                for (options, field.options, 0..) |*option, name, index| {
                    option.* = optionLabel(arena, key, field.name, name);
                    if (value.len > 1 and std.mem.eql(u8, value[1..], name)) selected = index;
                }
                const picked = context.select(hidden, options, &selected);
                break :blk if (picked) (std.fmt.allocPrint(arena, ".{s}", .{field.options[selected]}) catch null) else null;
            },
            .int, .float => blk: {
                context.begin(.row);
                const typed = context.textInput(hidden, edit, field.default);
                restyle(context, .{ .width = 96 });
                if (unit.label.len > 0) context.muted(unit.label);
                context.end();
                restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center });
                if (!typed) break :blk null;
                const text = std.mem.trim(u8, edit.text(), " ");
                const valid = if (field.kind == .int) !std.meta.isError(std.fmt.parseInt(i128, text, 10)) else !std.meta.isError(std.fmt.parseFloat(f64, text));
                break :blk if (valid) text else null;
            },
            .string => blk: {
                const typed = context.textInput(hidden, edit, prefs.stringValue(field.default) orelse "");
                restyle(context, .{ .width = 320 });
                if (!typed) break :blk null;
                // Kept as a plain ZON string, which `prefs.stringValue` reads back.
                const text = std.mem.trim(u8, edit.text(), " ");
                if (std.mem.indexOfAny(u8, text, "\\\"") != null) break :blk null;
                break :blk std.fmt.allocPrint(arena, "\"{s}\"", .{text}) catch null;
            },
        };
        if (changed) |literal| apply(target, key, field.name, literal);

        // Under the control: what a reset goes back to, else where the value shown is from, else
        // (on All projects) that this project overrides it.
        const shown = valueLabel(arena, key, field, inherited);
        const note: []const u8 = if (set_here)
            (if (layer == .project and global_value != null) std.fmt.allocPrint(arena, "All projects use {s}", .{shown}) catch "" else std.fmt.allocPrint(arena, "Default is {s}", .{shown}) catch "")
        else if (layer == .project and global_value != null)
            "From All projects"
        else if (layer == .global and target.folders.project != null and store.literal(.project, key, field.name) != null)
            std.fmt.allocPrint(arena, "This project uses {s}", .{valueLabel(arena, key, field, store.literal(.project, key, field.name).?)}) catch ""
        else
            "";
        if (rows.endResettable(context, note, set_here, field.name)) {
            apply(target, key, field.name, null);
            self.synced = null;
        }
    }

    /// The key that stops Play, as a keycap, and a button to press another; returns the new
    /// key's literal once one is pressed.
    fn stopKeyControl(self: *PreferenceForm, context: *ui.Context, value: []const u8) ?[]const u8 {
        const code = (if (value.len > 1) std.meta.stringToEnum(eggy.Key, value[1..]) else null) orelse (files.Editor{}).stop_play_key;
        context.begin(.row);
        context.badge(if (self.capturing_stop_key) "Press a key..." else sdl3.keyboard.getScancodeName(code) orelse @tagName(code), .outline);
        if (self.capturing_stop_key) {
            if (context.buttonVariant("Cancel##stop key", .ghost)) self.capturing_stop_key = false;
        } else if (context.buttonVariant("Change##stop key", .outline)) self.capturing_stop_key = true;
        context.end();
        restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center });
        const captured = self.captured_stop_key orelse return null;
        self.captured_stop_key = null;
        return std.fmt.allocPrint(context.builder().allocator, ".{t}", .{captured}) catch null;
    }
};

/// Set `field` of `key` in `target`'s layer to `literal` (null clears it), and save its file.
fn apply(target: Target, key: []const u8, field: []const u8, literal: ?[]const u8) void {
    // Undoable: what it was goes with the change.
    if (target.history) |history| history.recordPreference(target.layer, key, field, target.store.literal(target.layer, key, field), literal, target.now_ms);
    target.store.set(target.layer, key, field, literal) catch |err| return log.err("cannot set {s}.{s}: {t}", .{ key, field, err });
    files.save(target.gpa, target.store, target.folders, target.layer, key) catch |err| log.err("cannot save {s}'s preferences: {t}", .{ key, err });
}

/// A number field's unit, from its name's suffix: the suffix, and the word shown after it.
fn unitOf(name: []const u8) struct { suffix: []const u8, label: []const u8 } {
    const units = [_][2][]const u8{ .{ "_seconds", "seconds" }, .{ "_ms", "ms" }, .{ "_px", "px" }, .{ "_m", "m" } };
    for (units) |unit| if (std.mem.endsWith(u8, name, unit[0]) and name.len > unit[0].len) return .{ .suffix = unit[0], .label = unit[1] };
    return .{ .suffix = "", .label = "" };
}

/// An enum choice as people read it: the editor's own have names of their own.
fn optionLabel(arena: std.mem.Allocator, key: []const u8, field: []const u8, name: []const u8) []const u8 {
    if (std.mem.eql(u8, key, files.editor_key)) {
        if (std.mem.eql(u8, field, "code_editor")) if (std.meta.stringToEnum(code_editor.Choice, name)) |choice| {
            return if (choice == .system) "System default" else choice.label();
        };
        if (std.mem.eql(u8, field, "log_level")) {
            const levels = [_][2][]const u8{ .{ "err", "Errors" }, .{ "warn", "Warnings" }, .{ "info", "Info" }, .{ "debug", "Debug" } };
            for (levels) |level| if (std.mem.eql(u8, name, level[0])) return level[1];
        }
    }
    return files.displayName(arena, name) catch name;
}

/// `literal`, a value of `field`, as its control shows it.
fn valueLabel(arena: std.mem.Allocator, key: []const u8, field: prefs.Field, literal: []const u8) []const u8 {
    return switch (field.kind) {
        .bool => if (std.mem.eql(u8, literal, "true")) "On" else "Off",
        .@"enum" => if (literal.len > 1 and literal[0] == '.') optionLabel(arena, key, field.name, literal[1..]) else literal,
        .int, .float => blk: {
            const unit = unitOf(field.name);
            break :blk if (unit.label.len > 0) std.fmt.allocPrint(arena, "{s} {s}", .{ literal, unit.label }) catch literal else literal;
        },
        .string => blk: {
            const text = prefs.stringValue(literal) orelse literal;
            break :blk if (text.len == 0) "empty" else text;
        },
    };
}

/// The layer a form on `layer` shows and sets `field` in: the global one for a global-only field.
fn layerOf(layer: Store.Layer, field: prefs.Field) Store.Layer {
    return if (field.scope == .global_only) .global else layer;
}

/// What `field` of `key` is in `layer`: its own value, else (for the project) the global one,
/// else the default.
pub fn current(store: *const Store, layer: Store.Layer, key: []const u8, field: prefs.Field) []const u8 {
    if (store.literal(layer, key, field.name)) |value| return value;
    if (layer == .project) if (store.literal(.global, key, field.name)) |value| return value;
    return field.default;
}

test "a project falls back on the global value, then the default" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const field = prefs.Field{ .name = "volume", .kind = .float, .default = "0.8" };
    try std.testing.expectEqualStrings("0.8", current(&store, .project, "game", field));
    try store.set(.global, "game", "volume", "0.5");
    try std.testing.expectEqualStrings("0.5", current(&store, .project, "game", field));
    try store.set(.project, "game", "volume", "0.2");
    try std.testing.expectEqualStrings("0.2", current(&store, .project, "game", field));
    try std.testing.expectEqualStrings("0.5", current(&store, .global, "game", field));
}

test "number fields show their unit, and enum values their names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("seconds", unitOf("autosave_seconds").label);
    try std.testing.expectEqualStrings("", unitOf("volume").label);
    try std.testing.expectEqualStrings("VS Code", optionLabel(arena.allocator(), files.editor_key, "code_editor", "vscode"));
    try std.testing.expectEqualStrings("Warnings", optionLabel(arena.allocator(), files.editor_key, "log_level", "warn"));
    const field = prefs.Field{ .name = "autosave_seconds", .kind = .int, .default = "60" };
    try std.testing.expectEqualStrings("60 seconds", valueLabel(arena.allocator(), files.editor_key, field, "60"));
}

test "a global-only field is shown and set in the global layer from either scope" {
    const field = prefs.Field{ .name = "eggy_source", .kind = .string, .default = "\"a\"", .scope = .global_only };
    try std.testing.expectEqual(Store.Layer.global, layerOf(.project, field));
    try std.testing.expectEqual(Store.Layer.project, layerOf(.project, .{ .name = "volume", .kind = .float, .default = "1" }));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("https://x/eggy#main", valueLabel(arena.allocator(), "editor", field, "\"https://x/eggy#main\""));
}
