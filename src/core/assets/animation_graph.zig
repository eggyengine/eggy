//! The `.graph.zon` format: an animation graph, the state machines an `AnimationGraph`
//! component runs. It names its parameters (numbers, switches and triggers the game sets), then
//! its layers: the whole body first, then any layer over a bone and those below it. Each layer
//! is a state machine whose states play a clip or blend clips by parameters (along one axis or
//! across two), and whose transitions move between them when their conditions hold.
//!
//!     .{
//!         .format_version = 1,
//!         .parameters = .{ .{ .name = "speed" }, .{ .name = "jump", .kind = .trigger } },
//!         .layers = .{ .{
//!             .name = "Base",
//!             .entry = "Locomotion",
//!             .states = .{
//!                 .{ .name = "Locomotion", .motion = .{ .blend_1d = .{ .parameter = "speed", .points = .{
//!                     .{ .clip = "<idle key>", .at = .{ 0, 0 } }, .{ .clip = "<run key>", .at = .{ 6, 0 } },
//!                 } } } },
//!                 .{ .name = "Jump", .motion = .{ .clip = .{ .clip = "<jump key>", .repeat = .once } } },
//!             },
//!             .transitions = .{ .{ .from = "Locomotion", .to = "Jump", .conditions = .{ .{ .parameter = "jump" } } } },
//!         } },
//!     }
//!
//! Clips are named by their asset keys (`AssetRef(.animation).key()`), states and parameters by
//! name. A transition with an empty `from` leaves any state. A state may play nothing
//! (`.motion = .none`), fading its layer out. Positions are where the editor draws each node,
//! and change nothing at run time.
const std = @import("std");
const zon_file = @import("zon.zig");
const RootMotion = @import("rig.zig").RootMotion;

pub const extension = ".graph.zon";
pub const format_version: u32 = 1;

/// The most of each a graph may hold, so a runtime component holds them in fixed arrays.
pub const max_parameters = 16;
pub const max_layers = 4;
pub const max_states = 32;
/// A blend state's clips all play at once, so they share the 8 slots an `Animator` mixes.
pub const max_points = 8;

/// A new graph: one layer with nothing in it yet.
pub const template =
    \\.{
    \\    .format_version = 1,
    \\    .parameters = .{},
    \\    .layers = .{.{ .name = "Base" }},
    \\}
    \\
;

pub const ParameterKind = enum {
    /// A number, such as a speed.
    float,
    /// On or off: 0 or 1.
    bool,
    /// Set by the game, and spent by the first transition it lets through.
    trigger,
};

pub const Parameter = struct {
    name: []const u8,
    kind: ParameterKind = .float,
    /// Its value before the game sets one; for a bool, 1 is on.
    default: f32 = 0,
};

pub const Repeat = enum { once, loop };

/// A clip placed in a blend state: along one axis (`at[0]`), or on a plane (`at`).
pub const Point = struct {
    clip: []const u8 = "",
    at: [2]f32 = .{ 0, 0 },
    /// Its playback rate, times the state's.
    speed: f32 = 1,
};

pub const ClipMotion = struct {
    clip: []const u8 = "",
    speed: f32 = 1,
    repeat: Repeat = .loop,
};

pub const Blend1d = struct {
    /// The float parameter that places the pose along the axis.
    parameter: []const u8 = "",
    /// In ascending `at[0]`.
    points: []const Point = &.{},
};

pub const Blend2d = struct {
    /// The float parameters across and up.
    parameters: [2][]const u8 = .{ "", "" },
    points: []const Point = &.{},
};

/// What a state plays.
pub const Motion = union(enum) {
    clip: ClipMotion,
    blend_1d: Blend1d,
    blend_2d: Blend2d,
    /// Nothing: the layer's states fade out over the transition's blend, so a layer over a bone
    /// can rest and let the layers before it show.
    none,
};

pub const State = struct {
    name: []const u8,
    motion: Motion = .{ .clip = .{} },
    /// What its clips do with the root bone.
    root_motion: RootMotion = .keep,
    /// Where its clips start when it is entered, in seconds into each.
    start_s: f32 = 0,
    /// Where the editor draws it, in the graph's units.
    position: [2]f32 = .{ 0, 0 },
};

pub const Check = enum {
    /// A trigger is set; the transition spends it.
    triggered,
    is_true,
    is_false,
    /// A float is above, or below, `value`.
    above,
    below,

    /// Whether it tests a parameter of `kind`.
    pub fn fits(self: Check, kind: ParameterKind) bool {
        return switch (self) {
            .triggered => kind == .trigger,
            .is_true, .is_false => kind == .bool,
            .above, .below => kind == .float,
        };
    }
};

pub const Condition = struct {
    parameter: []const u8,
    check: Check = .triggered,
    value: f32 = 0,
};

pub const Transition = struct {
    /// The state it leaves; empty for any state.
    from: []const u8 = "",
    to: []const u8,
    /// All must hold; none lets it through as soon as it may.
    conditions: []const Condition = &.{},
    /// How long the state it enters takes to fade in, in seconds.
    blend_s: f32 = 0.15,
    /// Let it through only once the state it leaves has played its clip to the end, less
    /// `blend_s`.
    wait_for_end: bool = false,
};

pub const Layer = struct {
    name: []const u8,
    /// The bone it moves, with every bone below it, over the layers before it; empty for the
    /// whole body.
    bone: []const u8 = "",
    /// The state it starts in; empty for the first.
    entry: []const u8 = "",
    states: []const State = &.{},
    transitions: []const Transition = &.{},
    /// Where the editor draws the Entry and Any state nodes.
    entry_position: [2]f32 = .{ -200, 0 },
    any_position: [2]f32 = .{ -200, 160 },

    /// The index of the state named `name`.
    pub fn stateIndex(self: Layer, name: []const u8) ?usize {
        for (self.states, 0..) |state, index| {
            if (std.mem.eql(u8, state.name, name)) return index;
        }
        return null;
    }

    /// The state the layer starts in, if it has any.
    pub fn entryIndex(self: Layer) ?usize {
        if (self.states.len == 0) return null;
        return self.stateIndex(self.entry) orelse 0;
    }
};

pub const Graph = struct {
    format_version: u32 = format_version,
    parameters: []const Parameter = &.{},
    layers: []const Layer = &.{},

    /// The index of the parameter named `name`.
    pub fn parameterIndex(self: Graph, name: []const u8) ?usize {
        for (self.parameters, 0..) |parameter, index| {
            if (std.mem.eql(u8, parameter.name, name)) return index;
        }
        return null;
    }

    /// Write the graph as `.graph.zon` text.
    pub fn write(self: Graph, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.zon.stringify.serialize(self, .{ .emit_default_optional_fields = false }, writer);
        try writer.writeByte('\n');
    }

    /// Check that every name a graph uses is one it holds and that it fits the limits.
    pub fn validate(self: Graph) Error!void {
        if (self.format_version != format_version) return error.UnsupportedVersion;
        if (self.parameters.len > max_parameters) return error.TooManyParameters;
        if (self.layers.len > max_layers) return error.TooManyLayers;
        for (self.parameters, 0..) |parameter, index| {
            if (parameter.name.len == 0) return error.UnnamedParameter;
            if (self.parameterIndex(parameter.name) != index) return error.DuplicateName;
        }
        for (self.layers) |layer| {
            if (layer.states.len > max_states) return error.TooManyStates;
            if (layer.entry.len > 0 and layer.stateIndex(layer.entry) == null) return error.UnknownState;
            for (layer.states, 0..) |state, index| {
                if (state.name.len == 0) return error.UnnamedState;
                if (layer.stateIndex(state.name) != index) return error.DuplicateName;
                if (!(state.start_s >= 0) or !std.math.isFinite(state.start_s)) return error.InvalidNumber;
                try self.validateMotion(state.motion);
            }
            for (layer.transitions) |transition| {
                if (transition.from.len > 0 and layer.stateIndex(transition.from) == null) return error.UnknownState;
                if (layer.stateIndex(transition.to) == null) return error.UnknownState;
                if (!(transition.blend_s >= 0) or !std.math.isFinite(transition.blend_s)) return error.InvalidNumber;
                for (transition.conditions) |condition| {
                    const parameter = self.parameterIndex(condition.parameter) orelse return error.UnknownParameter;
                    if (!condition.check.fits(self.parameters[parameter].kind)) return error.MismatchedCheck;
                }
            }
        }
    }

    fn validateMotion(self: Graph, motion: Motion) Error!void {
        switch (motion) {
            .clip => |clip| if (!std.math.isFinite(clip.speed)) return error.InvalidNumber,
            .blend_1d => |blend| {
                try self.validateAxis(blend.parameter);
                try validatePoints(blend.points);
                if (blend.points.len > 1) for (blend.points[1..], blend.points[0 .. blend.points.len - 1]) |point, before| {
                    if (!(point.at[0] > before.at[0])) return error.UnsortedPoints;
                };
            },
            .blend_2d => |blend| {
                for (blend.parameters) |parameter| try self.validateAxis(parameter);
                try validatePoints(blend.points);
            },
            .none => {},
        }
    }

    fn validateAxis(self: Graph, parameter: []const u8) Error!void {
        if (parameter.len == 0) return;
        const index = self.parameterIndex(parameter) orelse return error.UnknownParameter;
        if (self.parameters[index].kind != .float) return error.MismatchedCheck;
    }
};

fn validatePoints(points: []const Point) Error!void {
    if (points.len > max_points) return error.TooManyPoints;
    for (points) |point| {
        for (point.at) |at| if (!std.math.isFinite(at)) return error.InvalidNumber;
        if (!std.math.isFinite(point.speed)) return error.InvalidNumber;
    }
}

/// A graph read from text, owning everything it points at.
pub const Parsed = struct {
    arena: *std.heap.ArenaAllocator,
    graph: Graph,

    pub fn deinit(self: Parsed) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

/// Read and validate `.graph.zon` text; the caller owns the result (`deinit`). Fails with
/// `error.ParseZon` for text that isn't a graph, or one of `Error` for a graph that doesn't hold
/// together.
///
/// ```zig
/// const parsed = try animation_graph.parse(gpa, source);
/// defer parsed.deinit();
/// ```
pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !Parsed {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const graph = try zon_file.parse(Graph, arena.allocator(), source, .{ .ignore_unknown_fields = true });
    try graph.validate();
    return .{ .arena = arena, .graph = graph };
}

pub const Error = error{ UnsupportedVersion, TooManyParameters, TooManyLayers, TooManyStates, TooManyPoints, UnnamedParameter, UnnamedState, DuplicateName, UnknownState, UnknownParameter, MismatchedCheck, UnsortedPoints, InvalidNumber };
