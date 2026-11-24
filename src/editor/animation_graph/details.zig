//! The graph editor's details: the settings of what is selected in the canvas or the outline.
//! A layer's name, bone and first state; a state's name and what it plays (a clip, or clips
//! placed along one axis or across two); a transition's conditions and blend; a parameter's
//! name, kind and default. Each field edits the document as it changes.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const format = eggy.assets.animation_graph;
const page_style = @import("../page_style.zig");
const restyle = page_style.restyle;
const setting_rows = eggy.setting_rows;
const SettingRows = setting_rows.SettingRows;
const document_zig = @import("document.zig");
const Document = document_zig.Document;
const BlendPlot = @import("blend_plot.zig").BlendPlot;

const remove_glyph = "\u{f00d}";
const plus_glyph = "\u{f067}";
const Edit = ui.TextEdit(64);

const motion_labels = [_][]const u8{ "One clip", "Blend along one axis", "Blend across two axes", "None" };
const repeat_labels = [_][]const u8{ "Once", "Loop" };
const root_motion_labels = [_][]const u8{ "Keep", "In place", "Pinned" };
const kind_labels = [_][]const u8{ "Float", "Bool", "Trigger" };
const check_labels = [_][]const u8{ "is set", "is on", "is off", "is above", "is below" };

/// The clips a field can pick: their asset keys, and what each is called.
pub const Clips = struct {
    keys: []const []const u8,
    names: []const []const u8,
};

pub const Details = struct {
    gpa: std.mem.Allocator,
    /// The text fields shown, by id, filled from the document when first shown.
    fields: std.AutoHashMapUnmanaged(u32, Edit) = .empty,
    /// What the fields were filled for; another selection fills them again.
    filled_for: ?struct { layer: usize, selection: document_zig.Selection } = null,
    /// Why the last edit was refused.
    message: ?[]const u8 = null,
    /// The selected blend state's points, drawn where they sit.
    plot: BlendPlot = .{},
    /// How wide the details are, for the plot.
    width: f32 = 300,

    pub fn deinit(self: *Details) void {
        self.fields.deinit(self.gpa);
    }

    /// Fill every field from the document again, as after an undo.
    pub fn forget(self: *Details) void {
        self.fields.clearRetainingCapacity();
        self.filled_for = null;
        self.message = null;
    }

    /// Whether a point is being dragged on the plot, so edits wait for it.
    pub fn holding(self: *const Details) bool {
        return self.plot.holding();
    }

    /// A pointer event over the page, for the plot of the selected blend state. The number
    /// fields are filled again from what it moved.
    pub fn plotPointer(self: *Details, document: *Document, event: ui.input.Event) @import("blend_plot.zig").Result {
        const index = switch (document.selection) {
            .state => |index| index,
            else => return .{},
        };
        const list = switch (document.states()[index].motion) {
            .clip, .none => return .{},
            .blend_1d => |blend| blend.points,
            .blend_2d => |blend| blend.points,
        };
        const result = self.plot.pointer(document_zig.mutable(format.Point, list), event);
        if (result.changed) self.fields.clearRetainingCapacity();
        return result;
    }

    /// Build the details of `document`'s selection, `width` wide. Returns whether the document
    /// changed.
    pub fn build(self: *Details, context: *ui.Context, document: *Document, clips: Clips, width: f32) !bool {
        self.width = width;
        // Unplaced until drawn, so a press where it was last shown isn't taken for it.
        self.plot.area = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const now: @TypeOf(self.filled_for.?) = .{ .layer = document.layer, .selection = document.selection };
        if (self.filled_for == null or !std.meta.eql(self.filled_for.?, now)) {
            self.fields.clearRetainingCapacity();
            self.filled_for = now;
            self.message = null;
        }
        if (self.message) |message| context.alert(message, "", true);
        var changed = false;
        context.begin(.column);
        switch (document.selection) {
            .layer => changed = try self.layerForm(context, document),
            .state => |index| changed = try self.stateForm(context, document, index, clips),
            .transition => |index| changed = try self.transitionForm(context, document, index),
            .parameter => |index| changed = try self.parameterForm(context, document, index),
        }
        context.end();
        restyle(context, .{ .gap = 14, .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 } });
        return changed;
    }

    fn layerForm(self: *Details, context: *ui.Context, document: *Document) !bool {
        const shown = document.shown();
        var changed = false;
        var rows = SettingRows{};
        setting_rows.beginGroup(context);
        rows.begin(context, "Name", "");
        if (self.text(context, "layer name", shown.name)) |name| if (name.len > 0) {
            shown.name = try document.own(name);
            changed = true;
        };
        rows.end(context);
        if (document.layer > 0) {
            rows.begin(context, "Bone", "It moves this bone and those below it.");
            if (self.text(context, "layer bone", shown.bone)) |bone| {
                shown.bone = try document.own(bone);
                changed = true;
            }
            rows.end(context);
        }
        if (shown.states.len > 0) {
            rows.begin(context, "Starts in", "");
            const arena = context.builder().allocator;
            const names = try arena.alloc([]const u8, shown.states.len);
            for (names, shown.states) |*name, each| name.* = each.name;
            var chosen = shown.entryIndex() orelse 0;
            if (context.select("##graph layer entry", names, &chosen)) {
                shown.entry = shown.states[chosen].name;
                changed = true;
            }
            restyle(context, .{ .width = SettingRows.control_width });
            rows.end(context);
        }
        setting_rows.endGroup(context);
        if (shown.states.len == 0) context.muted("No states yet.");
        if (document.graph().layers.len > 1 and context.buttonVariant("Remove layer##graph remove layer", .destructive)) {
            try document.removeLayer();
            changed = true;
        }
        return changed;
    }

    fn stateForm(self: *Details, context: *ui.Context, document: *Document, index: usize, clips: Clips) !bool {
        const each = &document.states()[index];
        var changed = false;
        var rows = SettingRows{};
        setting_rows.beginGroup(context);
        rows.begin(context, "Name", "");
        if (self.text(context, "state name", each.name)) |name| {
            document.renameState(index, name) catch |err| {
                self.message = switch (err) {
                    error.DuplicateName => "Another state has that name.",
                    error.EmptyName => "A state needs a name.",
                    else => "That name can't be used.",
                };
            };
            changed = true;
        }
        rows.end(context);
        rows.begin(context, "Plays", "");
        var kind: usize = @backingInt(std.meta.activeTag(each.motion));
        if (context.select("##graph state motion", &motion_labels, &kind)) {
            each.motion = switch (kind) {
                0 => .{ .clip = .{} },
                1 => .{ .blend_1d = .{} },
                2 => .{ .blend_2d = .{} },
                else => .none,
            };
            changed = true;
        }
        restyle(context, .{ .width = SettingRows.control_width });
        rows.end(context);
        switch (each.motion) {
            .clip => |*clip| {
                rows.begin(context, "Clip", "");
                if (clipField(context, "graph state clip", clip.clip, clips)) |key| {
                    clip.clip = try document.own(key);
                    changed = true;
                }
                rows.end(context);
                rows.begin(context, "Speed", "");
                if (self.number(context, "state speed", clip.speed)) |speed| {
                    clip.speed = speed;
                    changed = true;
                }
                rows.end(context);
                rows.begin(context, "Repeats", "");
                var repeat: usize = @backingInt(clip.repeat);
                if (context.select("##graph state repeat", &repeat_labels, &repeat)) {
                    clip.repeat = @fromBackingInt(@intCast(repeat));
                    changed = true;
                }
                restyle(context, .{ .width = SettingRows.control_width });
                rows.end(context);
            },
            .blend_1d => |*blend| {
                rows.begin(context, "Axis", "");
                if (try floatField(context, document, "graph blend axis", blend.parameter)) |name| {
                    blend.parameter = name;
                    changed = true;
                }
                rows.end(context);
            },
            .blend_2d => |*blend| for (&blend.parameters, [_][]const u8{ "Across", "Up" }, 0..) |*axis, title, slot| {
                rows.begin(context, title, "");
                if (try floatField(context, document, try std.fmt.allocPrint(context.builder().allocator, "graph blend axis {d}", .{slot}), axis.*)) |name| {
                    axis.* = name;
                    changed = true;
                }
                rows.end(context);
            },
            .none => {},
        }
        if (each.motion != .none) {
            rows.begin(context, "Root motion", "");
            var root_motion: usize = @backingInt(each.root_motion);
            if (context.select("##graph state root motion", &root_motion_labels, &root_motion)) {
                each.root_motion = @fromBackingInt(@intCast(root_motion));
                changed = true;
            }
            restyle(context, .{ .width = SettingRows.control_width });
            rows.end(context);
            rows.begin(context, "Start (s)", "");
            if (self.number(context, "state start", each.start_s)) |start_s| if (start_s >= 0) {
                each.start_s = start_s;
                changed = true;
            };
            rows.end(context);
        }
        setting_rows.endGroup(context);

        switch (each.motion) {
            .clip, .none => {},
            .blend_1d => |*blend| {
                try self.plot.build(context, blend.points, 1, .{ blend.parameter, "" }, try pointLabels(context.builder().allocator, blend.points, clips), self.width - 32);
                changed = try self.points(context, document, &blend.points, 1, clips) or changed;
            },
            .blend_2d => |*blend| {
                try self.plot.build(context, blend.points, 2, blend.parameters, try pointLabels(context.builder().allocator, blend.points, clips), self.width - 32);
                changed = try self.points(context, document, &blend.points, 2, clips) or changed;
            },
        }

        context.begin(.row);
        const shown = document.shown();
        if (!std.mem.eql(u8, shown.entry, each.name) and context.buttonVariant("Start here##graph entry", .outline)) {
            shown.entry = each.name;
            changed = true;
        }
        if (context.buttonVariant("Remove state##graph remove state", .destructive)) {
            try document.removeState(index);
            changed = true;
        }
        page_style.endRow(context);
        return changed;
    }

    /// A blend state's points, a card each: its clip, where it sits (`axes` numbers) and its
    /// rate, then a button to add another. One-axis points are kept in order.
    fn points(self: *Details, context: *ui.Context, document: *Document, list: *[]const format.Point, comptime axes: usize, clips: Clips) !bool {
        const arena = context.builder().allocator;
        var changed = false;
        var removed: ?usize = null;
        const editable = document_zig.mutable(format.Point, list.*);
        for (editable, 0..) |*point, index| {
            var rows = SettingRows{};
            setting_rows.beginGroup(context);
            rows.begin(context, "Clip", "");
            if (clipField(context, try std.fmt.allocPrint(arena, "graph point clip {d}", .{index}), point.clip, clips)) |key| {
                point.clip = try document.own(key);
                changed = true;
            }
            if (rows.endWithButton(context, "", .{ .glyph = remove_glyph, .label = "Remove point", .id = try std.fmt.allocPrint(arena, "graph remove point {d}", .{index}) })) removed = index;
            const titles = if (axes == 1) [_][]const u8{"At"} else [_][]const u8{ "Across", "Up" };
            for (titles, 0..) |title, axis| {
                rows.begin(context, title, "");
                if (self.number(context, try std.fmt.allocPrint(arena, "point {d} at {d}", .{ index, axis }), point.at[axis])) |at| {
                    point.at[axis] = at;
                    changed = true;
                }
                rows.end(context);
            }
            rows.begin(context, "Speed", "");
            if (self.number(context, try std.fmt.allocPrint(arena, "point {d} speed", .{index}), point.speed)) |speed| {
                point.speed = speed;
                changed = true;
            }
            rows.end(context);
            setting_rows.endGroup(context);
        }
        if (removed) |index| {
            list.* = try document_zig.without(format.Point, document.arena(), list.*, index);
            self.fields.clearRetainingCapacity();
            changed = true;
        }
        if (axes == 1 and changed) {
            // Points along one axis go in order, as the format asks.
            std.mem.sort(format.Point, document_zig.mutable(format.Point, list.*), {}, struct {
                fn less(_: void, a: format.Point, b: format.Point) bool {
                    return a.at[0] < b.at[0];
                }
            }.less);
        }
        if (list.len < format.max_points and context.buttonVariant(plus_glyph ++ "  Add clip##graph add point", .outline)) {
            const last: [2]f32 = if (list.len > 0) list.*[list.len - 1].at else .{ -1, 0 };
            list.* = try document_zig.appended(format.Point, document.arena(), list.*, .{ .at = if (axes == 1) .{ last[0] + 1, 0 } else .{ 0, 0 } });
            self.fields.clearRetainingCapacity();
            changed = true;
        }
        return changed;
    }

    fn transitionForm(self: *Details, context: *ui.Context, document: *Document, index: usize) !bool {
        const arena = context.builder().allocator;
        const each = &document.transitions()[index];
        var changed = false;
        context.text(try std.fmt.allocPrint(arena, "{s}  \u{f061}  {s}", .{ if (each.from.len == 0) "Any state" else each.from, each.to }));
        page_style.smallText(context, 15);

        const parameters = document.graph().parameters;
        var removed: ?usize = null;
        for (document_zig.mutable(format.Condition, each.conditions), 0..) |*condition, slot| {
            context.begin(.row);
            const names = try arena.alloc([]const u8, parameters.len);
            for (names, parameters) |*name, parameter| name.* = parameter.name;
            var chosen = document.graph().parameterIndex(condition.parameter) orelse 0;
            if (context.select(try std.fmt.allocPrint(arena, "##graph condition parameter {d}", .{slot}), names, &chosen)) {
                condition.parameter = parameters[chosen].name;
                if (!condition.check.fits(parameters[chosen].kind)) condition.check = document_zig.defaultCheck(parameters[chosen].kind);
                changed = true;
            }
            restyle(context, .{ .grow = 1 });
            const kind = parameters[document.graph().parameterIndex(condition.parameter) orelse 0].kind;
            var fitting: std.ArrayList([]const u8) = .empty;
            var checks: std.ArrayList(format.Check) = .empty;
            var check_index: usize = 0;
            for (std.enums.values(format.Check), check_labels) |check, label| if (check.fits(kind)) {
                if (check == condition.check) check_index = checks.items.len;
                try fitting.append(arena, label);
                try checks.append(arena, check);
            };
            if (context.select(try std.fmt.allocPrint(arena, "##graph condition check {d}", .{slot}), fitting.items, &check_index)) {
                condition.check = checks.items[check_index];
                changed = true;
            }
            restyle(context, .{ .width = 104 });
            if (condition.check == .above or condition.check == .below) {
                if (self.number(context, try std.fmt.allocPrint(arena, "condition {d} value", .{slot}), condition.value)) |value| {
                    condition.value = value;
                    changed = true;
                }
                restyle(context, .{ .width = 64 });
            }
            if (context.buttonVariant(try std.fmt.allocPrint(arena, remove_glyph ++ "##graph remove condition {d}", .{slot}), .ghost)) removed = slot;
            context.tooltip("Remove condition");
            page_style.endRow(context);
        }
        if (removed) |slot| {
            try document.removeCondition(index, slot);
            self.fields.clearRetainingCapacity();
            changed = true;
        }
        if (each.conditions.len == 0) context.muted("With no conditions, it goes as soon as it may.");
        if (parameters.len == 0) {
            context.muted("No parameters to test yet.");
        } else if (context.buttonVariant(plus_glyph ++ "  Add condition##graph add condition", .ghost)) {
            try document.addCondition(index);
            changed = true;
        }

        var rows = SettingRows{};
        setting_rows.beginGroup(context);
        rows.begin(context, "Blend", "Seconds the next state takes to fade in.");
        if (self.number(context, "transition blend", each.blend_s)) |blend_s| if (blend_s >= 0) {
            each.blend_s = blend_s;
            changed = true;
        };
        rows.end(context);
        rows.begin(context, "Wait for the clip to end", "");
        if (context.toggle("##graph wait for end", &each.wait_for_end)) changed = true;
        rows.end(context);
        setting_rows.endGroup(context);

        if (context.buttonVariant("Remove transition##graph remove transition", .destructive)) {
            try document.removeTransition(index);
            changed = true;
        }
        return changed;
    }

    fn parameterForm(self: *Details, context: *ui.Context, document: *Document, index: usize) !bool {
        const each = &document.parameters()[index];
        var changed = false;
        var rows = SettingRows{};
        setting_rows.beginGroup(context);
        rows.begin(context, "Name", "");
        if (self.text(context, "parameter name", each.name)) |name| {
            document.renameParameter(index, name) catch |err| {
                self.message = switch (err) {
                    error.DuplicateName => "Another parameter has that name.",
                    error.EmptyName => "A parameter needs a name.",
                    else => "That name can't be used.",
                };
            };
            changed = true;
        }
        rows.end(context);
        rows.begin(context, "Kind", "");
        var kind: usize = @backingInt(each.kind);
        if (context.select("##graph parameter kind", &kind_labels, &kind)) {
            try document.setParameterKind(index, @fromBackingInt(@intCast(kind)));
            self.fields.clearRetainingCapacity();
            changed = true;
        }
        restyle(context, .{ .width = SettingRows.control_width });
        rows.end(context);
        switch (each.kind) {
            .float => {
                rows.begin(context, "Default", "");
                if (self.number(context, "parameter default", each.default)) |value| {
                    each.default = value;
                    changed = true;
                }
                rows.end(context);
            },
            .bool => {
                rows.begin(context, "On at first", "");
                var on = each.default > 0.5;
                if (context.toggle("##graph parameter default", &on)) {
                    each.default = if (on) 1 else 0;
                    changed = true;
                }
                rows.end(context);
            },
            .trigger => {},
        }
        setting_rows.endGroup(context);
        if (context.buttonVariant("Remove parameter##graph remove parameter", .destructive)) {
            try document.removeParameter(index);
            changed = true;
        }
        return changed;
    }

    /// A text field `name` showing `current`; the new text when it was typed this frame.
    fn text(self: *Details, context: *ui.Context, comptime name: []const u8, current: []const u8) ?[]const u8 {
        const edit = self.field(context, name, current) orelse return null;
        if (!context.textInput("##graph " ++ name, edit, "")) return null;
        return std.mem.trim(u8, edit.text(), " ");
    }

    /// A number field named `name` showing `current`; the new value when one was typed this
    /// frame that reads as a number.
    fn number(self: *Details, context: *ui.Context, name: []const u8, current: f32) ?f32 {
        var buffer: [32]u8 = undefined;
        const shown = std.fmt.bufPrint(&buffer, "{d}", .{current}) catch "";
        const edit = self.field(context, name, shown) orelse return null;
        const label = std.fmt.allocPrint(context.builder().allocator, "##graph {s}", .{name}) catch return null;
        if (!context.textInput(label, edit, "")) return null;
        restyle(context, .{ .width = 96 });
        const value = std.fmt.parseFloat(f32, std.mem.trim(u8, edit.text(), " ")) catch return null;
        return if (std.math.isFinite(value)) value else null;
    }

    /// The field `name`'s edit, filled with `current` the first time it shows.
    fn field(self: *Details, context: *ui.Context, name: []const u8, current: []const u8) ?*Edit {
        const found = self.fields.getOrPut(self.gpa, context.idFor(name)) catch return null;
        if (!found.found_existing) {
            found.value_ptr.* = .{};
            found.value_ptr.set(current) catch {};
        }
        return found.value_ptr;
    }
};

/// What each point plays, by its clip's file name without folder or extension.
fn pointLabels(arena: std.mem.Allocator, list: []const format.Point, clips: Clips) ![]const []const u8 {
    const labels = try arena.alloc([]const u8, list.len);
    for (labels, list) |*label, point| {
        label.* = "no clip";
        for (clips.keys, clips.names) |key, name| if (std.mem.eql(u8, key, point.clip)) {
            const base = std.fs.path.basename(name);
            label.* = base[0 .. std.mem.indexOfScalar(u8, base, '.') orelse base.len];
        };
    }
    return labels;
}

/// A menu of `clips` showing `current` (an asset key); the key picked this frame, if any.
fn clipField(context: *ui.Context, id: []const u8, current: []const u8, clips: Clips) ?[]const u8 {
    const arena = context.builder().allocator;
    const labels = arena.alloc([]const u8, clips.names.len + 1) catch return null;
    labels[0] = "None";
    @memcpy(labels[1..], clips.names);
    var chosen: usize = 0;
    for (clips.keys, 1..) |key, index| if (std.mem.eql(u8, key, current)) {
        chosen = index;
    };
    const picked = context.select(std.fmt.allocPrint(arena, "##{s}", .{id}) catch return null, labels, &chosen);
    restyle(context, .{ .width = SettingRows.control_width });
    if (!picked) return null;
    return if (chosen == 0) "" else clips.keys[chosen - 1];
}

/// A menu of the graph's float parameters showing `current`; the one picked this frame, if any.
fn floatField(context: *ui.Context, document: *Document, id: []const u8, current: []const u8) !?[]const u8 {
    const arena = context.builder().allocator;
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(arena, "None");
    var chosen: usize = 0;
    for (document.graph().parameters) |parameter| if (parameter.kind == .float) {
        if (std.mem.eql(u8, parameter.name, current)) chosen = names.items.len;
        try names.append(arena, parameter.name);
    };
    const picked = context.select(try std.fmt.allocPrint(arena, "##{s}", .{id}), names.items, &chosen);
    restyle(context, .{ .width = SettingRows.control_width });
    if (!picked) return null;
    return if (chosen == 0) "" else names.items[chosen];
}
