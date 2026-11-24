//! The graph editor's canvas: one layer's state machine drawn as nodes and arrows over a dotted
//! ground. Pressing a node or an arrow selects it, dragging a node moves it, dragging from the
//! port on a node's right edge to another node adds a transition, and dragging the ground (or
//! the wheel) pans. Entry points at the layer's first state; Any state's arrows leave any state.
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const format = eggy.assets.animation_graph;
const gizmo = @import("../scene_view/gizmo.zig");
const document_zig = @import("document.zig");
const Document = document_zig.Document;

const state_size = [2]f32{ 176, 56 };
const pill_size = [2]f32{ 104, 36 };
const port_radius: f32 = 6;
/// How near an arrow a press must be to pick it, in page units.
const arrow_reach: f32 = 6;
/// How far apart the two arrows between a pair of states run.
const pair_offset: f32 = 7;

/// A node of the canvas.
pub const Node = union(enum) {
    entry,
    any,
    state: usize,
};

const Drag = union(enum) {
    /// Moving a node: where the pointer was on it, as an offset from its position.
    node: struct { node: Node, grab: [2]f32, moved: bool = false },
    /// Drawing a transition from a node to the pointer.
    link: struct { from: Node, to: ui.Vec2 },
    pan: ui.Vec2,
};

/// What a pointer event did.
pub const Result = struct {
    used: bool = false,
    /// The document changed (a node moved, a transition was added).
    changed: bool = false,
};

pub const Canvas = struct {
    /// Where the graph's origin is in the canvas, in page units.
    pan: [2]f32 = .{ 280, 140 },
    /// Where the canvas was laid out last frame, in page units.
    area: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    drag: ?Drag = null,
    /// The node the pointer is over, lit.
    hovered: ?Node = null,

    /// Whether a drag holds edits that aren't finished.
    pub fn holding(self: *const Canvas) bool {
        return self.drag != null;
    }

    /// Where in the graph a new node goes: the middle of what the canvas shows.
    pub fn middle(self: *const Canvas) [2]f32 {
        return .{ @round(self.area.w / 2 - self.pan[0] - state_size[0] / 2), @round(self.area.h / 2 - self.pan[1] - state_size[1] / 2) };
    }

    /// Lay the canvas out `height` tall across the page and draw `document`'s shown layer.
    pub fn build(self: *Canvas, context: *ui.Context, document: *Document, height: f32) !void {
        const arena = context.builder().allocator;
        const scene = try arena.create(Scene);
        scene.* = try self.snapshot(arena, document, context.theme);
        const element = try context.builder().node(0, .{ .grow = 1, .height = height }, .{ .custom = .{ .context = scene, .draw = Scene.draw } }, &.{});
        element.accessibility = .{ .role = .image, .label = "Animation graph" };
        context.element(element);
    }

    /// A pointer event over the page, in its units. Returns what it did.
    pub fn pointer(self: *Canvas, document: *Document, event: ui.input.Event) Result {
        switch (event) {
            .pointer_down => |down| {
                const at = down.position;
                if (!self.area.contains(at.x, at.y)) return .{};
                if (down.button == .middle) {
                    self.drag = .{ .pan = at };
                    return .{ .used = true };
                }
                if (down.button != .left) return .{};
                if (self.portAt(document, at)) |node| {
                    self.drag = .{ .link = .{ .from = node, .to = at } };
                    return .{ .used = true };
                }
                if (self.nodeAt(document, at)) |node| {
                    select(document, node);
                    const position = nodePosition(document, node);
                    self.drag = .{ .node = .{ .node = node, .grab = .{ at.x - self.pan[0] - self.area.x - position[0], at.y - self.pan[1] - self.area.y - position[1] } } };
                    return .{ .used = true };
                }
                if (self.arrowAt(document, at)) |index| {
                    document.selection = .{ .transition = index };
                    return .{ .used = true };
                }
                document.selection = .layer;
                self.drag = .{ .pan = at };
                return .{ .used = true };
            },
            .pointer_move => |at| {
                self.hovered = if (self.area.contains(at.x, at.y)) self.nodeAt(document, at) else null;
                const drag = if (self.drag) |*held| held else return .{};
                switch (drag.*) {
                    .pan => |*last| {
                        self.pan[0] += at.x - last.x;
                        self.pan[1] += at.y - last.y;
                        last.* = at;
                    },
                    .link => |*link| link.to = at,
                    .node => |*moving| {
                        const placed = [2]f32{ @round(at.x - self.pan[0] - self.area.x - moving.grab[0]), @round(at.y - self.pan[1] - self.area.y - moving.grab[1]) };
                        if (!std.meta.eql(placed, nodePosition(document, moving.node))) {
                            setNodePosition(document, moving.node, placed);
                            moving.moved = true;
                            return .{ .used = true, .changed = true };
                        }
                    },
                }
                return .{ .used = true };
            },
            .pointer_up => |up| {
                const drag = self.drag orelse return .{};
                self.drag = null;
                switch (drag) {
                    .link => |link| {
                        const target = self.nodeAt(document, up.position) orelse return .{ .used = true };
                        const to = switch (target) {
                            .state => |index| index,
                            .entry, .any => return .{ .used = true },
                        };
                        const from: ?usize = switch (link.from) {
                            .state => |index| index,
                            .any => null,
                            .entry => {
                                // From Entry: the target becomes where the layer starts.
                                document.shown().entry = document.states()[to].name;
                                return .{ .used = true, .changed = true };
                            },
                        };
                        document.addTransition(from, to) catch return .{ .used = true };
                        return .{ .used = true, .changed = true };
                    },
                    .node => |moving| return .{ .used = true, .changed = moving.moved },
                    .pan => return .{ .used = true },
                }
            },
            .wheel => |wheel| {
                if (!self.area.contains(wheel.position.x, wheel.position.y)) return .{};
                self.pan[0] += wheel.delta.x * 40;
                self.pan[1] += wheel.delta.y * 40;
                return .{ .used = true };
            },
            else => return .{},
        }
    }

    /// The node under `at`, topmost first.
    fn nodeAt(self: *const Canvas, document: *Document, at: ui.Vec2) ?Node {
        var index = document.shown().states.len;
        while (index > 0) {
            index -= 1;
            if (self.rectOf(document, .{ .state = index }).contains(at.x, at.y)) return .{ .state = index };
        }
        for ([_]Node{ .entry, .any }) |node| if (self.rectOf(document, node).contains(at.x, at.y)) return node;
        return null;
    }

    /// The node whose port (the dot on its right edge) is under `at`.
    fn portAt(self: *const Canvas, document: *Document, at: ui.Vec2) ?Node {
        for (0..document.shown().states.len) |index| if (near(portOf(self.rectOf(document, .{ .state = index })), at, port_radius + 3)) return .{ .state = index };
        for ([_]Node{ .entry, .any }) |node| if (near(portOf(self.rectOf(document, node)), at, port_radius + 3)) return node;
        return null;
    }

    /// The transition whose arrow passes within reach of `at`.
    fn arrowAt(self: *const Canvas, document: *Document, at: ui.Vec2) ?usize {
        for (document.shown().transitions, 0..) |transition, index| {
            const ends = self.arrowEnds(document, transition) orelse continue;
            if (distanceToSegment(at, ends[0], ends[1]) <= arrow_reach) return index;
        }
        return null;
    }

    /// Where `node` is drawn, in page units.
    fn rectOf(self: *const Canvas, document: *Document, node: Node) ui.Rect {
        const position = nodePosition(document, node);
        const size = if (node == .state) state_size else pill_size;
        return .{ .x = self.area.x + self.pan[0] + position[0], .y = self.area.y + self.pan[1] + position[1], .w = size[0], .h = size[1] };
    }

    /// Where `transition`'s arrow runs: between its nodes' edges, beside the arrow back when
    /// there is one.
    fn arrowEnds(self: *const Canvas, document: *Document, transition: format.Transition) ?[2]ui.Vec2 {
        const layer = document.shown();
        const to = layer.stateIndex(transition.to) orelse return null;
        const from: Node = if (transition.from.len == 0) .any else .{ .state = layer.stateIndex(transition.from) orelse return null };
        const back = for (layer.transitions) |other| {
            if (std.mem.eql(u8, other.from, transition.to) and std.mem.eql(u8, other.to, transition.from)) break true;
        } else false;
        return self.between(self.rectOf(document, from), self.rectOf(document, .{ .state = to }), if (back) pair_offset else 0);
    }

    fn between(_: *const Canvas, from: ui.Rect, to: ui.Rect, offset: f32) [2]ui.Vec2 {
        var a = centre(from);
        var b = centre(to);
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const length = @max(0.001, @sqrt(dx * dx + dy * dy));
        // Shift the pair apart, each to its own right, so there and back read apart.
        const nx = -dy / length * offset;
        const ny = dx / length * offset;
        a = .{ .x = a.x + nx, .y = a.y + ny };
        b = .{ .x = b.x + nx, .y = b.y + ny };
        return .{ edgePoint(from, a, b), edgePoint(to, b, a) };
    }

    /// What the draw call needs, copied for the frame.
    fn snapshot(self: *const Canvas, arena: std.mem.Allocator, document: *Document, theme: ui.Theme) !Scene {
        const layer = document.shown();
        var nodes: std.ArrayList(Scene.Box) = .empty;
        var arrows: std.ArrayList(Scene.Arrow) = .empty;
        const selection = document.selection;

        // Arrows first, under the nodes.
        for (layer.transitions, 0..) |transition, index| {
            const ends = self.arrowEnds(document, transition) orelse continue;
            const picked = selection == .transition and selection.transition == index;
            try arrows.append(arena, .{ .from = ends[0], .to = ends[1], .color = if (picked) theme.primary else theme.muted_foreground, .width = if (picked) 2.5 else 1.5 });
        }
        if (layer.entryIndex()) |entry| {
            const ends = self.between(self.rectOf(document, .entry), self.rectOf(document, .{ .state = entry }), 0);
            try arrows.append(arena, .{ .from = ends[0], .to = ends[1], .color = theme.muted_foreground, .width = 1.5 });
        }
        if (self.drag) |drag| if (drag == .link) {
            const from = portOf(self.rectOf(document, drag.link.from));
            try arrows.append(arena, .{ .from = from, .to = drag.link.to, .color = theme.primary, .width = 2 });
        };

        for ([_]Node{ .entry, .any }) |node| try nodes.append(arena, .{
            .rect = self.rectOf(document, node),
            .title = if (node == .entry) "Entry" else "Any state",
            .pill = true,
            .lit = std.meta.eql(self.hovered, @as(?Node, node)),
        });
        for (layer.states, 0..) |state, index| try nodes.append(arena, .{
            .rect = self.rectOf(document, .{ .state = index }),
            .title = state.name,
            .detail = try detailOf(arena, state.motion),
            .picked = selection == .state and selection.state == index,
            .lit = std.meta.eql(self.hovered, @as(?Node, .{ .state = index })),
        });
        return .{ .area = self.area, .pan = self.pan, .boxes = nodes.items, .arrows = arrows.items, .area_out = @constCast(&self.area) };
    }
};

/// One frame's drawing of the canvas.
const Scene = struct {
    area: ui.Rect,
    pan: [2]f32,
    boxes: []const Box,
    arrows: []const Arrow,
    /// Where the canvas's area is kept for the next frame's pointer events.
    area_out: *ui.Rect,

    const Box = struct {
        rect: ui.Rect,
        title: []const u8,
        detail: []const u8 = "",
        pill: bool = false,
        picked: bool = false,
        lit: bool = false,
    };
    const Arrow = struct { from: ui.Vec2, to: ui.Vec2, color: ui.Color, width: f32 };

    fn draw(context: *const anyopaque, c: *ui.Canvas, r: ui.Rect) anyerror!void {
        const self: *const Scene = @ptrCast(@alignCast(context));
        self.area_out.* = r;
        const t = c.theme;
        const clip = c.clip;
        c.clip = r;
        defer c.clip = clip;
        try c.rect(r, t.background);

        // Dots every 24 units, moving with the graph.
        const step: f32 = 24;
        var y = r.y + @mod(self.pan[1], step);
        while (y < r.y + r.h) : (y += step) {
            var x = r.x + @mod(self.pan[0], step);
            while (x < r.x + r.w) : (x += step) try c.rectAlpha(.{ .x = x, .y = y, .w = 1.5, .h = 1.5 }, t.border, 1);
        }

        for (self.arrows) |arrow| try drawArrow(c, arrow.from, arrow.to, arrow.width, arrow.color);
        for (self.boxes) |box| {
            const radius: f32 = if (box.pill) box.rect.h / 2 else 10;
            try c.roundRect(box.rect, if (box.pill) t.muted else t.card, radius);
            const edge = if (box.picked) t.primary else if (box.lit) t.ring else t.input;
            try c.roundRectStroke(box.rect, edge, radius, if (box.picked) 2 else 1);
            if (box.pill) {
                try c.textIn(box.rect, box.title, t.text_size, t.muted_foreground, .center);
            } else {
                const inner = ui.Rect{ .x = box.rect.x + 14, .y = box.rect.y + 8, .w = box.rect.w - 28, .h = 20 };
                try c.textIn(inner, box.title, t.text_size, t.foreground, .start);
                try c.textIn(.{ .x = inner.x, .y = inner.y + 20, .w = inner.w, .h = 18 }, box.detail, 12, t.muted_foreground, .start);
            }
            if (box.lit or box.picked) {
                const port = portOf(box.rect);
                try c.roundRect(.{ .x = port.x - port_radius, .y = port.y - port_radius, .w = port_radius * 2, .h = port_radius * 2 }, t.primary, port_radius);
            }
        }
    }
};

/// What a state plays, in a few words.
fn detailOf(arena: std.mem.Allocator, motion: format.Motion) ![]const u8 {
    return switch (motion) {
        .clip => |clip| if (clip.clip.len == 0) "no clip" else if (clip.repeat == .once) "clip, once" else "clip",
        .blend_1d => |blend| try std.fmt.allocPrint(arena, "blend by {s}", .{if (blend.parameter.len == 0) "nothing" else blend.parameter}),
        .blend_2d => |blend| try std.fmt.allocPrint(arena, "blend by {s} and {s}", .{ if (blend.parameters[0].len == 0) "nothing" else blend.parameters[0], if (blend.parameters[1].len == 0) "nothing" else blend.parameters[1] }),
    };
}

fn select(document: *Document, node: Node) void {
    document.selection = switch (node) {
        .state => |index| .{ .state = index },
        .entry, .any => .layer,
    };
}

fn nodePosition(document: *Document, node: Node) [2]f32 {
    const layer = document.shown();
    return switch (node) {
        .entry => layer.entry_position,
        .any => layer.any_position,
        .state => |index| layer.states[index].position,
    };
}

fn setNodePosition(document: *Document, node: Node, position: [2]f32) void {
    switch (node) {
        .entry => document.shown().entry_position = position,
        .any => document.shown().any_position = position,
        .state => |index| document.states()[index].position = position,
    }
}

fn centre(r: ui.Rect) ui.Vec2 {
    return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
}

fn portOf(r: ui.Rect) ui.Vec2 {
    return .{ .x = r.x + r.w, .y = r.y + r.h / 2 };
}

fn near(a: ui.Vec2, b: ui.Vec2, reach: f32) bool {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return dx * dx + dy * dy <= reach * reach;
}

/// Where the line from `inside` towards `toward` leaves `r`.
fn edgePoint(r: ui.Rect, inside: ui.Vec2, toward: ui.Vec2) ui.Vec2 {
    const dx = toward.x - inside.x;
    const dy = toward.y - inside.y;
    var t: f32 = 1;
    if (dx > 0) t = @min(t, (r.x + r.w - inside.x) / dx);
    if (dx < 0) t = @min(t, (r.x - inside.x) / dx);
    if (dy > 0) t = @min(t, (r.y + r.h - inside.y) / dy);
    if (dy < 0) t = @min(t, (r.y - inside.y) / dy);
    t = std.math.clamp(t, 0, 1);
    return .{ .x = inside.x + dx * t, .y = inside.y + dy * t };
}

fn distanceToSegment(p: ui.Vec2, a: ui.Vec2, b: ui.Vec2) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length_squared = dx * dx + dy * dy;
    const t = if (length_squared > 0) std.math.clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / length_squared, 0, 1) else 0;
    const x = a.x + dx * t - p.x;
    const y = a.y + dy * t - p.y;
    return @sqrt(x * x + y * y);
}

/// A line from `from` to `to` with a filled head at `to`.
fn drawArrow(c: *ui.Canvas, from: ui.Vec2, to: ui.Vec2, width: f32, color: ui.Color) !void {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const length = @sqrt(dx * dx + dy * dy);
    if (length < 1) return;
    const ux = dx / length;
    const uy = dy / length;
    const head: f32 = 9;
    const base = ui.Vec2{ .x = to.x - ux * head, .y = to.y - uy * head };
    const rgba = [4]f32{ color[0], color[1], color[2], 1 };
    try gizmo.line(c, from, base, width, rgba);
    const side = [2]f32{ -uy * head * 0.55, ux * head * 0.55 };
    try c.triangle(.{ .{ to.x, to.y }, .{ base.x + side[0], base.y + side[1] }, .{ base.x - side[0], base.y - side[1] } }, .{ rgba, rgba, rgba });
}
