//! Which interactive element of a laid-out Weeoui tree is under a point, as Weeoui's `Context`
//! decides it: the highest overlay layer wins, then the smallest box.
const std = @import("std");
const L = @import("eggy").ui.Layout;

/// The id of the topmost interactive element (id not 0) under (x, y) in `root`, or 0.
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
        if (element.id != 0 and rect.contains(x, y) and (z > self.z or (z == self.z and rect.w * rect.h < self.area))) {
            self.* = .{ .id = element.id, .z = z, .area = rect.w * rect.h };
        }
        for (element.children) |child| self.visit(child, z, x, y);
    }
};
