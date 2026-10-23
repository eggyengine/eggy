//! The Inspector's view of the entity selected in the Hierarchy: its name, then a card per
//! component, each field with the controls its type calls for (`field_editor.zig`). A card's
//! header folds it away; Remove takes the component off; Add component opens a search over the
//! types it doesn't have. Values are read from the world every frame, so fields a system changes change
//! here too, except one being typed into.
//!
//! A reference (`eggy.EntityRef`, `eggy.AssetRef`) is a slot: drag an entity from the
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
const ProjectAssets = @import("../assets/project_assets.zig").ProjectAssets;
const field_editor = @import("field_editor.zig");
const component_icons = @import("component_icons.zig");
const restyle = page_style.restyle;
const displayName = field_editor.displayName;

/// What the Inspector shows: the entity, its name, and its components with their values.
pub const Details = struct {
    entity: ecs.EntityId,
    name: []const u8,
    components: []const Component,
    /// The component types it doesn't have and can be given, as `(index, label)`.
    addable: []const Addable,
    /// What is being dragged from another panel, if anything: the slots that take it light up.
    dragging: ?Dragged = null,
    /// Names the assets nested reference fields hold, by their identities.
    assets: ?*ProjectAssets = null,

    pub const Component = struct {
        /// Its index among the game's component types.
        index: usize,
        info: components.Info,
        /// Each field's value as ZON; null where it can't be read.
        values: []const ?[]const u8,
        /// Each reference field's value as people read it (an entity's name, a file's); null for
        /// other fields, and empty when unset.
        shown: []const ?[]const u8 = &.{},
        /// Whether its plugin is turned off: its values show, but can't be changed.
        disabled: bool = false,
        /// The components it depends on, and those of the entity's that depend on it (which keep
        /// it from being removed), by name, joined with commas; empty for none.
        needs: []const u8 = "",
        needed_by: []const u8 = "",
    };
    pub const Addable = struct {
        index: usize,
        label: []const u8,
        /// The component's icon (`eggy.components.Info.icon`), drawn before its label.
        icon: []const u8 = eggy.components.default_icon,
    };
};

pub const Action = union(enum) {
    rename: []const u8,
    set_field: struct { component: usize, field: usize, text: []const u8 },
    add_component: usize,
    remove_component: usize,
};

const SearchEdit = ui.TextEdit(64);
/// The most component types the search lists at once.
const max_listed = 12;
/// The listed types' element ids: `pick_id_base` plus their place in the list.
const pick_id_base: u32 = 0x6D00_0000;
const NameEdit = ui.TextEdit(eggy.Name.max_len);
/// The share of the Inspector's width a field's controls take, beside its name, and how narrow
/// and wide they get.
const control_share: f32 = 0.6;
const min_control_width: f32 = 80;
const max_control_width: f32 = 360;

pub const EntityInspector = struct {
    gpa: std.mem.Allocator,
    name: NameEdit = NameEdit.init("") catch unreachable,
    /// The fields' controls, and what is being typed into or dragged there.
    values: field_editor.FieldEditor,
    /// The text box typed into last frame (`name_key` for the name), which keeps its text
    /// rather than the world's.
    focused: ?u32 = null,
    /// Components folded away, by index.
    folded: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// The entity the state above is for.
    shown: ?ecs.EntityId = null,
    /// Add component's search while it is open, and whether it has had the keyboard yet.
    search: ?struct { edit: SearchEdit, focused: bool = false } = null,

    const name_key = std.math.maxInt(u32);
    const search_key = std.math.maxInt(u32) - 1;

    /// Create editor inspector state; future fold/field allocations use `gpa`.
    /// Pair with `deinit`; no entity or game metadata is retained yet.
    ///
    /// ```zig
    /// var inspector = EntityInspector.init(gpa); // Existing allocator.
    /// defer inspector.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator) EntityInspector {
        return .{ .gpa = gpa, .values = .init(gpa) };
    }

    /// Release editor field/fold storage once; no later builds or drop queries are valid.
    ///
    /// ```zig
    /// var inspector = EntityInspector.init(gpa); // Existing allocator.
    /// defer inspector.deinit();
    /// ```
    pub fn deinit(self: *EntityInspector) void {
        self.values.deinit();
        self.folded.deinit(self.gpa);
    }

    /// The reference under `at` in last frame's layout, if any: what a drop there must fit.
    /// Editor-only: query before the next build clears slots; `at` is in UI coordinates.
    /// Returned Part metadata can borrow the loaded game's library and must not outlive it.
    ///
    /// ```zig
    /// const target = inspector.targetAt(context, at); // Last-layout context and UI position.
    /// ```
    pub fn targetAt(self: *const EntityInspector, context: *const ui.Context, at: ui.Vec2) ?components.Part {
        const slot = self.values.slotAt(context, at) orelse return null;
        return slot.target;
    }

    /// `dragged` let go at `at`: set the reference there, if it takes it.
    /// Editor-only: only proposes an action; it does not write the world. Query against last
    /// layout before rebuilding; returned ZON lives in `arena`. Null means no compatible slot
    /// or serialization/allocation failure.
    ///
    /// ```zig
    /// // Given inspector, last-layout context, UI position, Dragged and arena allocator:
    /// const action = inspector.dropAt(context, at, dragged, arena);
    /// ```
    pub fn dropAt(self: *const EntityInspector, context: *const ui.Context, at: ui.Vec2, dragged: Dragged, arena: std.mem.Allocator) ?Action {
        const slot = self.values.slotAt(context, at) orelse return null;
        if (!dragged.fits(slot.target)) return null;
        const text = slot.text(arena, dragged) catch return null;
        return .{ .set_field = .{ .component = slot.component, .field = slot.field, .text = text } };
    }

    /// Whether a number is being dragged or a colour picked: the changes become one undo step
    /// once that ends.
    /// Editor-only: use the value to coalesce undo snapshots, not to apply field changes.
    ///
    /// ```zig
    /// const coalesce_edits = inspector.scrubbing(); // Existing EntityInspector.
    /// ```
    pub fn scrubbing(self: *const EntityInspector) bool {
        return self.values.scrubbing();
    }

    /// Draw `details` into `context`. Returns what the user did this frame, if anything.
    /// Editor-only: details must describe one entity with aligned field/value arrays and
    /// live game metadata. Resets selection-specific state when the entity changes; returned
    /// action text lives in the UI frame arena. The host applies actions; UI failures are
    /// handled as incomplete UI/no action rather than errors.
    ///
    /// ```zig
    /// // Given inspector, building context and Details collected through the game ABI:
    /// const action = inspector.build(context, details);
    /// ```
    pub fn build(self: *EntityInspector, context: *ui.Context, details: Details) ?Action {
        const arena = context.builder().allocator;
        if (self.shown == null or !self.shown.?.eql(details.entity)) {
            self.values.reset();
            self.folded.clearRetainingCapacity();
            self.focused = null;
            self.search = null;
            self.shown = details.entity;
        }
        var action: ?Action = null;
        var focused: ?u32 = null;
        self.values.newFrame();

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
        const field_control = std.math.clamp(width * control_share, min_control_width, max_control_width);
        for (details.components) |component| if (self.componentCard(context, component, field_control, details.dragging, details.assets)) |card_action| {
            action = card_action;
        };
        self.focused = focused;
        return action;
    }

    /// A card for one component: a header (fold, name, owner, Remove), then its fields.
    fn componentCard(self: *EntityInspector, context: *ui.Context, component: Details.Component, field_control: f32, dragging: ?Dragged, assets: ?*ProjectAssets) ?Action {
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
            b.node(0, .{ .width = 18, .height = 18 }, component_icons.paint(arena, component.info) catch .none, &.{}) catch return null,
            b.node(0, .{ .grow = 1, .gap = 1 }, .none, &.{
                b.node(0, .{}, .{ .text = .{ .value = component.info.name, .size = 14, .wrap = true } }, &.{}) catch return null,
                b.node(0, .{}, .{ .text = .{ .value = std.fmt.allocPrint(arena, "{s}from {s}{s}{s}{s}{s}", .{ if (component.disabled) "Disabled: its plugin is off · " else "", component.info.owner, if (component.needs.len > 0) " · needs " else "", component.needs, if (component.needed_by.len > 0) " · needed by " else "", component.needed_by }) catch "", .size = 11, .tone = .muted, .wrap = true } }, &.{}) catch return null,
            }) catch return null,
        }) catch return null;
        header.cursor = .pointer;
        header.accessibility = .{ .role = .button, .label = component.info.name, .expanded = !folded };
        context.element(header);
        // Removable unless another of its components depends on it (the line under its name says which).
        if (component.needed_by.len == 0) if (context.buttonVariant(std.fmt.allocPrint(arena, "Remove##remove {d}", .{component.index}) catch return null, .ghost)) {
            action = .{ .remove_component = component.index };
        };
        context.end();
        restyle(context, .{ .direction = .row, .gap = 8, .align_items = .center });

        if (!folded) for (component.info.fields, component.values, 0..) |field, value, index| {
            const shown = if (index < component.shown.len) component.shown[index] else null;
            if (component.disabled or !field.editable or field.parts.len == 0 or value == null) {
                readOnlyRow(context, field, shown orelse value orelse "", field_control);
            } else if (self.values.fieldRows(context, .{
                .component = component.index,
                .field = index,
                .label = displayName(arena, field.name),
                .parts = field.parts,
                .text = value.?,
                .shown = shown,
                .control_width = field_control,
                .dragging = dragging,
                .assets = assets,
            })) |text| action = .{ .set_field = .{ .component = component.index, .field = index, .text = text } };
        };

        context.end();
        restyle(context, .{ .gap = 8, .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 } });
        return action;
    }

    /// A field of a disabled component: its name, and its value as text, not to be changed.
    fn readOnlyRow(context: *ui.Context, field: components.Field, value: []const u8, field_control: f32) void {
        const arena = context.builder().allocator;
        context.begin(.row);
        context.text(displayName(arena, field.name));
        page_style.smallText(context, 13);
        restyle(context, .{ .grow = 1 });
        context.begin(.column);
        context.muted(if (value.len > 0) value else "None");
        page_style.noteText(context);
        if (context.last_added) |text| text.paint_kind.text.wrap = true;
        context.end();
        restyle(context, .{ .width = field_control, .align_items = .end });
        context.end();
        restyle(context, .{ .direction = .row, .gap = 10, .align_items = .center });
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
            if (query.len > 0 and std.ascii.findIgnoreCase(choice.label, query) == null) continue;
            if (listed == max_listed) break;
            const id = pick_id_base + @as(u32, @intCast(listed));
            if (context.activated(id) or (enter and listed == 0)) picked = choice.index;
            // The icon, then the name, fitted to the room the icon leaves.
            const label = page_style.fitText(arena, context.font, choice.label, 13, width - 64);
            const iconed = std.fmt.allocPrint(arena, "{s}  {s}", .{ choice.icon, label }) catch return null;
            const row = b.node(id, .{ .height = 24 }, .{ .menu_item = .{ .label = iconed } }, &.{}) catch return null;
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

const ui_checks = @import("../ui_checks.zig");

/// A component with a field of every kind, and long names, for the layout tests.
const Everything = struct {
    a_field_with_a_very_long_name_that_wraps: f32 = 1234567.25,
    mode: enum { first_choice_with_a_long_name, second } = .first_choice_with_a_long_name,
    enabled: bool = true,
    count: u8 = 3,
    points: []const u8 = "not editable",
    position: [3]f32 = .{ 1, 2, 3 },
    tint_color: [4]f32 = .{ 1, 0.5, 0.25, 1 },
    turn: eggy.math.Quat = .identity(),
    shape: eggy.mesh.Source = .{ .model = .init("models/a_model_with_a_long_long_name.glb") },
    nested: struct { speed: f32 = 1, offset: eggy.math.Vec2 = .{ .x = 0, .y = 0 } } = .{},
    maybe: ?f32 = 2,
    orbits_around: eggy.EntityRef(SomeComponentWithALongName) = .{},
    sound: eggy.AssetRef(.audio) = .init("sounds/a_sound_with_a_long_long_name.ogg"),

    const SomeComponentWithALongName = struct {};
};

/// `Everything` as the Inspector gets it: its description, and its fields' values as ZON.
fn everythingDetails(arena: std.mem.Allocator, world: *ecs.World) !Details {
    const Registry = components.Registry(&.{Everything}, &.{"a_plugin_with_a_long_name"});
    const entity = try world.spawn(.{Everything{}});
    var info = Registry.infos[0];
    info.name = "AComponentWithAnUnreasonablyLongTypeName";
    const values = try arena.alloc(?[]const u8, info.fields.len);
    const shown = try arena.alloc(?[]const u8, info.fields.len);
    for (values, shown, info.fields, 0..) |*value, *note, field, index| {
        var text: std.Io.Writer.Allocating = .init(arena);
        try Registry.writeField(world, entity, 0, index, &text.writer);
        value.* = text.written();
        note.* = switch (field.kind) {
            .entity => "",
            .asset => "sounds/a_sound_with_a_long_long_name.ogg",
            else => null,
        };
    }
    return .{
        .entity = entity,
        .name = "An entity with a name long enough to need the whole field and then some",
        .components = try arena.dupe(Details.Component, &.{.{ .index = 0, .info = info, .values = values, .shown = shown }}),
        .addable = &.{.{ .index = 1, .label = "AnotherComponentWithALongName (some_plugin)" }},
    };
}

test "a component with every kind of field, and long names, fits a narrow Inspector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var inspector = EntityInspector.init(std.testing.allocator);
    defer inspector.deinit();
    const details = try everythingDetails(arena.allocator(), &world);
    for ([_]bool{ false, true }) |searching| for ([_]f32{ 220, 320, 600 }) |width| {
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = width, .h = 1600 };
        context.newFrame(viewport);
        // Add component's search, open, and searching for one of the types.
        if (searching) inspector.search = .{ .edit = try SearchEdit.init("another") };
        _ = inspector.build(&context, details);
        _ = try context.render();
        try ui_checks.expectFits(context.last_root.?, context.font, viewport);
    };
}

test "dragging a number sideways changes it, and a click types into it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    var inspector = EntityInspector.init(std.testing.allocator);
    defer inspector.deinit();
    const details = try everythingDetails(arena.allocator(), &world);
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 400, .h = 1600 };
    context.newFrame(viewport);
    _ = inspector.build(&context, details);
    _ = try context.render();

    // The first number box: the long-named float's.
    const box = findSlider(context.last_root.?).?;
    const at = ui.Vec2{ .x = box.bounds.x + box.bounds.w / 2, .y = box.bounds.y + box.bounds.h / 2 };
    context.handle(.{ .pointer_move = at });
    context.handle(.{ .pointer_down = .{ .position = at, .button = .left, .clicks = 1 } });
    context.newFrame(viewport);
    try std.testing.expect(inspector.build(&context, details) == null);
    _ = try context.render();
    try std.testing.expect(inspector.scrubbing());
    context.handle(.{ .pointer_move = .{ .x = at.x + 10, .y = at.y } });
    context.newFrame(viewport);
    const action = inspector.build(&context, details).?;
    _ = try context.render();
    const dragged_to = try std.fmt.parseFloat(f64, action.set_field.text);
    try std.testing.expect(dragged_to > 1234567.25);

    // Let go without moving: the box becomes a text field.
    context.handle(.{ .pointer_up = .{ .position = .{ .x = at.x + 10, .y = at.y }, .button = .left } });
    context.newFrame(viewport);
    _ = inspector.build(&context, details);
    _ = try context.render();
    try std.testing.expect(!inspector.scrubbing());
    try std.testing.expect(inspector.values.typing == null);
    context.handle(.{ .pointer_down = .{ .position = at, .button = .left, .clicks = 1 } });
    context.newFrame(viewport);
    _ = inspector.build(&context, details);
    _ = try context.render();
    context.handle(.{ .pointer_up = .{ .position = at, .button = .left } });
    context.newFrame(viewport);
    _ = inspector.build(&context, details);
    _ = try context.render();
    try std.testing.expect(inspector.values.typing != null);
    try std.testing.expect(context.wants_text);
}

fn findSlider(element: *ui.Layout.Element) ?*ui.Layout.Element {
    if (element.accessibility.role == .slider) return element;
    for (element.children) |child| if (findSlider(child)) |found| return found;
    return null;
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
    // One row, the component's icon (the default here) before its name.
    try std.testing.expectEqual(@as(usize, 1), labels.items.len);
    try std.testing.expectEqualStrings(eggy.components.default_icon ++ "  Orbit", labels.items[0]);
}

fn collectMenuItems(element: *const ui.Layout.Element, labels: *std.ArrayList([]const u8)) !void {
    if (element.paint_kind == .menu_item) try labels.append(std.testing.allocator, element.paint_kind.menu_item.label);
    for (element.children) |child| try collectMenuItems(child, labels);
}
