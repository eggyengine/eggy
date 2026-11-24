//! What is being dragged from one panel to another: an entity from the Hierarchy or a file from
//! Assets. The panel it starts in owns the drag; the editor hands this description to the panels
//! it can be dropped on, which say whether they take it.
const std = @import("std");
const eggy = @import("eggy");
const Reference = @import("assets/reference.zig").Reference;

pub const Dragged = union(enum) {
    entity: struct {
        entity: eggy.ecs.EntityId,
        /// Its name as shown ("Entity N" without one), for labels.
        name: []const u8,
        /// The short names of its components, to tell which reference fields take it.
        components: []const []const u8,
    },
    /// A project asset by its identity (a model file also stands for its geometry, and an
    /// expanded model's clips for themselves), with the name to show.
    asset: Reference,

    /// Whether a reference part `target` takes this: an entity reference an entity with the
    /// component it requires, an asset reference a file of its kind.
    /// Inspects borrowed drag metadata without changing it; no world/filesystem lookup occurs.
    ///
    /// ```zig
    /// const dragged = Dragged{ .asset = Reference.of(0x2a, .audio, "hum.ogg") };
    /// const accepts = dragged.fits(.{ .kind = .asset, .accepts = .audio });
    /// std.debug.assert(accepts);
    /// ```
    pub fn fits(self: Dragged, target: eggy.components.Part) bool {
        const requires = std.mem.span(target.requires);
        return switch (self) {
            .entity => |dragged| target.kind == .entity and (requires.len == 0 or for (dragged.components) |name| {
                if (std.mem.eql(u8, name, requires)) break true;
            } else false),
            .asset => |reference| target.kind == .asset and reference.fits(target.accepts),
        };
    }

    /// What a field set to this holds, as ZON, in `buffer`.
    /// Returns a slice borrowing caller storage, valid until that storage changes.
    /// An asset is its identity's key as a string; returns `NoSpaceLeft` if the buffer is too short.
    ///
    /// ```zig
    /// var buffer: [256]u8 = undefined;
    /// const text = try (Dragged{ .asset = Reference.of(0x2a, .audio, "hum.ogg") }).zon(&buffer);
    /// // Pass text to the editor's field setter before reusing buffer.
    /// std.debug.assert(text[0] == '"');
    /// ```
    pub fn zon(self: Dragged, buffer: []u8) ![]const u8 {
        return switch (self) {
            .entity => |dragged| std.fmt.bufPrint(buffer, ".{{ .id = {d}, .generation = {d} }}", .{ dragged.entity.id, dragged.entity.generation }),
            .asset => |reference| std.fmt.bufPrint(buffer, "\"{s}\"", .{reference.key()}),
        };
    }
};
