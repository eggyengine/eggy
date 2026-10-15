//! The Inspector's view of the entity selected in the Hierarchy: its name, then a card per
//! component, each field with the control its kind calls for (the rest as ZON text). A card's
//! header folds it away; Remove takes the component off; Add component opens a search over the
//! types it doesn't have. Values are read from the world every frame, so fields a system changes change
//! here too, except one being typed into.
//!
//! A reference field (`eggy.EntityRef`, `eggy.AssetRef`) is a slot: drag an entity from the
//! Hierarchy or a file from Assets onto it (while dragging, the slots that would take it light
//! up), or clear it with its x.
//!
//! Like the Hierarchy, the page doesn't change the world itself: `build` and `dropAt` return the
//! `Action` the user took.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const ecs = eggy.ecs;
const components = eggy.components;
const page_style = @import("../page_style.zig");
const Dragged = @import("../dragged.zig").Dragged;
const restyle = page_style.restyle;

/// What the Inspector shows: the entity, its name, and its components with their values.
pub const Details = struct {
    entity: ecs.EntityId,
    name: []const u8,
    components: []const Component,
    /// The component types it doesn't have and can be given, as `(index, label)`.
    addable: []const Addable,
    /// What is being dragged from another panel, if anything: the slots that take it light up.
    dragging: ?Dragged = null,

    pub const Component = struct {
        /// Its index among the game's component types.
        index: usize,
        info: components.Info,
        /// Each field's value as ZON; null where it can't be read.
        values: []const ?[]const u8,
        /// Each reference field's value as people read it (an entity's name, a file's); null for
        /// other fields, and empty when unset.
        shown: []const ?[]const u8 = &.{},
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
const SearchEdit = ui.TextEdit(64);
/// The most component types the search lists at once.
const max_listed = 12;
/// The listed types' element ids: `pick_id_base` plus their place in the list.
const pick_id_base: u32 = 0x6D00_0000;
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
    /// Add component's search while it is open, and whether it has had the keyboard yet.
    search: ?struct { edit: SearchEdit, focused: bool = false } = null,
    /// The reference slots last built, to match a drop to.
    slots: std.ArrayList(Slot) = .empty,

    /// A reference field's slot: its element, and which field it sets.
    const Slot = struct { id: u32, component: usize, field: usize, info: components.Field };

    const name_key = std.math.maxInt(u32);
    const search_key = std.math.maxInt(u32) - 1;

    pub fn init(gpa: std.mem.Allocator) EntityInspector {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *EntityInspector) void {
        self.edits.deinit(self.gpa);
        self.folded.deinit(self.gpa);
        self.slots.deinit(self.gpa);
    }

    /// The reference field under `at` in last frame's layout, if any.
    pub fn fieldAt(self: *const EntityInspector, context: *const ui.Context, at: ui.Vec2) ?components.Field {
        const slot = self.slotAt(context, at) orelse return null;
        return slot.info;
    }

    /// `dragged` let go at `at`: set the reference field there, if it takes it.
    pub fn dropAt(self: *const EntityInspector, context: *const ui.Context, at: ui.Vec2, dragged: Dragged, arena: std.mem.Allocator) ?Action {
        const slot = self.slotAt(context, at) orelse return null;
        if (!dragged.fits(slot.info)) return null;
        var buffer: [512]u8 = undefined;
        const text = dragged.zon(&buffer) catch return null;
        return .{ .set_field = .{ .component = slot.component, .field = slot.field, .text = arena.dupe(u8, text) catch return null } };
    }

    fn slotAt(self: *const EntityInspector, context: *const ui.Context, at: ui.Vec2) ?Slot {
        for (self.slots.items) |slot| {
            const bounds = context.last_bounds.get(slot.id) orelse continue;
            if (bounds.rect.contains(at.x, at.y)) return slot;
        }
        return null;
    }

    /// Draw `details` into `context`. Returns what the user did this frame, if anything.
    pub fn build(self: *EntityInspector, context: *ui.Context, details: Details) ?Action {
        const arena = context.builder().allocator;
        if (self.shown == null or !self.shown.?.eql(details.entity)) {
            self.edits.clearRetainingCapacity();
            self.folded.clearRetainingCapacity();
            self.focused = null;
            self.search = null;
            self.shown = details.entity;
        }
        var action: ?Action = null;
        var focused: ?u32 = null;
        self.slots.clearRetainingCapacity();

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
        if (self.addComponentSearch(context, details.addable, width, &focused)) |index| action = .{ .add_component = index };
        if (details.components.len == 0) {
            context.muted("No components yet.");
            page_style.smallText(context, 13);
        }
        const field_control = std.math.clamp(width * 0.45, min_control_width, control_width);
        for (details.components) |component| if (self.componentCard(context, component, field_control, details.dragging, &focused)) |card_action| {
            action = card_action;
        };
        self.focused = focused;
        return action;
    }

    /// A card for one component: a header (fold, name, owner, Remove), then its fields.
    fn componentCard(self: *EntityInspector, context: *ui.Context, component: Details.Component, field_control: f32, dragging: ?Dragged, focused: *?u32) ?Action {
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
            const shown = if (index < component.shown.len) component.shown[index] else null;
            if (self.fieldRow(context, component.index, field, value orelse "", shown, index, field_control, dragging, focused)) |field_action| action = field_action;
        };

        context.end();
        restyle(context, .{ .gap = 8, .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 } });
        return action;
    }

    /// One field: its name on the left (wrapping if need be), its control on the right.
    fn fieldRow(self: *EntityInspector, context: *ui.Context, component: usize, field: components.Field, value: []const u8, shown: ?[]const u8, index: usize, field_control: f32, dragging: ?Dragged, focused: *?u32) ?Action {
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
        if (field.kind == .entity or field.kind == .asset) {
            action = self.referenceSlot(context, component, field, shown orelse "", index, field_control, dragging);
        } else if (!field.editable) {
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
            .entity, .asset => unreachable, // slots, above
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

    /// A reference field's slot: what it points at (`shown`, empty for nothing) and an x to
    /// clear it. Lit while `dragging` would fit it, dimmed while something that wouldn't is.
    fn referenceSlot(self: *EntityInspector, context: *ui.Context, component: usize, field: components.Field, shown: []const u8, index: usize, width: f32, dragging: ?Dragged) ?Action {
        const b = context.builder();
        const arena = b.allocator;
        const id = context.idFor(std.fmt.allocPrint(arena, "##slot {d}.{d}", .{ component, index }) catch return null);
        self.slots.append(self.gpa, .{ .id = id, .component = component, .field = index, .info = field }) catch {};
        var action: ?Action = null;

        const empty = shown.len == 0;
        const hint: []const u8 = switch (field.kind) {
            .entity => if (field.requires.len > 0) std.fmt.allocPrint(arena, "Drop an entity with {s}", .{field.requires}) catch "Drop an entity" else "Drop an entity",
            else => if (field.accepts == .any) "Drop a file" else std.fmt.allocPrint(arena, "Drop a {s} file", .{@tagName(field.accepts)}) catch "Drop a file",
        };
        const clear_room: f32 = if (empty) 0 else 28;
        const label = page_style.fitText(arena, context.font, if (empty) hint else shown, 12, width - 20 - clear_room);
        const look = arena.create(SlotPaint) catch return null;
        look.* = .{ .id = id, .fits = if (dragging) |dragged| dragged.fits(field) else null };
        context.begin(.row);
        const slot = b.node(id, .{ .height = 26, .grow = 1, .padding = .{ .left = 8, .right = 8 }, .align_items = .center, .direction = .row }, .{ .custom = .{ .context = look, .draw = SlotPaint.draw } }, &.{
            b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = label, .size = 12, .tone = if (empty) .muted else .foreground } }, &.{}) catch return null,
        }) catch return null;
        slot.accessibility = .{ .role = .button, .label = if (empty) hint else shown };
        context.element(slot);
        if (!empty) {
            const clear_id = context.idFor(std.fmt.allocPrint(arena, "##clear {d}.{d}", .{ component, index }) catch return null);
            if (context.activated(clear_id)) action = .{ .set_field = .{ .component = component, .field = index, .text = if (field.kind == .entity) "null" else "\"\"" } };
            const clear = b.node(clear_id, .{ .width = 24, .height = 24, .padding = .{ .left = 6, .right = 6, .top = 6, .bottom = 6 } }, .none, &.{
                b.node(0, .{ .width = 12, .height = 12 }, .{ .icon = .x }, &.{}) catch return null,
            }) catch return null;
            clear.cursor = .pointer;
            clear.accessibility = .{ .role = .button, .label = "Clear" };
            context.element(clear);
        }
        context.end();
        restyle(context, .{ .direction = .row, .gap = 4, .align_items = .center, .width = width });
        return action;
    }

    /// Add component: a button that opens a search over the types `addable` lists, each match a
    /// row to pick (Enter picks the first). Returns the index of the type picked.
    fn addComponentSearch(self: *EntityInspector, context: *ui.Context, addable: []const Details.Addable, width: f32, focused: *?u32) ?usize {
        if (addable.len == 0) return null;
        const b = context.builder();
        const arena = b.allocator;
        if (context.buttonVariant(if (self.search == null) "Add component" else "Close##add component", .outline)) {
            self.search = if (self.search == null) .{ .edit = SearchEdit.init("") catch unreachable } else null;
        }
        page_style.restyle(context, .{ .width = width });
        const search = &(self.search orelse return null);

        // The search, focused as it opens so typing goes straight in.
        _ = context.textInput("##component search", &search.edit, "Search components");
        page_style.restyle(context, .{ .width = width });
        if (context.last_added) |input| input.style.min_width = 0;
        // Enter picks the first match; Escape closes the search.
        var enter = false;
        if (context.last_added) |input| {
            if (!search.focused) {
                context.focus = input.id;
                search.focused = true;
            }
            if (context.focus == input.id) {
                focused.* = search_key;
                for (context.pending.items) |item| if (item == .key) switch (item.key.key) {
                    .enter => enter = true,
                    .escape => {
                        self.search = null;
                        return null;
                    },
                    else => {},
                };
            }
        }

        // The types whose name holds what was typed, ignoring case.
        const query = std.mem.trim(u8, search.edit.text(), " ");
        var listed: usize = 0;
        var picked: ?usize = null;
        for (addable) |choice| {
            if (query.len > 0 and std.ascii.indexOfIgnoreCase(choice.label, query) == null) continue;
            if (listed == max_listed) break;
            const id = pick_id_base + @as(u32, @intCast(listed));
            if (context.activated(id) or (enter and listed == 0)) picked = choice.index;
            const label = page_style.fitText(arena, context.font, choice.label, 13, width - 40);
            const row = b.node(id, .{ .height = 24 }, .{ .menu_item = .{ .label = label } }, &.{}) catch return null;
            row.cursor = .pointer;
            row.accessibility = .{ .role = .menu_item, .label = choice.label };
            context.element(row);
            listed += 1;
        }
        if (listed == 0) {
            context.muted("No component matches.");
            page_style.smallText(context, 12);
        }
        if (picked != null) self.search = null;
        return picked;
    }
};

/// How a reference slot is drawn: a field's box, outlined while a drag would fit it.
const SlotPaint = struct {
    id: u32,
    /// Whether what is being dragged would fit; null while nothing is.
    fits: ?bool,

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const SlotPaint = @ptrCast(@alignCast(context));
        const t = c.theme;
        const hovered = c.hot_id == self.id;
        if (self.fits) |fits| {
            if (fits) {
                try c.roundRectAlpha(r, t.primary, t.radiusSm(), if (hovered) 0.25 else 0.1);
                try c.roundRectStroke(r, t.primary, t.radiusSm(), 1.5);
            } else try c.roundRectAlpha(r, t.muted, t.radiusSm(), 0.6);
            return;
        }
        try c.roundRect(r, t.muted, t.radiusSm());
        try c.roundRectStroke(r, t.border, t.radiusSm(), 1);
    }
};

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
        .{ .name = "orbits_around", .kind = .entity, .editable = true, .requires = "SomeComponentWithALongName" },
        .{ .name = "sound", .kind = .asset, .editable = true, .accepts = .audio },
    };
    const info = components.Info{ .name = "AComponentWithAnUnreasonablyLongTypeName", .owner = "a_plugin_with_a_long_name", .fields = &fields, .addable = true };
    const values = [_]?[]const u8{ "1234567.25", ".first_choice_with_a_long_name", "true", ".{ .{ 1, 2, 3 }, .{ 4, 5, 6 }, .{ 7, 8, 9 } }", "null", "\"sounds/a_sound_with_a_long_long_name.ogg\"" };
    const shown = [_]?[]const u8{ null, null, null, null, "", "sounds/a_sound_with_a_long_long_name.ogg" };
    const details = Details{
        .entity = .init(3, 0),
        .name = "An entity with a name long enough to need the whole field and then some",
        .components = &.{.{ .index = 0, .info = info, .values = &values, .shown = &shown }},
        .addable = &.{.{ .index = 1, .label = "AnotherComponentWithALongName (some_plugin)" }},
    };
    for ([_]bool{ false, true }) |searching| for ([_]f32{ 220, 320, 600 }) |width| {
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = width, .h = 800 };
        context.newFrame(viewport);
        // Add component's search, open, and searching for one of the types.
        if (searching) inspector.search = .{ .edit = try SearchEdit.init("another") };
        _ = inspector.build(&context, details);
        _ = try context.render();
        try ui_checks.expectFits(context.last_root.?, context.font, viewport);
    };
}

test "the component search lists only the types that match, ignoring case" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var inspector = EntityInspector.init(std.testing.allocator);
    defer inspector.deinit();
    const details = Details{ .entity = .init(1, 0), .name = "", .components = &.{}, .addable = &.{
        .{ .index = 0, .label = "Orbit" },
        .{ .index = 1, .label = "Position" },
        .{ .index = 2, .label = "Body" },
    } };
    inspector.shown = details.entity;
    inspector.search = .{ .edit = try SearchEdit.init("OR"), .focused = true };
    context.newFrame(.{ .x = 0, .y = 0, .w = 300, .h = 400 });
    _ = inspector.build(&context, details);
    _ = try context.render();
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(std.testing.allocator);
    try collectMenuItems(context.last_root.?, &labels);
    try std.testing.expectEqual(@as(usize, 1), labels.items.len);
    try std.testing.expectEqualStrings("Orbit", labels.items[0]);
}

fn collectMenuItems(element: *const ui.Layout.Element, labels: *std.ArrayList([]const u8)) !void {
    if (element.paint_kind == .menu_item) try labels.append(std.testing.allocator, element.paint_kind.menu_item.label);
    for (element.children) |child| try collectMenuItems(child, labels);
}
