//! What is being dragged from one panel to another: an entity from the Hierarchy or a file from
//! Assets. The panel it starts in owns the drag; the editor hands this description to the panels
//! it can be dropped on, which say whether they take it.
const std = @import("std");
const eggy = @import("eggy");

pub const Dragged = union(enum) {
    entity: struct {
        entity: eggy.ecs.EntityId,
        /// Its name as shown ("Entity N" without one), for labels.
        name: []const u8,
        /// The short names of its components, to tell which reference fields take it.
        components: []const []const u8,
    },
    /// A project file, relative to the project with `/` between parts.
    asset: []const u8,

    /// Whether a field of `field`'s kind takes this: an entity reference an entity with the
    /// component it requires, an asset reference a file of its kind.
    pub fn fits(self: Dragged, field: eggy.components.Field) bool {
        return switch (self) {
            .entity => |dragged| field.kind == .entity and (field.requires.len == 0 or for (dragged.components) |name| {
                if (std.mem.eql(u8, name, field.requires)) break true;
            } else false),
            .asset => |path| field.kind == .asset and field.accepts.takes(path),
        };
    }

    /// What a field set to this holds, as ZON, in `buffer`.
    pub fn zon(self: Dragged, buffer: []u8) ![]const u8 {
        return switch (self) {
            .entity => |dragged| std.fmt.bufPrint(buffer, ".{{ .id = {d}, .generation = {d} }}", .{ dragged.entity.id, dragged.entity.generation }),
            .asset => |path| std.fmt.bufPrint(buffer, "\"{f}\"", .{std.zig.fmtString(path)}),
        };
    }
};

test "an entity reference takes an entity with the component it requires" {
    const field = eggy.components.Field{ .name = "around", .kind = .entity, .editable = true, .requires = "Body" };
    const sun = Dragged{ .entity = .{ .entity = .init(1, 0), .name = "Sun", .components = &.{ "Name", "Body" } } };
    const rock = Dragged{ .entity = .{ .entity = .init(2, 0), .name = "Rock", .components = &.{"Name"} } };
    try std.testing.expect(sun.fits(field));
    try std.testing.expect(!rock.fits(field));
    try std.testing.expect(!(Dragged{ .asset = "sun.png" }).fits(field));

    const sound = eggy.components.Field{ .name = "hum", .kind = .asset, .editable = true, .accepts = .audio };
    try std.testing.expect((Dragged{ .asset = "sounds/hum.ogg" }).fits(sound));
    try std.testing.expect(!(Dragged{ .asset = "art/hum.png" }).fits(sound));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\"sounds/hum.ogg\"", try (Dragged{ .asset = "sounds/hum.ogg" }).zon(&buffer));
}
