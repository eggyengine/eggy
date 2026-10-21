const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;
const panel_zig = @import("panel.zig");
const status = @import("status.zig");
const repo_zig = @import("repo.zig");

fn atlas(font: *const ui.Font, u: f32, v: f32) f32 {
    const x = std.math.clamp(u * ui.atlas_width - 0.5, 0, ui.atlas_width - 1);
    const y = std.math.clamp(v * ui.atlas_height - 0.5, 0, ui.atlas_height - 1);
    const x0: usize = @intFromFloat(@floor(x));
    const y0: usize = @intFromFloat(@floor(y));
    const x1 = @min(x0 + 1, ui.atlas_width - 1);
    const y1 = @min(y0 + 1, ui.atlas_height - 1);
    const fx = x - @floor(x);
    const fy = y - @floor(y);
    const p = font.pixels;
    const s = struct {
        fn at(px: []const u8, xx: usize, yy: usize) f32 {
            return @as(f32, @floatFromInt(px[yy * ui.atlas_width + xx])) / 255;
        }
    }.at;
    const top = s(p, x0, y0) * (1 - fx) + s(p, x1, y0) * fx;
    const bottom = s(p, x0, y1) * (1 - fx) + s(p, x1, y1) * fx;
    return top * (1 - fy) + bottom * fy;
}

fn edge(sample: f32, e: f32, width: f32) f32 {
    return std.math.clamp((sample - e) / width + 0.5, 0, 1);
}

fn rasterize(gpa: std.mem.Allocator, font: *const ui.Font, vertices: []const ui.Vertex, w: usize, h: usize, background: [4]f32, path: []const u8) !void {
    const image = try gpa.alloc([3]f32, w * h);
    defer gpa.free(image);
    @memset(image, .{ background[0], background[1], background[2] });
    var i: usize = 0;
    while (i + 2 < vertices.len) : (i += 3) {
        const a = vertices[i];
        const b = vertices[i + 1];
        const c = vertices[i + 2];
        const area = (b.position[0] - a.position[0]) * (c.position[1] - a.position[1]) - (c.position[0] - a.position[0]) * (b.position[1] - a.position[1]);
        if (@abs(area) < 1e-6) continue;
        // uv per screen pixel
        const sizes = [2]f32{ ui.atlas_width, ui.atlas_height };
        var tpp: f32 = 0;
        for (0..2) |k| {
            const du_dx = ((b.uv[k] - a.uv[k]) * (c.position[1] - a.position[1]) - (c.uv[k] - a.uv[k]) * (b.position[1] - a.position[1])) / area;
            const du_dy = ((c.uv[k] - a.uv[k]) * (b.position[0] - a.position[0]) - (b.uv[k] - a.uv[k]) * (c.position[0] - a.position[0])) / area;
            tpp += (@abs(du_dx) + @abs(du_dy)) * sizes[k];
        }
        const width = @max(0.5 / 64.0 * 0.5 * tpp, 1e-5);
        const min_x: usize = @intFromFloat(std.math.clamp(@floor(@min(a.position[0], b.position[0], c.position[0])), 0, @as(f32, @floatFromInt(w))));
        const max_x: usize = @intFromFloat(std.math.clamp(@ceil(@max(a.position[0], b.position[0], c.position[0])), 0, @as(f32, @floatFromInt(w))));
        const min_y: usize = @intFromFloat(std.math.clamp(@floor(@min(a.position[1], b.position[1], c.position[1])), 0, @as(f32, @floatFromInt(h))));
        const max_y: usize = @intFromFloat(std.math.clamp(@ceil(@max(a.position[1], b.position[1], c.position[1])), 0, @as(f32, @floatFromInt(h))));
        for (min_y..max_y) |y| for (min_x..max_x) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const w0 = ((b.position[0] - px) * (c.position[1] - py) - (c.position[0] - px) * (b.position[1] - py)) / area;
            const w1 = ((c.position[0] - px) * (a.position[1] - py) - (a.position[0] - px) * (c.position[1] - py)) / area;
            const w2 = 1 - w0 - w1;
            if (w0 < -1e-4 or w1 < -1e-4 or w2 < -1e-4) continue;
            var color: [4]f32 = undefined;
            for (0..4) |k| color[k] = a.color[k] * w0 + b.color[k] * w1 + c.color[k] * w2;
            const u = a.uv[0] * w0 + b.uv[0] * w1 + c.uv[0] * w2;
            const v = a.uv[1] * w0 + b.uv[1] * w1 + c.uv[1] * w2;
            const mode = a.mode;
            if (mode < -0.5) continue;
            const sample = atlas(font, u, v);
            var coverage = sample;
            if (mode > 0.5) {
                const inner = if (mode > 1.0) edge(sample, 0.5 + 0.5 * (mode - 1.0), width) else 0;
                coverage = edge(sample, 0.5, width) - inner;
            }
            const alpha = std.math.clamp(color[3] * coverage, 0, 1);
            const dst = &image[y * w + x];
            for (0..3) |k| dst[k] = dst[k] * (1 - alpha) + color[k] * alpha;
        };
    }
    const bytes = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(bytes);
    for (image, 0..) |p, k| {
        for (0..3) |ch| bytes[k * 4 + ch] = @intFromFloat(std.math.clamp(p[ch], 0, 1) * 255);
        bytes[k * 4 + 3] = 255;
    }
    var threaded: std.Io.Threaded = .init_single_threaded;
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = bytes });
}

test "probe: render the Git panel" {
    const gpa = std.testing.allocator;
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    context.theme = .dark;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    const repo = try repo_zig.Repo.create(gpa, &environ, .{ .block = .{ .slice = &.{} } }, "/nowhere");
    defer repo.destroy();
    const state = try gpa.create(status.State);
    state.* = .{ .arena = .init(gpa) };
    repo.state = state;
    const a = state.arena.allocator();
    try status.parseStatus(a, state, "## main...origin/main [ahead 2, behind 1]\nM  src/main.zig\nA  resources/scene/level.scene.zon\n M build.zig\n M resources/scene/start.scene.zon\n?? notes.txt\n D old.zig\n");
    try status.parseRefs(a, state, "*\trefs/heads/main\torigin/main\tahead 2, behind 1\tabc1234\tAdd the second level\n \trefs/heads/lighting\torigin/lighting\t\tdef5678\tTry baked shadows\n \trefs/remotes/origin/main\t\t\t9a8b7c6\tFix the jump\n \trefs/remotes/origin/lighting\t\t\tdef5678\tTry baked shadows\n \trefs/tags/v0.1.0\t\t\t1122334\tFirst playable\n");
    try status.parseLog(a, state, "abc1234\tabc1234ff\tSam Rivera\t2 hours ago\tHEAD -> main\tAdd the second level\n9a8b7c6\t9a8b7c6ff\tSam Rivera\t1 day ago\torigin/main\tFix the jump\n5566778\t5566778ff\tAlex Chen\t3 days ago\t\tTune the camera\n1122334\t1122334ff\tAlex Chen\t1 week ago\ttag: v0.1.0\tFirst playable\n");
    try status.parseStashes(a, state, "stash@{0}\tOn main: halfway through the menu\nstash@{1}\tWIP on lighting: def5678 Try baked shadows\n");
    try status.parseRemotes(a, state, "origin\thttps://github.com/sam/space-game.git (fetch)\n");
    state.user_name = "Sam Rivera";
    state.user_email = "sam@example.com";
    repo.say("Push", "To https://github.com/sam/space-game.git\n   abc1234..def5678  main -> main", false);
    const diff = try gpa.create(repo_zig.Diff);
    diff.* = .{ .arena = .init(gpa), .key = "git-row-w:build.zig", .text = "", .lines = &.{} };
    repo.diff = diff;
    diff.text = "diff --git a/build.zig b/build.zig\nindex 3f2a..9c1d 100644\n--- a/build.zig\n+++ b/build.zig\n@@ -12,7 +12,8 @@ pub fn build(b: *std.Build) void {\n     const target = b.standardTargetOptions(.{});\n-    const optimize = .Debug;\n+    const optimize = b.standardOptimizeOption(.{});\n+    const scene = b.option([]const u8, \"scene\", \"Start here\");\n     eggy.addGame(b, .{";
    var lines: std.ArrayList(repo_zig.Diff.Line) = .empty;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, diff.text, start, '\n')) |end| : (start = end + 1) try lines.append(diff.arena.allocator(), .{ .start = start, .end = end });
    try lines.append(diff.arena.allocator(), .{ .start = start, .end = diff.text.len });
    diff.lines = lines.items;

    var panel = panel_zig.Panel{};
    const W = 460;
    const H = 640;
    const cases = [_]struct { name: []const u8, tab: panel_zig.Tab, key: []const u8, operation: status.Operation = .none }{
        .{ .name = "git_changes", .tab = .changes, .key = "git-row-w:build.zig" },
        .{ .name = "git_history", .tab = .history, .key = "git-row-c:abc1234ff" },
        .{ .name = "git_branches", .tab = .branches, .key = "git-row-x" },
        .{ .name = "git_stashes", .tab = .stashes, .key = "git-row-x" },
        .{ .name = "git_remotes", .tab = .remotes, .key = "git-row-x" },
    };
    for (cases) |case| {
        panel.open(case.tab);
        panel.selected_len = case.key.len;
        @memcpy(panel.selected_buffer[0..case.key.len], case.key);
        diff.key = case.key;
        // Two frames: the second has the first's layout for hover and ids.
        for (0..2) |_| {
            context.newFrame(.{ .x = 0, .y = 0, .w = W, .h = H });
            try panel.build(repo, &context);
            _ = try context.render();
        }
        context.newFrame(.{ .x = 0, .y = 0, .w = W, .h = H });
        try panel.build(repo, &context);
        const vertices = try context.render();
        const path = try std.fmt.allocPrint(gpa, "/tmp/claude-1000/-home-tirbofish-eggy/7ad4dd81-232d-47e0-9afe-a64230e81842/scratchpad/shots/{s}.raw", .{case.name});
        defer gpa.free(path);
        try rasterize(gpa, context.font, vertices, W, H, context.theme.background ++ [_]f32{1}, path);
    }
    diff.arena.deinit();
    gpa.destroy(diff);
    repo.diff = null;
}
