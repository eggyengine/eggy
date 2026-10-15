//! Entities in the editor: the Hierarchy panel's tree of the world's entities, and the
//! Inspector's view of the one selected there.
pub const hierarchy = @import("hierarchy.zig");
pub const EntityInspector = @import("inspector.zig").EntityInspector;

test {
    _ = @import("hierarchy.zig");
    _ = @import("inspector.zig");
}
