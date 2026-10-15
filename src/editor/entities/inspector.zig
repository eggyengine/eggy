//! The Inspector's view of the entity selected in the Hierarchy: its name, then a card per
//! component, each field with the control its kind calls for (the rest as ZON text). A card's
//! header folds it away; Remove takes the component off; Add component offers the types it
//! doesn't have. Values are read from the world every frame, so fields a system changes change
//! here too, except one being typed into.
//!
//! Like the Hierarchy, the page doesn't change the world itself: `build` returns the `Action` the
//! user took.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ecs = eggy.ecs;
const components = eggy.components;
const page_style = @import("../page_style.zig");
const restyle = page_style.restyle;

/// What the Inspector shows: the entity, its name, and its components with their values.
pub const Details = struct {
    entity: ecs.EntityId,
    name: []const u8,
    components: []const Component,
    /// The component types it doesn't have and can be given, as `(index, label)`.
    addable: []const Addable,

    pub const Component = struct {
        /// Its index among the game's component types.
        index: usize,
        info: components.Info,
        /// Each field's value as ZON; null where it can't be read.
        values: []const ?[]const u8,
    };
    pub const Addable = struct { index: usize, label: []const u8 };
};

pub const Action = union(enum) {
    rename: []const u8,
    set_field: struct { component: usize, field: usize, text: []const u8 },
    add_component: usize,
    remove_component: usize,
};

const FieldEdit = ui.TextEdit(256);
const NameEdit = ui.TextEdit(eggy.Name.max_len);
const control_width: f32 = 160;
/// A dropdown's text size, and the room its padding and chevron take beside the text.
const select_text_size: f32 = 14;
const select_chrome: f32 = 48;
/// The narrowest a field's control gets in a narrow Inspector.
const min_control_width: f32 = 80;

pub const EntityInspector = struct {
    gpa: std.mem.Allocator,
    name: NameEdit = NameEdit.init("") catch unreachable,
    /// The text of each field shown as a text box, by `fieldKey`, for the entity shown.
    edits: std.AutoHashMapUnmanaged(u32, FieldEdit) = .empty,
    /// The text box typed into last frame (`name_key` for the name), which keeps its text
    /// rather than the world's.
    focused: ?u32 = null,
    /// Components folded away, by index.
    folded: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// The entity the state above is for.
    shown: ?ecs.EntityId = null,

    const name_key = std.math.maxInt(u32);

    pub fn init(gpa: std.mem.Allocator) EntityInspector {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *EntityInspector) void {
        self.edits.deinit(self.gpa);
        self.folded.deinit(self.gpa);
    }

    /// Draw `details` into `context`. Returns what the user did this frame, if anything.
    pub fn build(self: *EntityInspector, context: *ui.Context, details: Details) ?Action {
        const arena = context.builder().allocator;
        if (self.shown == null or !self.shown.?.eql(details.entity)) {
            self.edits.clearRetainingCapacity();
            self.folded.clearRetainingCapacity();
            self.focused = null;
            self.shown = details.entity;
        }
        var action: ?Action = null;
        var focused: ?u32 = null;

        // The name, typed into directly; "Entity N" until it has one.
        if (self.focused != name_key) self.name = NameEdit.init(details.name) catch NameEdit.init("") catch unreachable;
        const placeholder = std.fmt.allocPrint(arena, "Entity {d}", .{details.entity.id}) catch "Entity";
        if (context.textInput("##entity name", &self.name, placeholder)) action = .{ .rename = arena.dupe(u8, self.name.text()) catch "" };
        if (context.last_added) |input| if (context.focus == input.id) {
            focused = name_key;
        };
        context.muted(std.fmt.allocPrint(arena, "Entity {d} · {d} component{s}", .{ details.entity.id, details.components.len, if (details.components.len == 1) "" else "s" }) catch "");
        page_style.smallText(context, 12);

        // Adding a component comes first, above the ones it has.
        const width = context.contentWidth();
        if (addComponentPicker(context, details.addable, width)) |index| action = .{ .add_component = index };
        if (details.components.len == 0) {
            context.muted("No components yet.");
            page_style.smallText(context, 13);
        }
        const field_control = std.math.clamp(width * 0.45, min_control_width, control_width);
        for (details.components) |component| if (self.componentCard(context, component, field_control, &focused)) |card_action| {
            action = card_action;
        };
        self.focused = focused;
        return action;
    }

    /// A card for one component: a header (fold, name, owner, Remove), then its fields.
    fn componentCard(self: *EntityInspector, context: *ui.Context, component: Details.Component, field_control: f32, focused: *?u32) ?Action {
        const arena = context.builder().allocator;
        const b = context.builder();
        var action: ?Action = null;
        const folded = self.folded.contains(component.index);
        context.begin(.card);

        // The header folds the card when pressed.
        context.begin(.row);
        const fold_id = context.idFor(std.fmt.allocPrint(arena, "fold {d}", .{component.index}) catch return null);
        if (context.activated(fold_id)) {
            if (folded) _ = self.folded.remove(component.index) else self.folded.put(self.gpa, component.index, {}) catch {};
        }
        const header = b.node(fold_id, .{ .direction = .row, .gap = 8, .align_items = .center, .grow = 1 }, .none, &.{
            b.node(0, .{ .width = 14, .height = 14 }, .{ .icon = if (folded) .chevron_right else .chevron_down }, &.{}) catch return null,
            b.node(0, .{ .grow = 1, .gap = 1 }, .none, &.{
                b.node(0, .{}, .{ .text = .{ .value = component.info.name, .size = 14, .wrap = true } }, &.{}) catch return null,
                b.node(0, .{}, .{ .text = .{ .value = std.fmt.allocPrint(arena, "from {s}", .{component.info.owner}) catch "", .size = 11, .tone = .muted, .wrap = true } }, &.{}) catch return null,
            }) catch return null,
        }) catch return null;
        header.cursor = .pointer;
        header.accessibility = .{ .role = .button, .label = component.info.name, .expanded = !folded };
        context.element(header);
        if (context.buttonVariant(std.fmt.allocPrint(arena, "Remove##remove {d}", .{component.index}) catch return null, .ghost)) action = .{ .remove_component = component.index };
        context.end();
        restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center });

        if (!folded) for (component.info.fields, component.values, 0..) |field, value, index| {
            if (self.fieldRow(context, component.index, field, value orelse "", index, field_control, focused)) |field_action| action = field_action;
        };

        context.end();
        restyle(context, .{ .gap = 8, .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 } });
        return action;
    }

    /// One field: its name on the left (wrapping if need be), its control on the right.
    fn fieldRow(self: *EntityInspector, context: *ui.Context, component: usize, field: components.Field, value: []const u8, index: usize, field_control: f32, focused: *?u32) ?Action {
        const arena = context.builder().allocator;
        const key = fieldKey(component, index);
        // Controls take their ids from their (hidden) label: the component and field.
        const hidden = std.fmt.allocPrint(arena, "##{d}.{s}", .{ component, field.name }) catch return null;
        var action: ?Action = null;

        context.begin(.row);
        context.text(displayName(arena, field.name));
        page_style.smallText(context, 13);
        restyle(context, .{ .grow = 1 });
        context.begin(.column);
        if (!field.editable) {
            context.muted(value);
            page_style.noteText(context);
            if (context.last_added) |text| text.paint_kind.text.wrap = true;
        } else switch (field.kind) {
            .bool => {
                var on = std.mem.eql(u8, value, "true");
                if (context.toggle(hidden, &on)) action = .{ .set_field = .{ .component = component, .field = index, .text = if (on) "true" else "false" } };
            },
            .@"enum" => {
                const options = arena.alloc([]const u8, field.options.len) catch return null;
                var selected: usize = 0;
                for (options, field.options, 0..) |*option, name, i| {
                    option.* = page_style.fitText(arena, context.font, displayName(arena, name), select_text_size, field_control - select_chrome);
                    if (value.len > 1 and std.mem.eql(u8, value[1..], name)) selected = i;
                }
                if (context.select(hidden, options, &selected)) action = .{ .set_field = .{ .component = component, .field = index, .text = std.fmt.allocPrint(arena, ".{s}", .{field.options[selected]}) catch return null } };
                // The dropdown keeps to the column rather than its own minimum width.
                if (context.last_added) |trigger| if (trigger.id != 0 and trigger.overlay == null) {
                    trigger.style.min_width = 0;
                };
            },
            .int, .float, .other => {
                // The world's value, unless this field is being typed into.
                const entry = self.edits.getOrPut(self.gpa, key) catch return null;
                if (!entry.found_existing or self.focused != key) entry.value_ptr.* = FieldEdit.init(value) catch FieldEdit.init("") catch unreachable;
                if (context.textInput(hidden, entry.value_ptr, "")) action = .{ .set_field = .{ .component = component, .field = index, .text = arena.dupe(u8, std.mem.trim(u8, entry.value_ptr.text(), " ")) catch return null } };
                if (context.last_added) |input| if (context.focus == input.id) {
                    focused.* = key;
                };
            },
        }
        context.end();
        restyle(context, .{ .width = field_control, .align_items = .end });
        context.end();
        restyle(context, .{ .direction = .row, .gap = 10, .align_items = .center });
        return action;
    }
};

/// A dropdown of the component types that can be added; picking one returns its index.
fn addComponentPicker(context: *ui.Context, addable: []const Details.Addable, width: f32) ?usize {
    if (addable.len == 0) return null;
    const arena = context.builder().allocator;
    const labels = arena.alloc([]const u8, addable.len + 1) catch return null;
    labels[0] = "Add component...";
    for (labels[1..], addable) |*label, choice| label.* = page_style.fitText(arena, context.font, choice.label, select_text_size, width - select_chrome);
    var picked: usize = 0;
    const changed = context.select("##add component", labels, &picked);
    if (context.last_added) |trigger| if (trigger.overlay == null) {
        trigger.style.min_width = 0;
    };
    return if (changed and picked > 0) addable[picked - 1].index else null;
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

const ui_checks = @import("../ui_checks.zig");

test "a component with long names and values fits a narrow Inspector" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var inspector = EntityInspector.init(std.testing.allocator);
    defer inspector.deinit();

    const fields = [_]components.Field{
        .{ .name = "a_field_with_a_very_long_name_that_wraps", .kind = .float, .editable = true },
        .{ .name = "mode", .kind = .@"enum", .options = &.{ "first_choice_with_a_long_name", "second" }, .editable = true },
        .{ .name = "enabled", .kind = .bool, .editable = true },
        .{ .name = "points", .kind = .other, .editable = false },
    };
    const info = components.Info{ .name = "AComponentWithAnUnreasonablyLongTypeName", .owner = "a_plugin_with_a_long_name", .fields = &fields, .addable = true };
    const values = [_]?[]const u8{ "1234567.25", ".first_choice_with_a_long_name", "true", ".{ .{ 1, 2, 3 }, .{ 4, 5, 6 }, .{ 7, 8, 9 } }" };
    const details = Details{
        .entity = .init(3, 0),
        .name = "An entity with a name long enough to need the whole field and then some",
        .components = &.{.{ .index = 0, .info = info, .values = &values }},
        .addable = &.{.{ .index = 1, .label = "AnotherComponentWithALongName (some_plugin)" }},
    };
    for ([_]f32{ 220, 320, 600 }) |width| {
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = width, .h = 800 };
        context.newFrame(viewport);
        _ = inspector.build(&context, details);
        _ = try context.render();
        try ui_checks.expectFits(context.last_root.?, context.font, viewport);
    }
}
