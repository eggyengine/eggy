//! The animation graph the graph editor edits: the file's text as last written, a parsed copy
//! edited in place, which layer is shown and what is selected in it, and the edits that keep the
//! graph's names in step (renaming a state renames it in its transitions). An edit changes the
//! copy; `take` turns it into the file's text before and after, for the file and for History.
const std = @import("std");
const eggy = @import("eggy");
const format = eggy.assets.animation_graph;

const key_len = eggy.assets.id.key_len;

/// The file's text before and after an edit, owned by the document's allocator.
pub const Change = struct { before: []u8, after: []u8 };

/// What the details panel shows, in the layer shown.
pub const Selection = union(enum) {
    layer,
    state: usize,
    transition: usize,
    parameter: usize,
};

pub const Document = struct {
    gpa: std.mem.Allocator,
    /// Project-relative, owned.
    path: []u8,
    key_buffer: [key_len]u8 = undefined,
    key_len: usize = 0,
    /// The file's text as last read or written.
    saved: []u8,
    /// `saved` as `write` puts it, which edits are compared with.
    normal: []u8,
    parsed: format.Parsed,
    /// The layer shown, by index.
    layer: usize = 0,
    selection: Selection = .layer,

    /// The document for `text`, the file at `path` (copied) with asset `key` (may be empty).
    /// Fails when `text` isn't a graph this build reads.
    pub fn init(gpa: std.mem.Allocator, path: []const u8, asset_key: []const u8, text: []const u8) !Document {
        const parsed = try parse(gpa, text);
        errdefer parsed.deinit();
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        const saved = try gpa.dupe(u8, text);
        errdefer gpa.free(saved);
        const normal = try serialize(gpa, parsed.graph);
        var self = Document{ .gpa = gpa, .path = owned_path, .saved = saved, .normal = normal, .parsed = parsed };
        self.key_len = @min(asset_key.len, key_len);
        @memcpy(self.key_buffer[0..self.key_len], asset_key[0..self.key_len]);
        return self;
    }

    pub fn deinit(self: *Document) void {
        self.parsed.deinit();
        self.gpa.free(self.saved);
        self.gpa.free(self.normal);
        self.gpa.free(self.path);
    }

    pub fn key(self: *const Document) []const u8 {
        return self.key_buffer[0..self.key_len];
    }

    pub fn graph(self: *const Document) format.Graph {
        return self.parsed.graph;
    }

    /// Where edited strings and lists live until the next `take`.
    pub fn arena(self: *Document) std.mem.Allocator {
        return self.parsed.arena.allocator();
    }

    /// The layer shown, editable. The graph always has one: `init` and `replace` add it.
    pub fn shown(self: *Document) *format.Layer {
        return &mutable(format.Layer, self.parsed.graph.layers)[self.layer];
    }

    /// The shown layer's states, editable in place.
    pub fn states(self: *Document) []format.State {
        return mutable(format.State, self.shown().states);
    }

    pub fn transitions(self: *Document) []format.Transition {
        return mutable(format.Transition, self.shown().transitions);
    }

    pub fn parameters(self: *Document) []format.Parameter {
        return mutable(format.Parameter, self.parsed.graph.parameters);
    }

    /// The edits since the last `take`, as the file's text before and after; null when nothing
    /// changed. The copy is parsed again from the new text, which frees what edits left behind.
    /// Fails with one of `format.Error` when an edit made a graph that doesn't hold together.
    pub fn take(self: *Document) !?Change {
        try self.parsed.graph.validate();
        const text = try serialize(self.gpa, self.parsed.graph);
        defer self.gpa.free(text);
        if (std.mem.eql(u8, text, self.normal)) return null;

        const parsed = try parse(self.gpa, text);
        errdefer parsed.deinit();
        const after = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(after);
        const saved = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(saved);
        const normal = try self.gpa.dupe(u8, text);
        self.parsed.deinit();
        self.parsed = parsed;
        self.gpa.free(self.normal);
        self.normal = normal;
        const before = self.saved;
        self.saved = saved;
        return .{ .before = before, .after = after };
    }

    /// Show `text` instead (an undo or redo, or the file changed), keeping the layer and
    /// selection when they still name something.
    pub fn replace(self: *Document, text: []const u8) !void {
        const parsed = try parse(self.gpa, text);
        errdefer parsed.deinit();
        const saved = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(saved);
        const normal = try serialize(self.gpa, parsed.graph);
        self.parsed.deinit();
        self.parsed = parsed;
        self.gpa.free(self.saved);
        self.saved = saved;
        self.gpa.free(self.normal);
        self.normal = normal;
        if (self.layer >= self.parsed.graph.layers.len) self.layer = 0;
        self.selection = switch (self.selection) {
            .layer => .layer,
            .state => |index| if (index < self.shown().states.len) self.selection else .layer,
            .transition => |index| if (index < self.shown().transitions.len) self.selection else .layer,
            .parameter => |index| if (index < self.parsed.graph.parameters.len) self.selection else .layer,
        };
    }

    pub fn showLayer(self: *Document, index: usize) void {
        self.layer = @min(index, self.parsed.graph.layers.len - 1);
        self.selection = .layer;
    }

    /// Add a state playing `motion` at `position`, named after `base` (numbered when taken),
    /// and select it. The first state of a layer is its entry.
    pub fn addState(self: *Document, base: []const u8, motion: format.Motion, position: [2]f32) !void {
        const layer = self.shown();
        if (layer.states.len >= format.max_states) return error.TooManyStates;
        const name = try self.freeName(base, stateTaken);
        layer.states = try appended(format.State, self.arena(), layer.states, .{ .name = name, .motion = motion, .position = position });
        if (layer.entry.len == 0) layer.entry = name;
        self.selection = .{ .state = layer.states.len - 1 };
    }

    /// Remove state `index` and every transition into or out of it.
    pub fn removeState(self: *Document, index: usize) !void {
        const layer = self.shown();
        const name = layer.states[index].name;
        var kept: std.ArrayList(format.Transition) = .empty;
        for (layer.transitions) |transition| {
            if (std.mem.eql(u8, transition.from, name) or std.mem.eql(u8, transition.to, name)) continue;
            try kept.append(self.arena(), transition);
        }
        layer.transitions = kept.items;
        layer.states = try without(format.State, self.arena(), layer.states, index);
        if (std.mem.eql(u8, layer.entry, name)) layer.entry = if (layer.states.len > 0) layer.states[0].name else "";
        self.selection = .layer;
    }

    /// Rename state `index` to `name`, in the transitions and the entry too. Fails with
    /// `error.DuplicateName` for a name another state has, and `error.EmptyName` for none.
    pub fn renameState(self: *Document, index: usize, name: []const u8) !void {
        if (name.len == 0) return error.EmptyName;
        const layer = self.shown();
        const old = layer.states[index].name;
        if (std.mem.eql(u8, old, name)) return;
        if (layer.stateIndex(name) != null) return error.DuplicateName;
        const owned = try self.arena().dupe(u8, name);
        for (self.transitions()) |*transition| {
            if (std.mem.eql(u8, transition.from, old)) transition.from = owned;
            if (std.mem.eql(u8, transition.to, old)) transition.to = owned;
        }
        if (std.mem.eql(u8, layer.entry, old)) layer.entry = owned;
        self.states()[index].name = owned;
    }

    /// Add a transition from state `from` (null: any state) to state `to`, and select it. One
    /// that is already there is selected instead.
    pub fn addTransition(self: *Document, from: ?usize, to: usize) !void {
        const layer = self.shown();
        const from_name = if (from) |index| layer.states[index].name else "";
        const to_name = layer.states[to].name;
        if (from != null and from.? == to) return error.SameState;
        for (layer.transitions, 0..) |transition, index| {
            if (std.mem.eql(u8, transition.from, from_name) and std.mem.eql(u8, transition.to, to_name)) {
                self.selection = .{ .transition = index };
                return;
            }
        }
        layer.transitions = try appended(format.Transition, self.arena(), layer.transitions, .{ .from = from_name, .to = to_name });
        self.selection = .{ .transition = layer.transitions.len - 1 };
    }

    pub fn removeTransition(self: *Document, index: usize) !void {
        const layer = self.shown();
        layer.transitions = try without(format.Transition, self.arena(), layer.transitions, index);
        self.selection = .layer;
    }

    /// Add a condition on the first parameter to transition `index`.
    pub fn addCondition(self: *Document, index: usize) !void {
        const graph_parameters = self.parsed.graph.parameters;
        if (graph_parameters.len == 0) return error.NoParameters;
        const transition = &self.transitions()[index];
        transition.conditions = try appended(format.Condition, self.arena(), transition.conditions, .{ .parameter = graph_parameters[0].name, .check = defaultCheck(graph_parameters[0].kind) });
    }

    pub fn removeCondition(self: *Document, transition: usize, condition: usize) !void {
        const owner = &self.transitions()[transition];
        owner.conditions = try without(format.Condition, self.arena(), owner.conditions, condition);
    }

    /// Add a parameter of `kind`, named after it, and select it.
    pub fn addParameter(self: *Document, kind: format.ParameterKind) !void {
        if (self.parsed.graph.parameters.len >= format.max_parameters) return error.TooManyParameters;
        const name = try self.freeName(@tagName(kind), parameterTaken);
        self.parsed.graph.parameters = try appended(format.Parameter, self.arena(), self.parsed.graph.parameters, .{ .name = name, .kind = kind });
        self.selection = .{ .parameter = self.parsed.graph.parameters.len - 1 };
    }

    /// Remove parameter `index`, the conditions that test it, and the blend axes it drives.
    pub fn removeParameter(self: *Document, index: usize) !void {
        const name = self.parsed.graph.parameters[index].name;
        try self.forEachUse(name, null);
        self.parsed.graph.parameters = try without(format.Parameter, self.arena(), self.parsed.graph.parameters, index);
        self.selection = .layer;
    }

    /// Rename parameter `index` to `name` everywhere it is used.
    pub fn renameParameter(self: *Document, index: usize, name: []const u8) !void {
        if (name.len == 0) return error.EmptyName;
        const old = self.parsed.graph.parameters[index].name;
        if (std.mem.eql(u8, old, name)) return;
        if (self.parsed.graph.parameterIndex(name) != null) return error.DuplicateName;
        const owned = try self.arena().dupe(u8, name);
        try self.forEachUse(old, owned);
        self.parameters()[index].name = owned;
    }

    /// Change parameter `index` to `kind`: the conditions that test it change to a check that
    /// fits, and blend axes stop using one that isn't a float.
    pub fn setParameterKind(self: *Document, index: usize, kind: format.ParameterKind) !void {
        const parameter = &self.parameters()[index];
        if (parameter.kind == kind) return;
        parameter.kind = kind;
        for (mutable(format.Layer, self.parsed.graph.layers)) |*layer| {
            for (mutable(format.Transition, layer.transitions)) |*transition| for (mutable(format.Condition, transition.conditions)) |*condition| {
                if (std.mem.eql(u8, condition.parameter, parameter.name) and !condition.check.fits(kind)) condition.check = defaultCheck(kind);
            };
            if (kind != .float) for (mutable(format.State, layer.states)) |*state| clearAxis(state, parameter.name, "");
        }
    }

    /// Point every use of the parameter `old` at `new`, or, when `new` is null, drop the
    /// conditions on it and clear the axes it drives.
    fn forEachUse(self: *Document, old: []const u8, new: ?[]const u8) !void {
        for (mutable(format.Layer, self.parsed.graph.layers)) |*layer| {
            for (mutable(format.Transition, layer.transitions)) |*transition| {
                var kept: std.ArrayList(format.Condition) = .empty;
                for (transition.conditions) |condition| {
                    if (!std.mem.eql(u8, condition.parameter, old)) {
                        try kept.append(self.arena(), condition);
                    } else if (new) |name| {
                        var renamed = condition;
                        renamed.parameter = name;
                        try kept.append(self.arena(), renamed);
                    }
                }
                transition.conditions = kept.items;
            }
            for (mutable(format.State, layer.states)) |*state| clearAxis(state, old, new orelse "");
        }
    }

    /// Add a layer over the body's, and show it.
    pub fn addLayer(self: *Document) !void {
        if (self.parsed.graph.layers.len >= format.max_layers) return error.TooManyLayers;
        const name = try self.freeName("Layer", layerTaken);
        self.parsed.graph.layers = try appended(format.Layer, self.arena(), self.parsed.graph.layers, .{ .name = name });
        self.showLayer(self.parsed.graph.layers.len - 1);
    }

    /// Remove the layer shown; the graph keeps at least one.
    pub fn removeLayer(self: *Document) !void {
        if (self.parsed.graph.layers.len <= 1) return error.LastLayer;
        self.parsed.graph.layers = try without(format.Layer, self.arena(), self.parsed.graph.layers, self.layer);
        self.showLayer(@min(self.layer, self.parsed.graph.layers.len - 1));
    }

    /// `text` kept in the document's arena, for a field an edit sets.
    pub fn own(self: *Document, text: []const u8) ![]const u8 {
        return self.arena().dupe(u8, text);
    }

    /// `base`, numbered from 2 until `taken` says no one has it, in the arena.
    fn freeName(self: *Document, base: []const u8, comptime taken: fn (*Document, []const u8) bool) ![]const u8 {
        if (!taken(self, base)) return self.arena().dupe(u8, base);
        var number: usize = 2;
        while (true) : (number += 1) {
            const name = try std.fmt.allocPrint(self.arena(), "{s} {d}", .{ base, number });
            if (!taken(self, name)) return name;
        }
    }
};

fn stateTaken(self: *Document, name: []const u8) bool {
    return self.shown().stateIndex(name) != null;
}

fn parameterTaken(self: *Document, name: []const u8) bool {
    return self.parsed.graph.parameterIndex(name) != null;
}

fn layerTaken(self: *Document, name: []const u8) bool {
    for (self.parsed.graph.layers) |layer| if (std.mem.eql(u8, layer.name, name)) return true;
    return false;
}

/// The check a new condition on a parameter of `kind` starts with.
pub fn defaultCheck(kind: format.ParameterKind) format.Check {
    return switch (kind) {
        .trigger => .triggered,
        .bool => .is_true,
        .float => .above,
    };
}

/// Point a blend state's axes that name `old` at `new` (empty clears them).
fn clearAxis(state: *format.State, old: []const u8, new: []const u8) void {
    switch (state.motion) {
        .clip, .none => {},
        .blend_1d => |*blend| if (std.mem.eql(u8, blend.parameter, old)) {
            blend.parameter = new;
        },
        .blend_2d => |*blend| for (&blend.parameters) |*parameter| if (std.mem.eql(u8, parameter.*, old)) {
            parameter.* = new;
        },
    }
}

/// Everything the document points at lives in its arena, so its lists may be edited in place.
pub fn mutable(comptime T: type, slice: []const T) []T {
    return @constCast(slice);
}

/// `slice` with `item` after it, in `arena`.
pub fn appended(comptime T: type, arena: std.mem.Allocator, slice: []const T, item: T) ![]T {
    const grown = try arena.alloc(T, slice.len + 1);
    @memcpy(grown[0..slice.len], slice);
    grown[slice.len] = item;
    return grown;
}

/// `slice` without the item at `index`, in `arena`.
pub fn without(comptime T: type, arena: std.mem.Allocator, slice: []const T, index: usize) ![]T {
    const shrunk = try arena.alloc(T, slice.len - 1);
    @memcpy(shrunk[0..index], slice[0..index]);
    @memcpy(shrunk[index..], slice[index + 1 ..]);
    return shrunk;
}

/// Parse `text`, giving a graph with no layers one, so there is always a layer to show.
fn parse(gpa: std.mem.Allocator, text: []const u8) !format.Parsed {
    const source = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(source);
    var parsed = try format.parse(gpa, source);
    errdefer parsed.deinit();
    if (parsed.graph.layers.len == 0) parsed.graph.layers = try appended(format.Layer, parsed.arena.allocator(), &.{}, .{ .name = "Base" });
    return parsed;
}

fn serialize(gpa: std.mem.Allocator, graph: format.Graph) ![]u8 {
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try graph.write(&bytes.writer);
    return gpa.dupe(u8, bytes.written());
}
