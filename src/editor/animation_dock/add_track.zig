//! The Animation panel's Add track menu: pick something in the scene, then what of it to animate,
//! as a menu under its button. What already has a track shows but can't be picked again.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const Property = eggy.assets.clip.Property;

/// Something in the scene the clip can animate, and what of it.
pub const Target = struct {
    label: []const u8,
    /// What it is (`Camera`, `UI`), or "".
    kind: []const u8,
    offers: []const Offer,
};

pub const Offer = struct {
    property: Property,
    label: []const u8,
    /// The clip has a track for it already.
    on_timeline: bool,
};

pub const Picked = struct { target: usize, property: Property };

/// Ids the menu takes: its surface, a row per target, an entry per offer of the target shown.
const surface_id: u32 = 0x5a7e_0000;
const target_id_base: u32 = surface_id + 1;
const offer_id_base: u32 = surface_id + 0x1000;
const width: f32 = 200;

pub const AddTrack = struct {
    open: bool = false,
    /// The target whose offers show beside the list.
    showing: usize = 0,

    /// The button, and while open the menu under it: the targets, then what the one pointed at
    /// can animate. Returns what was picked. A press elsewhere or Escape closes it.
    pub fn build(self: *AddTrack, context: *ui.Context, targets: []const Target) ?Picked {
        const pressed = context.buttonVariant("Add track", if (self.open) .secondary else .default);
        const anchor = context.last_added orelse return null;
        if (pressed) {
            self.open = !self.open;
            return null;
        }
        if (!self.open or targets.len == 0) return null;
        if (context.escape) {
            context.escape = false;
            self.open = false;
            return null;
        }
        if (context.pressed_down) if (context.press) |press| {
            const inside = if (context.last_bounds.get(surface_id)) |bounds| bounds.rect.contains(press.at.x, press.at.y) else true;
            if (!inside) {
                self.open = false;
                return null;
            }
        };
        if (self.showing >= targets.len) self.showing = 0;

        const b = context.builder();
        const arena = b.allocator;
        // The targets: the one shown is lit; pointing at or pressing one shows its offers.
        var rows: std.ArrayList(*ui.Layout.Element) = .empty;
        for (targets, 0..) |target, index| {
            const id = target_id_base + @as(u32, @intCast(index));
            if (context.activated(id) or under(context, id)) self.showing = index;
            const label = if (target.kind.len > 0) std.fmt.allocPrint(arena, "{s}   {s}", .{ target.label, target.kind }) catch target.label else target.label;
            const row = b.node(id, .{ .height = 26, .width = width }, .{ .menu_item = .{ .label = label, .submenu = true, .hot = index == self.showing } }, &.{}) catch return null;
            row.cursor = .pointer;
            row.accessibility = .{ .role = .menu_item, .label = target.label, .expanded = index == self.showing };
            rows.append(arena, row) catch return null;
        }

        // What the shown target can animate; one already on the timeline is greyed out.
        var picked: ?Picked = null;
        const offers = targets[self.showing].offers;
        const items = arena.alloc(ui.widgets.MenuItem, offers.len) catch return null;
        var hot: u32 = 0;
        for (offers, items, 0..) |offer, *item, index| {
            const id = offer_id_base + @as(u32, @intCast(index));
            if (under(context, id)) hot = id;
            if (!offer.on_timeline and context.activated(id)) picked = .{ .target = self.showing, .property = offer.property };
            item.* = .{ .id = id, .label = offer.label, .disabled = offer.on_timeline };
        }
        const list = b.node(0, .{ .width = width, .gap = 2 }, .none, rows.items) catch return null;
        const menu = ui.widgets.menuItems(b, items, hot, 0) catch return null;
        menu.style.width = width;
        const surface = b.node(surface_id, .{ .direction = .row, .gap = 6, .padding = .{ .left = 6, .right = 6, .top = 6, .bottom = 6 }, .z_index = 120 }, .card, &.{ list, menu }) catch return null;
        surface.overlay = .{ .anchor = .{ .target = anchor, .side = .bottom } };
        surface.accessibility = .{ .role = .menu, .label = "Add track" };
        context.overlays.append(arena, surface) catch return null;
        if (picked != null) self.open = false;
        return picked;
    }
};

/// Whether the pointer is over widget `id` as it was last drawn.
fn under(context: *const ui.Context, id: u32) bool {
    const bounds = context.last_bounds.get(id) orelse return false;
    return bounds.rect.contains(context.pointer.x, context.pointer.y);
}
