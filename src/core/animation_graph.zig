//! `AnimationGraph`: a component that runs a `.graph.zon` (`eggy.assets.animation_graph`) on an
//! entity's `Animator`. Each frame `step` checks every layer's transitions against the entity's
//! parameters, moves to the first whose conditions hold, and drives the `Animator`'s weighted
//! states (`animation_states.zig`) from what the layer's state plays: one clip, or clips blended
//! by parameters along an axis or across a plane. The game sets parameters through
//! `app.animation()` (`setParameter`, `trigger`), by name.
const std = @import("std");
const ecs = @import("clutch");
const assets = @import("eggy_assets");
const format = assets.animation_graph;
const AssetRef = @import("refs.zig").AssetRef;
const Name = @import("name.zig").Name;
const animation = @import("animation.zig");
const states = animation.states;
const Animator = animation.Animator;
const ClipCache = @import("clip_cache.zig").ClipCache;
const AssetCache = @import("asset_cache.zig").AssetCache;

pub const max_parameters = format.max_parameters;
pub const max_layers = format.max_layers;

fn parseGraph(gpa: std.mem.Allocator, source: [:0]const u8) anyerror!format.Parsed {
    return format.parse(gpa, source);
}

fn freeGraph(_: std.mem.Allocator, parsed: format.Parsed) void {
    parsed.deinit();
}

/// Graphs by asset key, read on first use; set its `resources`.
pub const GraphCache = AssetCache(.animation_graph, format.Parsed, parseGraph, freeGraph);

/// A parameter's value on one entity: a float as it is, a bool or a pending trigger as 1.
pub const Parameter = struct {
    name: Name = .{},
    value: f32 = 0,
};

/// Where one layer of the graph is.
pub const LayerState = struct {
    pub const none = std.math.maxInt(u8);
    /// The state it is in, by its index in the layer; `none` before it starts.
    state: u8 = none,
    /// How long it has been in that state, in seconds.
    time_s: f32 = 0,
    /// How long the state took to fade in; its blend weights ease at the same pace.
    blend_s: f32 = 0,
};

pub const AnimationGraph = struct {
    /// Marks it in the editor (nf-md-sitemap).
    pub const icon = "\u{f018d}";
    pub const category = "Animation";
    pub const dependencies = .{Animator};

    graph: AssetRef(.animation_graph) = .{},
    /// What the game set, by name; a graph's parameters the game hasn't set start at their
    /// defaults.
    parameters: [max_parameters]Parameter = @splat(.{}),
    layers: [max_layers]LayerState = @splat(.{}),

    /// The value of the parameter `name`, if the game or the graph gave it one.
    pub fn parameter(self: *const AnimationGraph, name: []const u8) ?f32 {
        const slot = self.find(name) orelse return null;
        return slot.value;
    }

    /// Set the parameter `name`, taking a free slot for a new one.
    pub fn set(self: *AnimationGraph, name: []const u8, value: f32) Error!void {
        if (name.len == 0 or name.len > Name.max_len) return error.InvalidParameter;
        if (!std.math.isFinite(value)) return error.InvalidParameter;
        const slot = self.findMut(name) orelse for (&self.parameters) |*free| {
            if (free.name.len == 0) {
                free.name = .init(name);
                break free;
            }
        } else return error.TooManyParameters;
        slot.value = value;
    }

    /// Start every layer over from its entry state, as when the graph changes.
    pub fn restart(self: *AnimationGraph) void {
        self.layers = @splat(.{});
    }

    fn find(self: *const AnimationGraph, name: []const u8) ?*const Parameter {
        for (&self.parameters) |*slot| {
            if (slot.name.len > 0 and std.mem.eql(u8, slot.name.text(), name)) return slot;
        }
        return null;
    }

    fn findMut(self: *AnimationGraph, name: []const u8) ?*Parameter {
        for (&self.parameters) |*slot| {
            if (slot.name.len > 0 and std.mem.eql(u8, slot.name.text(), name)) return slot;
        }
        return null;
    }
};

pub const Error = error{ InvalidParameter, TooManyParameters };
pub const AccessError = Error || error{ InvalidEntity, NoAnimationGraph };

/// Borrowed access to this world's animation graphs; obtain it from `app.animationGraphs()`.
/// Values take effect when the next `step` runs.
pub const Graphs = struct {
    world: *ecs.World,

    /// Set the float or bool parameter `name` of `entity`'s graph (a bool is 1 or 0).
    ///
    /// ```zig
    /// try app.animationGraphs().set(hero, "speed", ground_speed_m_per_s);
    /// ```
    pub fn set(self: Graphs, entity: ecs.EntityId, name: []const u8, value: f32) AccessError!void {
        try (try self.of(entity)).set(name, value);
    }

    /// Set the trigger `name`, which the first transition it lets through spends.
    ///
    /// ```zig
    /// if (jumped) try app.animationGraphs().trigger(hero, "jump");
    /// ```
    pub fn trigger(self: Graphs, entity: ecs.EntityId, name: []const u8) AccessError!void {
        try self.set(entity, name, 1);
    }

    /// The value of the parameter `name`, if the game or the graph gave it one.
    pub fn get(self: Graphs, entity: ecs.EntityId, name: []const u8) AccessError!?f32 {
        return (try self.of(entity)).parameter(name);
    }

    fn of(self: Graphs, entity: ecs.EntityId) AccessError!*AnimationGraph {
        if (!self.world.isAlive(entity)) return error.InvalidEntity;
        return self.world.get(entity, AnimationGraph) orelse error.NoAnimationGraph;
    }
};

/// Run every entity's graph for a frame of `delta_s` seconds (the game's time): move each layer
/// along its transitions, then set its `Animator`'s states for the state it is in. Runs before
/// `animation.step`, which advances those states. Graphs that fail to load are logged once by
/// `graphs` and do nothing.
///
/// ```zig
/// animation_graph.step(&app.world, &app.graphics.graphs, &app.graphics.clips, app.time.delta_s);
/// ```
pub fn step(world: *ecs.World, graphs: *GraphCache, clips: *ClipCache, delta_s: f32) void {
    if (!std.math.isFinite(delta_s)) return;
    var running = world.query(.{ *AnimationGraph, *Animator });
    while (running.next()) |view| {
        const component = view.get(*AnimationGraph);
        if (component.graph.len == 0) continue;
        const parsed = graphs.get(component.graph.key()) orelse continue;
        run(component, view.get(*Animator), parsed.graph, clips, delta_s);
        world.markChanged(view.entity, Animator);
    }
}

/// One frame of `graph` on `component` and `animator`.
pub fn run(component: *AnimationGraph, animator: *Animator, graph: format.Graph, clips: *ClipCache, delta_s: f32) void {
    seedDefaults(component, graph);
    for (graph.layers, component.layers[0..graph.layers.len]) |layer, *where| {
        const entering = moveAlong(component, where, layer, graph, clips, delta_s) orelse continue;
        drive(component, animator, layer, where.*, entering);
    }
}

/// Give each of the graph's parameters the game hasn't set its default.
fn seedDefaults(component: *AnimationGraph, graph: format.Graph) void {
    for (graph.parameters) |parameter| {
        if (component.find(parameter.name) != null) continue;
        const value: f32 = if (parameter.kind == .trigger) 0 else parameter.default;
        component.set(parameter.name, value) catch return;
    }
}

/// Move `where` on by `delta_s`, into the entry state if it hasn't started, or along the first
/// transition that lets it through. Whether it entered a state this frame; null for a layer with
/// no states.
fn moveAlong(component: *AnimationGraph, where: *LayerState, layer: format.Layer, graph: format.Graph, clips: *ClipCache, delta_s: f32) ?bool {
    if (where.state == LayerState.none or where.state >= layer.states.len) {
        const entry = layer.entryIndex() orelse return null;
        where.* = .{ .state = @intCast(entry) };
        return true;
    }
    where.time_s += delta_s;
    const current = layer.states[where.state];
    // Transitions out of any state go first, so a hit interrupts whatever plays.
    for ([_]bool{ true, false }) |from_any| for (layer.transitions) |transition| {
        if ((transition.from.len == 0) != from_any) continue;
        if (!from_any and !std.mem.eql(u8, transition.from, current.name)) continue;
        const target = layer.stateIndex(transition.to) orelse continue;
        if (from_any and target == where.state) continue;
        if (!holds(component, transition, graph)) continue;
        if (transition.wait_for_end and !ended(current.motion, where.time_s, transition.blend_s, clips)) continue;
        spend(component, transition, graph);
        where.* = .{ .state = @intCast(target), .blend_s = transition.blend_s };
        return true;
    };
    return false;
}

fn holds(component: *const AnimationGraph, transition: format.Transition, graph: format.Graph) bool {
    for (transition.conditions) |condition| {
        _ = graph.parameterIndex(condition.parameter) orelse return false;
        const value = component.parameter(condition.parameter) orelse 0;
        const met = switch (condition.check) {
            .triggered, .is_true => value > 0.5,
            .is_false => value <= 0.5,
            .above => value > condition.value,
            .below => value < condition.value,
        };
        if (!met) return false;
    }
    return true;
}

/// Clear the triggers `transition` let through on.
fn spend(component: *AnimationGraph, transition: format.Transition, graph: format.Graph) void {
    for (transition.conditions) |condition| {
        if (condition.check != .triggered) continue;
        _ = graph.parameterIndex(condition.parameter) orelse continue;
        component.set(condition.parameter, 0) catch {};
    }
}

/// Whether `motion`, `time_s` in, is within `blend_s` of its clip's end. A blend state goes by
/// its first clip.
// ponytail: a blend state ends by its first clip alone; time them by normalized time once blended clips are synced.
fn ended(motion: format.Motion, time_s: f32, blend_s: f32, clips: *ClipCache) bool {
    const key, const speed = switch (motion) {
        .clip => |clip| .{ clip.clip, clip.speed },
        .blend_1d => |blend| if (blend.points.len > 0) .{ blend.points[0].clip, blend.points[0].speed } else return true,
        .blend_2d => |blend| if (blend.points.len > 0) .{ blend.points[0].clip, blend.points[0].speed } else return true,
    };
    if (key.len == 0) return true;
    const loaded = clips.get(key) orelse return true;
    return time_s * @abs(speed) >= loaded.duration_s() - blend_s;
}

/// Set `animator`'s states for the state `where` is in. Problems are logged as the state is
/// entered, so a broken state doesn't log every frame.
fn drive(component: *const AnimationGraph, animator: *Animator, layer: format.Layer, where: LayerState, entering: bool) void {
    const state = layer.states[where.state];
    const start_s: ?f32 = if (entering) 0 else null;
    const options = states.Options{ .start_s = start_s, .bone = layer.bone };
    const result = switch (state.motion) {
        .clip => |clip| playClip(animator, clip, where.blend_s, options),
        .blend_1d => |blend| blendAlong(component, animator, blend, where.blend_s, options),
        .blend_2d => |blend| blendAcross(component, animator, blend, where.blend_s, options),
    };
    result catch |err| if (entering) std.log.warn("animation graph state {s} can't play: {t}", .{ state.name, err });
}

fn playClip(animator: *Animator, clip: format.ClipMotion, blend_s: f32, options: states.Options) !void {
    var shown = options;
    shown.speed = clip.speed;
    shown.repeat = switch (clip.repeat) {
        .once => .once,
        .loop => .loop,
    };
    try states.fadeTo(&animator.states, try AssetRef(.animation).parse(clip.clip), blend_s, shown);
}

fn blendAlong(component: *const AnimationGraph, animator: *Animator, blend: format.Blend1d, blend_s: f32, options: states.Options) !void {
    var points: [format.max_points]states.Point = undefined;
    const placed = try pointsOf(blend.points, &points);
    const value = component.parameter(blend.parameter) orelse 0;
    try states.along(&animator.states, placed, value, blend_s, options);
}

fn blendAcross(component: *const AnimationGraph, animator: *Animator, blend: format.Blend2d, blend_s: f32, options: states.Options) !void {
    var points: [format.max_points]states.Point = undefined;
    const placed = try pointsOf(blend.points, &points);
    var places: [format.max_points][2]f32 = undefined;
    for (places[0..placed.len], blend.points) |*place, point| place.* = point.at;
    const value = [2]f32{ component.parameter(blend.parameters[0]) orelse 0, component.parameter(blend.parameters[1]) orelse 0 };
    var weights: [format.max_points]f32 = undefined;
    states.planeWeights(places[0..placed.len], value, &weights);
    try states.mix(&animator.states, placed, weights[0..placed.len], blend_s, options);
}

/// A blend state's points as the `Animator` takes them, in `buffer`.
fn pointsOf(points: []const format.Point, buffer: *[format.max_points]states.Point) ![]const states.Point {
    if (points.len == 0) return error.NoPoints;
    for (buffer[0..points.len], points) |*placed, point| placed.* = .{ .clip = try AssetRef(.animation).parse(point.clip), .at = point.at[0], .speed = point.speed };
    return buffer[0..points.len];
}

test "a layer enters its entry state, and a trigger moves it along a transition and is spent" {
    const gpa = std.testing.allocator;
    const parsed = try format.parse(gpa,
        \\.{
        \\    .parameters = .{ .{ .name = "speed" }, .{ .name = "jump", .kind = .trigger } },
        \\    .layers = .{ .{
        \\        .name = "Base",
        \\        .states = .{
        \\            .{ .name = "Locomotion", .motion = .{ .blend_1d = .{ .parameter = "speed", .points = .{
        \\                .{ .clip = "0000000000000031", .at = .{ 0, 0 } }, .{ .clip = "0000000000000032", .at = .{ 2, 0 } },
        \\            } } } },
        \\            .{ .name = "Jump", .motion = .{ .clip = .{ .clip = "0000000000000033", .repeat = .once } } },
        \\        },
        \\        .transitions = .{ .{ .from = "Locomotion", .to = "Jump", .blend_s = 0, .conditions = .{ .{ .parameter = "jump" } } } },
        \\    } },
        \\}
    );
    defer parsed.deinit();
    var clips: ClipCache = .{ .gpa = gpa };
    defer clips.deinit();
    var component: AnimationGraph = .{};
    var animator: Animator = .{};

    try component.set("speed", 0.5);
    run(&component, &animator, parsed.graph, &clips, 0.1);
    try std.testing.expectEqual(@as(u8, 0), component.layers[0].state);
    const walk = AssetRef(.animation).fromId(0x32);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), states.find(&animator.states, walk).?.weight, 1e-6);

    try component.set("jump", 1);
    run(&component, &animator, parsed.graph, &clips, 0.1);
    try std.testing.expectEqual(@as(u8, 1), component.layers[0].state);
    try std.testing.expectEqual(@as(f32, 0), component.parameter("jump").?);
    const jump = AssetRef(.animation).fromId(0x33);
    try std.testing.expectEqual(@as(f32, 1), states.find(&animator.states, jump).?.weight);
}
