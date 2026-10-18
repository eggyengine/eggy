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

    /// Whether a reference part `target` takes this: an entity reference an entity with the
    /// component it requires, an asset reference a file of its kind.
    /// Inspects borrowed drag metadata without changing it; no world/filesystem lookup occurs.
    ///
    /// ```zig
    /// const dragged = Dragged{ .asset = "sounds/hum.ogg" };
    /// const accepts = dragged.fits(.{ .kind = .asset, .accepts = .audio });
    /// std.debug.assert(accepts);
    /// ```
    pub fn fits(self: Dragged, target: eggy.components.Part) bool {
        const requires = std.mem.span(target.requires);
        return switch (self) {
            .entity => |dragged| target.kind == .entity and (requires.len == 0 or for (dragged.components) |name| {
                if (std.mem.eql(u8, name, requires)) break true;
            } else false),
            .asset => |path| target.kind == .asset and target.accepts.takes(path),
        };
    }

    /// What a field set to this holds, as ZON, in `buffer`.
    /// Returns a slice borrowing caller storage, valid until that storage changes.
    /// Escapes asset paths; returns `NoSpaceLeft` if the buffer is too short.
    ///
    /// ```zig
    /// var buffer: [256]u8 = undefined;
    /// const text = try (Dragged{ .asset = "sounds/hum.ogg" }).zon(&buffer);
    /// // Pass text to the editor's field setter before reusing buffer.
    /// std.debug.assert(text[0] == '"');
    /// ```
    pub fn zon(self: Dragged, buffer: []u8) ![]const u8 {
        return switch (self) {
            .entity => |dragged| std.fmt.bufPrint(buffer, ".{{ .id = {d}, .generation = {d} }}", .{ dragged.entity.id, dragged.entity.generation }),
            .asset => |path| std.fmt.bufPrint(buffer, "\"{f}\"", .{std.zig.fmtString(path)}),
        };
    }
};

test "an entity reference takes an entity with the component it requires" {
    const field = eggy.components.Part{ .kind = .entity, .requires = "Body" };
    const sun = Dragged{ .entity = .{ .entity = .init(1, 0), .name = "Sun", .components = &.{ "Name", "Body" } } };
    const rock = Dragged{ .entity = .{ .entity = .init(2, 0), .name = "Rock", .components = &.{"Name"} } };
    try std.testing.expect(sun.fits(field));
    try std.testing.expect(!rock.fits(field));
    try std.testing.expect(!(Dragged{ .asset = "sun.png" }).fits(field));

    const sound = eggy.components.Part{ .kind = .asset, .accepts = .audio };
    try std.testing.expect((Dragged{ .asset = "sounds/hum.ogg" }).fits(sound));
    try std.testing.expect(!(Dragged{ .asset = "art/hum.png" }).fits(sound));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\"sounds/hum.ogg\"", try (Dragged{ .asset = "sounds/hum.ogg" }).zon(&buffer));
}
