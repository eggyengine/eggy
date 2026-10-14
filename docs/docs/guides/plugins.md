---
sidebar_position: 1
title: Plugins
---

# Plugins

A plugin is a Zig type that Eggy calls at set points in your game's life: when it starts, every frame, on input, and when it stops. Your game is a plugin too, the first one. Other plugins come from your own package or from other packages.

Plugins are compiled into your game. Eggy finds each hook with `@hasDecl`, so a plugin declares only the hooks it needs.

## Hooks

```zig
const std = @import("std");
const eggy = @import("eggy");

pub const Plugin = struct {
    frames: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Plugin { ... }
    pub fn deinit(self: *Plugin) void { ... }
    pub fn event(self: *Plugin, app: *eggy.App, event: eggy.Event) !void { ... }
    pub fn update(self: *Plugin, app: *eggy.App) !void { ... }
    pub fn editorUi(self: *Plugin, ui: *eggy.ui.Context) void { ... }

    pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .title = "Stats" }};
    pub fn editorPanelUi(self: *Plugin, panel: usize, ui: *eggy.ui.Context) void { ... }
};
```

| Hook | When it runs |
| --- | --- |
| `init` | Once, at start-up. Without it, the plugin starts as `.{}`. |
| `deinit` | Once, at shutdown. |
| `event` | For every SDL event: input, window changes and so on. |
| `update` | Once per frame, before the frame is drawn. |
| `editorUi` | Each frame in the editor, to add to the Inspector panel. |
| `editor_panels`, `editorPanelUi` | In the editor, to add dock panels of your own. See [Editor panels](#editor-panels). |

The editor-only hooks never run in the runtime, so the runtime pays nothing for them.

### Order

Hooks run in the order the plugins are listed, with the game first. Each frame, the game's `update` runs before its plugins' `update`. `deinit` runs in reverse, so a plugin stops before the plugins it may depend on.

If an `init` fails, the plugins already started are stopped again, and the error ends start-up.

### State

A plugin keeps its state in its own fields. Eggy stores plugins by value and may move them after `init`, so:

- don't keep pointers to `self` (in callbacks, say);
- use the `app` each hook is given rather than storing it.

## The app

`eggy.App` is what the hooks work with:

| Field | What it is |
| --- | --- |
| `window` | The SDL window. |
| `graphics` | The GPU device and the main window's swapchain. |
| `world` | The game's ECS world (`eggy.ecs`). |

Register systems on the world in `init`. Eggy runs the world's stages from then on: its Init stages once every plugin has started, and its Update stages every frame after the plugins' `update`.

```zig
const ecs = eggy.ecs;

const Spin = struct { turns: u64 = 0 };

fn spin(spinners: ecs.Query(.{*Spin})) !void {
    var iter = spinners;
    while (iter.next()) |view| view.get(*Spin).turns += 1;
}

pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Plugin {
    _ = gpa;
    app.world.addSchedule(ecs.Schedule(.Update, .{spin}));
    _ = try app.world.spawn(.{Spin{}});
    return .{};
}
```

## Editor panels

A plugin can add panels to the editor's dock. Each panel gets a tab that can be dragged to dock anywhere, floated, or popped out into its own window, like the editor's own panels.

Declare the panels with `editor_panels`, then fill them in `editorPanelUi`. `panel` is the index of the panel in `editor_panels`:

```zig
pub const Plugin = struct {
    clicks: u32 = 0,

    pub const editor_panels = [_]eggy.plugins.EditorPanel{
        .{ .title = "Clicker" },
        .{ .title = "About" },
    };

    pub fn editorPanelUi(self: *Plugin, panel: usize, ui: *eggy.ui.Context) void {
        switch (panel) {
            0 => {
                if (ui.button("Click me")) self.clicks += 1;
                ui.label("Clicked {d} times", .{self.clicks});
            },
            else => ui.muted("Made with Eggy."),
        }
    }
};
```

Each panel is a page of [Weeoui](https://eggyengine.github.io/weeoui/) UI that you describe every frame. It has its own scroll position, focus and hover state, so panels don't interfere with each other.

New panels open as tabs beside the Inspector. The editor's **Window** menu lists every panel, yours included, so a closed panel can be brought back.

The title appears on the panel's tab, in the Window menu, and on its window when popped out.

## Using plugins

### In your own package

A package's plugin lives in `src/root.zig` and is published with `addPlugin`. Pass its module to `addGame` to run it in your game:

```zig title="build.zig"
const std = @import("std");
const eggy = @import("eggy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = eggy.addPlugin(b, .{
        .name = "my_game",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    eggy.addGame(b, .{
        .name = "my_game",
        .game = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .plugins = &.{plugin},
        .target = target,
        .optimize = optimize,
    });
}
```

### From another package

Fetch the package, then list its module in `plugins`:

```bash
zig fetch --save git+https://github.com/someone/stats
```

```zig
.plugins = &.{ plugin, b.dependency("stats", .{}).module("stats") },
```

Each plugin gets your game's own Eggy, so they all share one engine, whichever Eggy they were written against.
