//! Each build step's own progress, followed across Zig's progress snapshots: every step seen
//! keeps a row, running until it leaves the snapshots, with the counter of the work inside it and
//! that work itself (`Work`), for opening the row up.
const std = @import("std");

/// One node of a `std.Progress` snapshot as Zig sends it (little endian; see `std.Progress`).
pub const ProgressNode = extern struct {
    completed_count: u32,
    /// 0 when unknown; maxInt marks a node standing in for a child process.
    estimated_total_count: u32,
    name: [120]u8 align(@alignOf(usize)),

    pub fn nameText(node: *const ProgressNode) []const u8 {
        return std.mem.sliceTo(&node.name, 0);
    }

    pub fn done(node: *const ProgressNode) u32 {
        return std.mem.littleToNative(u32, node.completed_count);
    }

    /// Its total, null when unknown or standing in for a child process.
    pub fn total(node: *const ProgressNode) ?u32 {
        const value = std.mem.littleToNative(u32, node.estimated_total_count);
        return if (value == 0 or value == std.math.maxInt(u32)) null else value;
    }
};

/// A step's row: its name, how far it is (null when its work has no count), what it is doing,
/// and whether it is still going. Plain data, copied out for drawing.
pub const Step = struct {
    name_buffer: [120]u8 = undefined,
    name_len: u8 = 0,
    task_buffer: [96]u8 = undefined,
    task_len: u8 = 0,
    fraction: ?f32 = null,
    state: State = .running,
    /// The counter `fraction` came from last snapshot (its name's hash) and its total then.
    counter_hash: u64 = 0,
    counter_total: u32 = 0,
    /// What is under way inside it, outermost first, as Zig nests it; empty once it finishes.
    work: [max_work]Work = undefined,
    work_len: u8 = 0,

    pub const State = enum { running, done, failed };
    pub const max_work = 12;

    pub fn name(self: *const Step) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    pub fn task(self: *const Step) []const u8 {
        return self.task_buffer[0..self.task_len];
    }

    pub fn works(self: *const Step) []const Work {
        return self.work[0..self.work_len];
    }
};

/// A piece of work inside a step: its name, how deep inside the step (1 for its own children),
/// and its count, if it has one.
pub const Work = struct {
    name_buffer: [64]u8 = undefined,
    name_len: u8 = 0,
    depth: u8,
    done: u32 = 0,
    total: ?u32 = null,

    pub fn name(self: *const Work) []const u8 {
        return self.name_buffer[0..self.name_len];
    }
};

/// Every step a build has shown, in the order they started.
pub const Steps = struct {
    /// A build of many steps folds its earliest finished ones away; this bounds the memory.
    pub const max = 128;

    rows: [max]Step = undefined,
    count: usize = 0,

    pub fn items(self: *const Steps) []const Step {
        return self.rows[0..self.count];
    }

    /// Take one snapshot (`nodes` and their `parents`): steps in it are running, with the counter
    /// deepest inside each; running steps no longer in it have finished.
    pub fn observe(self: *Steps, nodes: []const ProgressNode, parents: []const u8) void {
        var seen: [max]bool = @splat(false);
        for (nodes, 0..) |node, index| {
            if (!isStep(nodes, parents, index)) continue;
            const row = self.find(node.nameText()) orelse self.start(node.nameText()) orelse continue;
            seen[row] = true;
            const step = &self.rows[row];
            step.state = .running;
            describeWork(step, nodes, parents, index);
        }
        for (self.rows[0..self.count], seen[0..self.count]) |*step, still| {
            if (step.state == .running and !still) finish(step, .done);
        }
    }

    /// The build is over: steps still running finished with it, or stopped where it failed.
    pub fn end(self: *Steps, succeeded: bool) void {
        for (self.rows[0..self.count]) |*step| {
            if (step.state == .running) finish(step, if (succeeded) .done else .failed);
        }
    }

    fn find(self: *const Steps, name: []const u8) ?usize {
        for (self.rows[0..self.count], 0..) |*step, i| if (std.mem.eql(u8, step.name(), name)) return i;
        return null;
    }

    /// A new row for `name`; when full, the oldest finished row makes way.
    fn start(self: *Steps, name: []const u8) ?usize {
        if (self.count == max) {
            const oldest = for (self.rows[0..self.count], 0..) |step, i| {
                if (step.state != .running) break i;
            } else return null;
            std.mem.copyForwards(Step, self.rows[oldest .. self.count - 1], self.rows[oldest + 1 .. self.count]);
            self.count -= 1;
        }
        var step = Step{};
        step.name_len = @intCast(@min(name.len, step.name_buffer.len));
        @memcpy(step.name_buffer[0..step.name_len], name[0..step.name_len]);
        self.rows[self.count] = step;
        self.count += 1;
        return self.count - 1;
    }
};

fn finish(step: *Step, state: Step.State) void {
    step.state = state;
    step.task_len = 0;
    step.work_len = 0;
    if (state == .done) step.fraction = 1;
}

/// Whether node `index` is a build step: a named child of a "steps" counter that isn't itself a
/// nested build (whose own steps stand for it).
fn isStep(nodes: []const ProgressNode, parents: []const u8, index: usize) bool {
    const parent = parents[index];
    if (parent >= nodes.len or !std.mem.eql(u8, nodes[parent].nameText(), "steps")) return false;
    if (nodes[index].nameText().len == 0) return false;
    for (nodes, 0..) |node, other| {
        if (other != index and std.mem.eql(u8, node.nameText(), "steps") and isInside(parents, other, index)) return false;
    }
    return true;
}

/// The step's progress from the deepest counter inside it (its own, without one), and its task:
/// that counter's name and count, or the deepest named node inside when nothing counts. A counter
/// whose total is still growing (the compiler's, as it finds more to do) gives no fraction: it
/// would read as nearly done throughout.
fn describeWork(step: *Step, nodes: []const ProgressNode, parents: []const u8, index: usize) void {
    var counter: ?usize = if (nodes[index].total() != null) index else null;
    var counter_depth: usize = 0;
    var named: ?usize = null;
    var named_depth: usize = 0;
    for (nodes, 0..) |node, inner| {
        if (inner == index or !isInside(parents, inner, index)) continue;
        const depth = depthOf(parents, inner);
        if (node.total() != null and depth >= counter_depth) {
            counter = inner;
            counter_depth = depth;
        }
        if (node.nameText().len > 0 and depth >= named_depth) {
            named = inner;
            named_depth = depth;
        }
    }
    var writer: std.Io.Writer = .fixed(&step.task_buffer);
    if (counter) |at| {
        const node = &nodes[at];
        const total = node.total().?;
        const hash = std.hash.Wyhash.hash(0, node.nameText());
        const settled = hash == step.counter_hash and total == step.counter_total;
        step.counter_hash = hash;
        step.counter_total = total;
        step.fraction = if (settled) std.math.clamp(@as(f32, @floatFromInt(node.done())) / @as(f32, @floatFromInt(total)), 0, 1) else null;
        if (at != index) writer.print("{s} {d}/{d}", .{ node.nameText(), node.done(), total }) catch {};
    } else {
        step.fraction = null;
        step.counter_hash = 0;
        if (named) |at| writer.writeAll(nodes[at].nameText()) catch {};
    }
    step.task_len = @intCast(writer.end);
    step.work_len = 0;
    collectWork(step, nodes, parents, index, 1);
}

/// The named nodes under node `parent`, each followed by its own, into `step.work`.
fn collectWork(step: *Step, nodes: []const ProgressNode, parents: []const u8, parent: usize, depth: u8) void {
    for (nodes, parents, 0..) |*node, of, inner| {
        if (of != parent or inner == parent) continue;
        if (step.work_len == Step.max_work) return;
        // An unnamed node only groups: its work shows at its depth.
        if (node.nameText().len == 0) {
            collectWork(step, nodes, parents, inner, depth);
            continue;
        }
        var work = Work{ .depth = depth, .done = node.done(), .total = node.total() };
        const text = node.nameText();
        work.name_len = @intCast(@min(text.len, work.name_buffer.len));
        @memcpy(work.name_buffer[0..work.name_len], text[0..work.name_len]);
        step.work[step.work_len] = work;
        step.work_len += 1;
        collectWork(step, nodes, parents, inner, depth +| 1);
    }
}

/// Whether node `inner` is under node `outer`.
fn isInside(parents: []const u8, inner: usize, outer: usize) bool {
    var at = inner;
    for (0..parents.len) |_| {
        const parent = parents[at];
        if (parent >= parents.len) return false;
        if (parent == outer) return true;
        at = parent;
    }
    return false;
}

/// How many parents node `index` has; a broken chain counts as deep.
pub fn depthOf(parents: []const u8, index: usize) usize {
    var depth: usize = 0;
    var at = index;
    while (parents[at] < parents.len) : (depth += 1) {
        if (depth == parents.len) return depth;
        at = parents[at];
    }
    return depth;
}

fn testNodes(comptime names: []const []const u8, counts: []const [2]u32) [names.len]ProgressNode {
    var nodes: [names.len]ProgressNode = undefined;
    for (&nodes, names, counts) |*node, name, count| {
        node.* = .{ .completed_count = count[0], .estimated_total_count = count[1], .name = @splat(0) };
        @memcpy(node.name[0..name.len], name);
    }
    return nodes;
}

test "each running step gets a row with the counter inside it, and finishes when it leaves" {
    var steps = Steps{};
    // Two steps run: a compile at code generation 30/120, and an install with no count.
    const first = testNodes(&.{ "", "steps", "compile exe game_editor", "zig", "Code Generation", "install" }, &.{ .{ 0, 0 }, .{ 2, 9 }, .{ 0, 0 }, .{ 0, std.math.maxInt(u32) }, .{ 30, 120 }, .{ 0, 0 } });
    steps.observe(&first, &.{ 255, 0, 1, 2, 3, 1 });
    // Seen once, the total may still grow; seen again unchanged, it counts.
    try std.testing.expect(steps.items()[0].fraction == null);
    steps.observe(&first, &.{ 255, 0, 1, 2, 3, 1 });
    try std.testing.expectEqual(@as(usize, 2), steps.count);
    const compile = steps.items()[0];
    try std.testing.expectEqualStrings("compile exe game_editor", compile.name());
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), compile.fraction.?, 0.001);
    try std.testing.expectEqualStrings("Code Generation 30/120", compile.task());
    try std.testing.expect(steps.items()[1].fraction == null);
    // Opened up, the compile shows the compiler's process and its code generation under it.
    try std.testing.expectEqual(@as(usize, 2), compile.works().len);
    try std.testing.expectEqualStrings("zig", compile.works()[0].name());
    try std.testing.expectEqualStrings("Code Generation", compile.works()[1].name());
    try std.testing.expectEqual(@as(u8, 2), compile.works()[1].depth);
    try std.testing.expectEqual(@as(?u32, 120), compile.works()[1].total);

    // The install is gone from the next snapshot: done. The build then fails with the compile running.
    const second = testNodes(&.{ "", "steps", "compile exe game_editor" }, &.{ .{ 0, 0 }, .{ 3, 9 }, .{ 0, 0 } });
    steps.observe(&second, &.{ 255, 0, 1 });
    try std.testing.expectEqual(Step.State.done, steps.items()[1].state);
    try std.testing.expectEqual(@as(?f32, 1), steps.items()[1].fraction);
    steps.end(false);
    try std.testing.expectEqual(Step.State.failed, steps.items()[0].state);
}

test "a nested build is shown by its own steps, not as one" {
    var steps = Steps{};
    const nodes = testNodes(&.{ "", "steps", "zig build runtime", "steps", "compile exe game" }, &.{ .{ 0, 0 }, .{ 1, 4 }, .{ 0, std.math.maxInt(u32) }, .{ 3, 6 }, .{ 0, 0 } });
    steps.observe(&nodes, &.{ 255, 0, 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 1), steps.count);
    try std.testing.expectEqualStrings("compile exe game", steps.items()[0].name());
}
