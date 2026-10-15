//! The Inspector's view of the entity selected in the Hierarchy: a card per component it has,
//! each field with the control its kind calls for (the rest as ZON text), Remove on each card,
//! and Add component for the types it doesn't have yet. Values are read from the world every
//! frame, so a field a system changes changes here too, except one being typed into.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ecs = eggy.ecs;
const components = eggy.components;
const HotGame = @import("../hot_reload/hot_reload.zig").HotGame;
const page_style = @import("../page_style.zig");
const restyle = page_style.restyle;

const FieldEdit = ui.TextEdit(256);
const control_width: f32 = 170;

pub const EntityInspector = struct {
    gpa: std.mem.Allocator,
    /// The text of each field shown as a text box, by `fieldKey`, for the entity shown.
    edits: std.AutoHashMapUnmanaged(u32, FieldEdit) = .empty,
    /// The field typed into last frame, which keeps its text rather than the world's.
    focused_field: ?u32 = null,
    /// The entity `edits` are for.
    shown: ?ecs.EntityId = null,

    pub fn init(gpa: std.mem.Allocator) EntityInspector {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *EntityInspector) void {
        self.edits.deinit(self.gpa);
    }

    /// Draw `entity`'s components into `context`. `game` has their types; without it there is
    /// nothing to show but the entity.
    pub fn build(self: *EntityInspector, context: *ui.Context, app: *eggy.App, game: ?*const HotGame, entity: ecs.EntityId) void {
        const arena = context.builder().allocator;
        if (self.shown == null or !self.shown.?.eql(entity)) {
            self.edits.clearRetainingCapacity();
            self.focused_field = null;
            self.shown = entity;
        }

        context.heading(3, std.fmt.allocPrint(arena, "Entity {d}", .{entity.id}) catch "Entity");
        const loaded = game orelse {
            context.muted("The game's library didn't load, so its components can't be shown.");
            return;
        };
        if (loaded.component_types.len == 0) {
            context.muted("Your game and plugins list no components yet. List them with `pub const components = .{ ... };` in your game or a plugin.");
            page_style.smallText(context, 13);
            return;
        }

        var focused: ?u32 = null;
        var has_any = false;
        for (loaded.component_types, 0..) |info, component| {
            if (!loaded.hasComponent(app, entity, component)) continue;
            has_any = true;
            self.componentCard(context, app, loaded, entity, info, component, &focused);
        }
        self.focused_field = focused;
        if (!has_any) {
            context.muted("No components. Add one below.");
            page_style.smallText(context, 13);
        }
        addComponentPicker(context, app, loaded, entity);
    }

    /// A card for `entity`'s component `component`: its name and owner, Remove, and its fields.
    fn componentCard(self: *EntityInspector, context: *ui.Context, app: *eggy.App, game: *const HotGame, entity: ecs.EntityId, info: components.Info, component: usize, focused: *?u32) void {
        const arena = context.builder().allocator;
        context.begin(.card);

        context.begin(.row);
        context.begin(.column);
        context.text(info.name);
        context.muted(std.fmt.allocPrint(arena, "from {s}", .{info.owner}) catch "");
        page_style.smallText(context, 12);
        context.end();
        restyle(context, .{ .grow = 1, .gap = 2 });
        if (context.buttonVariant(std.fmt.allocPrint(arena, "Remove##remove {d}", .{component}) catch return, .ghost)) {
            game.removeComponent(app, entity, component);
        }
        context.end();
        restyle(context, .{ .direction = .row, .gap = 12, .align_items = .center });

        for (info.fields, 0..) |field, index| self.fieldRow(context, app, game, entity, component, field, index, focused);

        context.end();
        restyle(context, .{ .gap = 8, .padding = .{ .left = 14, .right = 14, .top = 12, .bottom = 12 } });
    }

    /// One field: its name on the left, its control on the right.
    fn fieldRow(self: *EntityInspector, context: *ui.Context, app: *eggy.App, game: *const HotGame, entity: ecs.EntityId, component: usize, field: components.Field, index: usize, focused: *?u32) void {
        const arena = context.builder().allocator;
        var buffer: [256]u8 = undefined;
        const value = game.readField(app, entity, component, index, &buffer) orelse "";
        const key = fieldKey(component, index);
        // Controls take their ids from their (hidden) label: the component and field.
        const hidden = std.fmt.allocPrint(arena, "##{d}.{s}", .{ component, field.name }) catch return;

        context.begin(.row);
        context.text(displayName(arena, field.name));
        page_style.smallText(context, 13);
        restyle(context, .{ .grow = 1 });
        context.begin(.column);
        if (!field.editable) {
            context.muted(value);
            page_style.noteText(context);
        } else switch (field.kind) {
            .bool => {
                var on = std.mem.eql(u8, value, "true");
                if (context.toggle(hidden, &on)) self.write(app, game, entity, component, index, if (on) "true" else "false");
            },
            .@"enum" => {
                const options = arena.alloc([]const u8, field.options.len) catch return;
                var selected: usize = 0;
                for (options, field.options, 0..) |*option, name, i| {
                    option.* = displayName(arena, name);
                    if (value.len > 1 and std.mem.eql(u8, value[1..], name)) selected = i;
                }
                if (context.select(hidden, options, &selected)) {
                    self.write(app, game, entity, component, index, std.fmt.allocPrint(arena, ".{s}", .{field.options[selected]}) catch return);
                }
            },
            .int, .float, .other => {
                // The world's value, unless this field is being typed into.
                const entry = self.edits.getOrPut(self.gpa, key) catch return;
                if (!entry.found_existing or self.focused_field != key) entry.value_ptr.* = FieldEdit.init(value) catch FieldEdit.init("") catch unreachable;
                if (context.textInput(hidden, entry.value_ptr, "")) self.write(app, game, entity, component, index, std.mem.trim(u8, entry.value_ptr.text(), " "));
                if (context.last_added) |input| if (context.focus == input.id) {
                    focused.* = key;
                };
            },
        }
        context.end();
        restyle(context, .{ .width = control_width, .align_items = .end });
        context.end();
        restyle(context, .{ .direction = .row, .gap = 12, .align_items = .center });
    }

    /// Set a field from `text` (ZON); text that doesn't parse leaves it as it was, until fixed.
    fn write(_: *EntityInspector, app: *eggy.App, game: *const HotGame, entity: ecs.EntityId, component: usize, field: usize, text: []const u8) void {
        var buffer: [257]u8 = undefined;
        const terminated = std.fmt.bufPrintZ(&buffer, "{s}", .{text}) catch return;
        _ = game.writeField(app, entity, component, field, terminated);
    }
};

/// A dropdown of the component types `entity` doesn't have and the editor can add; picking one
/// adds it.
fn addComponentPicker(context: *ui.Context, app: *eggy.App, game: *const HotGame, entity: ecs.EntityId) void {
    const arena = context.builder().allocator;
    var labels: std.ArrayList([]const u8) = .empty;
    var types: std.ArrayList(usize) = .empty;
    labels.append(arena, "Add component...") catch return;
    types.append(arena, 0) catch return;
    for (game.component_types, 0..) |info, component| {
        if (!info.addable or game.hasComponent(app, entity, component)) continue;
        labels.append(arena, std.fmt.allocPrint(arena, "{s}  ({s})", .{ info.name, info.owner }) catch continue) catch return;
        types.append(arena, component) catch return;
    }
    if (labels.items.len == 1) return;
    var picked: usize = 0;
    if (context.select("##add component", labels.items, &picked) and picked > 0) _ = game.addComponent(app, entity, types.items[picked]);
}

/// A field's key in `EntityInspector.edits`.
fn fieldKey(component: usize, field: usize) u32 {
    return @intCast(component << 16 | field);
}

/// `turns_per_second` as "Turns per second". In `arena`.
fn displayName(arena: std.mem.Allocator, name: []const u8) []const u8 {
    const label = arena.dupe(u8, name) catch return name;
    for (label) |*char| if (char.* == '_') {
        char.* = ' ';
    };
    if (label.len > 0) label[0] = std.ascii.toUpper(label[0]);
    return label;
}
