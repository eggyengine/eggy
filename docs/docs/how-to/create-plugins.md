---
slug: /guides/plugins
sidebar_position: 10
title: Create reusable plugins
---

# Create reusable plugins

Put components, systems, and settings in a plugin that your own game or another package
can use. The game and reusable plugins use the same hooks.

## Before you start

Use a Zig 0.16 game package that already calls `eggy.addGame`.
[Set up a project](set-up-project.md) if you need one. A reusable plugin belongs in
`src/root.zig` as `pub const Plugin`; game-only behavior can stay in `pub const Game`
in `src/main.zig`.

## Steps

### Declare serializable components {#components}

List component types in the plugin's `components` declaration. This makes them available
to scene files and the Inspector:

```zig
pub const Spin = struct {
    speed: f32 = 0.001,
    turns: f32 = 0,
};

pub const Plugin = struct {
    pub const components = .{Spin};

    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Plugin {
        _ = gpa;
        _ = try app.world.spawn(.{Spin{}});
        return .{};
    }
};
```

Import `std` and `eggy` in the file containing this type. Place hooks inside the plugin,
not beside it. Omit hooks you do not need; fields need defaults when there is no `init`.
The [hook reference](../reference/plugin-hooks.md#hooks) lists signatures and dispatch order.

If a component requires another component, declare the dependency:

```zig
pub const Wheel = struct {
    pub const dependencies = .{eggy.Transform};
    radius: f32 = 0.5,
};
```

Adding `Wheel` through the Inspector or scene loading also adds `Transform`. The
Inspector prevents removing a component that another component still needs.

Use typed references for editable links to entities or files:

```zig
pub const Orbit = struct {
    around: eggy.EntityRef(Body) = .{}, // an entity that has a Body
    sound: eggy.AssetRef(.audio) = .{}, // an audio file
};
```

Here `Body` is your component type. Resolve entity references before use, as shown in
[Render entities and cameras](render-scene.md#find-entities-safely). Asset references
validate a path; they do not load or play a file.

### Register systems in initialization {#the-app}

Register ECS systems through `app.world` in `init`. Eggy runs Init stages after all
enabled plugins start, then Update stages after each frame's plugin updates.

This independent counter example uses a different `Spin` definition from the
serializable component above. Put `spin` at file scope and `init` inside `Plugin`:

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

Keep owned allocations in plugin fields and release them in `deinit`. Do not store
pointers to the App, `self`, or component storage across reloads.

### Read editable settings {#preferences}

Declare `Preferences` inside the plugin with defaults for every field:

```zig
pub const Plugin = struct {
    pub const Preferences = struct {
        volume: f32 = 0.8,
        show_gizmos: bool = true,
        difficulty: enum { easy, normal, hard } = .normal,

        // Optional: a line under each field in the Preferences window.
        pub const descriptions = .{ .volume = "How loud the game is, 0 to 1." };
    };

    pub fn update(self: *Plugin, app: *eggy.App) !void {
        const prefs = app.preferences(Preferences);
        if (prefs.show_gizmos) { ... }
    }
};
```

Replace `{ ... }` with your implementation and mark unused hook parameters with `_`.
Fields may be bools, integers, floats, or enums. Edit > Preferences shows the controls.
Read settings where you use them to follow changes; values cached in `init` are refreshed
only when the instance restarts.

Project preference files are embedded in runtime builds. Their names and layering are
listed in the [configuration reference](../reference/project-configuration.md#preferences).

### Publish and enable the plugin {#using-plugins}

In your package's `build.zig`, publish `src/root.zig` with `addPlugin` and pass the
returned module to `addGame`:

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

Both helpers request the same Eggy dependency arguments. Do not add divergent engine
options: the game and plugin must share native engine and ECS types.

To use another package's published plugin, fetch it and add its module to `.plugins`.
Replace the example URL and module name with the package you want:

```bash
zig fetch --save git+https://github.com/someone/stats
```

```zig
.plugins = &.{ plugin, b.dependency("stats", .{}).module("stats") },
```

Plugins run after the game in list order. A disabled plugin does not run; its component
and preference declarations remain available.

## Verify

Build and open the project's editor with `zig build run`. Check that the plugin appears
in Preferences > Plugins and that its declared components and settings appear in the
Inspector and Preferences. Press Play to run gameplay initialization and systems;
entities spawned by `init` are gameplay entities, not saved scene content.

Change plugin code and refocus the editor. It should rebuild the game library and start
new plugin state. See [Ownership, Play, and reload](../explanation/ownership-and-reload.md)
before retaining IDs or allocating resources in a plugin.

## Related reference

- [Plugin hooks, Inspector field types, panel keys, and templates](../reference/plugin-hooks.md)
- [Project preference files](../reference/project-configuration.md#preferences)
- [Extend the editor](extend-editor.md) for panels, commands, and undoable edits
