---
sidebar_position: 1
title: Plugins
---

# Plugins

A plugin is a Zig type that Eggy calls at set points in your game's life: when it starts, every frame, on input, and when it stops. Your game is a plugin too, the first one. Other plugins come from your own package or from other packages.

Plugins are compiled into your game. Eggy finds each hook with `@hasDecl`, so a plugin declares only the hooks it needs. In the editor they also live in a library of their own, which the editor swaps for a rebuilt one when you change their code: see [Changing code in the editor](#changing-code-in-the-editor).

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
| `update` | Once per frame, before the frame is drawn. In the editor, only while playing. |
| `editorUpdate` | Once per frame in the editor while not playing, for editor tools. |
| `editorUi` | Each frame in the editor, to add to the Inspector panel. |
| `editor_panels`, `editorPanelUi` | In the editor, to add dock panels of your own. See [Editor panels](#editor-panels). |
| `Preferences` | Settings people change in the editor's Preferences window. See [Preferences](#preferences). |
| `components` | ECS components the editor's Hierarchy and Inspector show, add and edit. See [Components](#components). |

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

## Components

A plugin lists the ECS components it brings in `components`. The editor's **Hierarchy** panel then shows every entity with the components it has, and selecting one shows its components in the **Inspector**, where each field can be edited and components added or removed:

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

A component is a struct, and the Inspector gives every field of plain data a control by its type:

- Numbers are boxes: drag one sideways to change it, or click it to type a value (Enter or Escape finishes).
- Vectors (two to four numbers in an array, a `@Vector`, a struct of `x`, `y`, `z` and `w`, or `eggy.math.Vec2`, `Vec3` and `Vec4`) get a box per axis, tagged X, Y, Z and W in red, green, blue and purple.
- Colours (`eggy.Color`, any struct of `r`, `g`, `b` and maybe `a`, or three or four numbers in a field named `color`, `colour` or ending `_color`) get a swatch and a box per channel, filled as far as the channel goes. Click the swatch for a colour picker (a wheel, sliders, hex codes and presets) that floats over the Inspector; click elsewhere to keep the colour, or Cancel to put it back.
- Rotations (`eggy.math.Quat`, or three floats in a field with `rotation`, `orientation` or `euler` in its name, in degrees, or radians when the name ends `_rad`) get a dropdown to show them as Euler angles in degrees or radians, a quaternion, or an axis and angle. The field keeps its own type whichever you pick.
- Bools get a switch, enums a dropdown, and tagged unions a dropdown of their variants with the chosen variant's fields under it.
- Nested structs, arrays and optionals get a row for each part, further in; an optional has a switch to set it or clear it.

Fields holding pointers (or strings) are shown but not edited. **Add component** offers the components whose fields all have defaults, which is what an added one starts with.

The values shown are read from the world every frame, so fields your systems change update as they run.

### Drawing shapes

Every project also has Eggy's own components, listed as from `eggy`. Give an entity a `Transform` (position, rotation in degrees, scale) and a `Mesh`, and it is drawn in the scene as the `Mesh`'s shape (cube, sphere, plane, cylinder or cone) in its colour. A `Mesh`'s shape can also be a model file (`.glb`, `.gltf`, `.obj`, `.fbx`, `.dae`, `.3ds`, `.ply` or `.stl`): drag one from Assets onto the shape's dropdown. In code, `eggy.Mesh{ .shape = .of(.sphere) }` picks a built-in shape from an `eggy.mesh.Shape`. An entity inside another is placed relative to its parent's `Transform`.

### Models and descriptors

Every file in `resources/` has a descriptor beside it, `<file>.eggy`, which the editor makes and keeps with the file when you rename, move or delete it in the **Assets** panel (which doesn't list them). It holds the file's id and kind, and for a model how to import it:

```zig
.{ .id = 8470855589818597979, .kind = .model, .model = .{ .scale = 0.01 } }
```

The editor imports model files as they are, with [assimp](https://github.com/assimp/assimp), and imports them again when you come back to it from another app, so a model re-exported from your modelling tool shows its changes. Building the game (`zig build runtime`) packages each model once, as an `.eggmodel` in `zig-out/data/`, which the game loads without assimp. A project without models never builds assimp at all.

Give an entity a `Camera` (field of view, near and far) and a `Transform`, and the game is seen through it: it looks down its -z, with its +y up. Without one, the game looks at the middle of the world from above. The editor's Scene panel has a camera of its own: right-drag to look around and, while held, W, A, S, D, Q and E to fly (Shift to go faster); Alt+left-drag to orbit; middle-drag to pan; the wheel to zoom; and F to frame the entity selected in the Hierarchy. To move something, change its `Transform` from a system:

```zig
fn rise(bodies: eggy.ecs.Query(.{*eggy.Transform})) !void {
    var iter = bodies;
    while (iter.next()) |view| view.get(*eggy.Transform).position[1] += 0.01;
}
```

The Hierarchy's **Add** spawns an empty entity, and **Delete** despawns the selected entity and its children. Drag an entity onto another to put it inside, or onto the top or bottom edge of one to put it before or after; entities keep the order you give them, and scenes save it.

### References

A field can point at another entity or at a file of the project:

```zig
pub const Orbit = struct {
    around: eggy.EntityRef(Body) = .{}, // an entity that has a Body
    sound: eggy.AssetRef(.audio) = .{}, // an audio file
};
```

In the Inspector these fields are slots: drag an entity from the Hierarchy (or a file from Assets) onto one to set it, and the x clears it. While you drag, the slots that would take what you hold light up; an `EntityRef(T)` takes only entities with component `T` (`EntityRef(void)` takes any), and an `AssetRef` only files of its kind (`.any`, `.scene`, `.image`, `.audio`, `.text`, `.code` or `.model`). References work anywhere in a field, a union's variant included: a union with a reference variant also takes a drop on its dropdown, which picks that variant. In code, `orbit.around.entity` is the entity (or null), and `orbit.sound.path()` the file's path in the project. A scene saves a reference to one of its own entities by its place, so it points at the right entity when loaded again.

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

## Preferences

A plugin declares its preferences as a struct of defaults named `Preferences`: its manifest. The editor's **Edit > Preferences** window gives the plugin a tab of its own, with a control for each field, and your code reads the values with `app.preferences`:

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

Fields are bools, integers, floats or enums, and each needs a default. Reading them is cheap, so reading them in `update` follows changes as they are made in the window. Values read in `init` apply the next time the game starts.

A plugin's preferences belong to the project: a value set in the window is kept in the project's `.eggy` folder and overrides the default in `Preferences`. The values are also baked into the game when its runtime is built, so the game you ship uses them. (The editor's own preferences, such as its theme, can also be set for **All projects**, which a project can override.)

A project's `.eggy` folder holds:

| File | What it is |
| --- | --- |
| `preferences.zon` | The editor's own preferences for this project, overriding those set for all projects. |
| `plugins/<plugin>.zon` | Each plugin's preferences, by the plugin's module name (`game.zon` for the game's). |
| `plugins.zon` | Written by the editor: the plugins the project has, whether each is on (Preferences > Plugins), and the preferences each declares. The game is built without the plugins that are off. |

The files are plain ZON, such as `.{ .volume = 0.5 }`, so they can be edited by hand and committed with the project. A value that doesn't fit its field's type is ignored, and the default applies.

## Changing code in the editor

The editor runs your game and its plugins from a library built beside it. When you change their code and come back to the editor, it rebuilds them in the Build progress window and swaps the new library in, while the editor itself keeps running: your layout, panels and Console stay as they were.

The world's entities carry over a swap: the editor keeps them as a scene and puts them back. Everything else starts over. Every plugin's `deinit` runs, and then every plugin's `init` runs again with the new code, among the entities, so:

- state kept in plugin fields starts fresh, so find the entities you need in `init` rather than keeping them from before;
- systems are registered again by the new `init`;
- panels follow `editor_panels`: new ones open beside the Inspector, removed ones close.

When a hook or one of the world's systems returns an error in the editor, the error goes to the Console once, and the game carries on; only a failing `init` stops it until its code is rebuilt. In the runtime, an error still ends the game.

Entities can be deleted in the editor at any time, so check `app.world.isAlive(entity)` before using one you kept.

### Playing

In the editor the game doesn't run on its own: its `update` hooks, the world's systems and input events only run while it plays (the play button on the title bar). While it doesn't, plugins' `editorUpdate` hooks run instead, for tools that work on the scene. Pressing play keeps the scene as it is; stopping starts the game over on it, so whatever happened while playing, the scene's values go back. To keep where something ended up, select it and press **Ctrl+Shift+K** while playing: after Stop it keeps that `Transform` (and Edit > Undo takes it back).

### Scenes

A scene is a file (`.scene.zon`, in `resources/scene/` by default; every project has a `resources` folder for the files its game uses) holding every entity: its name, parent, and each component's values. The editor reopens the scene that was open last; open another by double-clicking it in the **Assets** panel, which also starts new ones. **File > Save** writes the open scene. The editor puts the scene into the world before plugins start, so `init` can find its entities.

Changes to Eggy itself (say, with a project linked to an Eggy checkout) rebuild the whole editor instead. Its **Reload** button, beside the play button, opens the new one.

Use the `event` hook for input rather than calling SDL yourself: the library has no SDL of its own to ask.

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
