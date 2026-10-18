//! Which interactive element of a laid-out Weeoui tree is under a point, as Weeoui's `Context`
//! decides it: the highest overlay layer wins, then the smallest box.
const std = @import("std");
const L = @import("weeoui").Layout;

/// The id of the topmost interactive element (id not 0) under (x, y) in `root`, or 0.
/// Host UI helper: use laid-out bounds/clip rectangles and coordinates in that same logical
/// UI space. Higher overlay layers win, then smaller areas, then the later visited child.
/// Borrows the tree without changing it.
///
/// ```zig
/// const hovered_id = controlAt(layout_root, pointer_x, pointer_y);
/// ```
pub fn controlAt(root: *const L.Element, x: f32, y: f32) u32 {
    var best = Hit{};
    best.visit(root, 0, x, y);
    return best.id;
}

const Hit = struct {
    id: u32 = 0,
    z: i16 = std.math.minInt(i16),
    area: f32 = std.math.inf(f32),

    fn visit(self: *Hit, element: *const L.Element, layer: i16, x: f32, y: f32) void {
        const z = if (element.overlay != null) element.style.z_index else layer;
        const rect = element.bounds.intersection(element.clip);
        // The topmost layer, then the smallest; on a tie, the inner one (visited later).
        if (element.id != 0 and rect.contains(x, y) and (z > self.z or (z == self.z and rect.w * rect.h <= self.area))) {
            self.* = .{ .id = element.id, .z = z, .area = rect.w * rect.h };
        }
        for (element.children) |child| self.visit(child, z, x, y);
    }
};
