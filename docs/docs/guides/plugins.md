---
sidebar_position: 2
title: Plugins
---

# Plugins

A plugin is a Zig type that Eggy calls at set points in your game's life: when it starts, every frame, on input, and when it stops. Your game is a plugin too, the first one. Other plugins come from your own package or from other packages.

Plugins are compiled into your game. Eggy finds each hook with `@hasDecl`, so a plugin declares only the hooks it needs. In the editor they also live in a library of their own, which the editor swaps for a rebuilt one when you change their code: see [Changing code in the editor](#changing-code-in-the-editor).

## Hooks

`Game` and `Plugin` support the same optional functions below. These are hooks, not
Zig overloads or inherited methods: Eggy calls a public function when your type declares
its name. Leave out any hook you do not need.

Declare hooks **inside** `pub const Game` in `src/main.zig`, or `pub const Plugin` in
`src/root.zig`, not as functions beside the type. `Self` below means the enclosing type,
so the signatures work unchanged if you rename `Plugin` to `Game`.

This is a signature reference; replace `{ ... }` with your implementation:

```zig
const std = @import("std");
const eggy = @import("eggy");

pub const Plugin = struct {
    const Self = @This();

    frames: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Self { ... }
    pub fn deinit(self: *Self) void { ... }
    pub fn event(self: *Self, app: *eggy.App, event: eggy.Event) !void { ... }
    pub fn update(self: *Self, app: *eggy.App) !void { ... }
    pub fn gameUi(self: *Self, app: *eggy.App, ui: *eggy.ui.Context) !void { ... }
    pub fn draw(self: *Self, app: *eggy.App, target: eggy.DrawContext) !void { ... }
    pub fn uiEvent(self: *Self, app: *eggy.App, event: eggy.Event) !bool { ... }
    pub fn editorUpdate(self: *Self, editor: *eggy.editor.Context) !void { ... }
    pub fn editorUi(self: *Self, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void { ... }

    pub const editor_panels = [_]eggy.plugins.EditorPanel{.{ .key = "stats", .title = "Stats" }};
    pub fn editorPanelUi(self: *Self, panel: usize, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void { ... }
    pub const editor_commands = [_]eggy.plugins.EditorCommand{.{ .key = "reset", .title = "Reset" }};
    pub fn editorCommand(self: *Self, command: usize, editor: *eggy.editor.Context) !void { ... }
};
```

| Hook | When it runs |
| --- | --- |
| `init` | Each time the instance starts, after scene loading, preference registration and input-map registration. Return the instance; without this hook it starts as `.{}`, so its fields need defaults. Register ECS systems and acquire owned resources here. |
| `deinit` | Before a started instance is discarded, including shutdown and editor restarts/reloads. Release what that instance owns; Eggy owns the App and world. |
| `event` | Gameplay input not consumed by UI, plus platform/window events. In the editor, gameplay events run only while playing and not paused. Use [typed input maps](input-mappings.md) in `update` for per-frame actions. |
| `update` | Each running frame, before ECS Update systems and rendering. In the editor, only while playing and not paused. Use `app.time.delta_s` for frame-independent movement. |
| `gameUi` | Build Weeoui game content after scene/custom drawing; also in editor Play, including pause. |
| `draw` | After the scene and before `gameUi`, including editor Play while paused. Record custom rendering into the supplied engine-owned target, outside a render pass; Eggy submits the frame. |
| `uiEvent` | Input not already consumed by the built-in game UI, before gameplay. Return `true` to consume it, or `false` to let it through. In editor Play this also runs while paused, so UI stays interactive. |
| `editorUpdate` | Each editor frame when gameplay is not running: while editing or paused. Use it for editor tools, not gameplay simulation. |
| `editorUi` | Build the project's Inspector content when the Inspector is not showing a selected entity. For a separate dock tab, use `editorPanelUi` instead. |
| `editorPanelUi` | Build the declared editor panel. `panel` is its zero-based index in this type's `editor_panels`, not a global panel ID. See [Editor panels](#editor-panels). |
| `editorCommand` | When someone invokes a declared View-menu command. `command` is its zero-based index in this type's `editor_commands`. See [Editor tools](editor-tools.md#add-commands). |

`init` is a constructor, so it has no `self` parameter. Other hooks receive a mutable
pointer to the current instance. Keep the parameter order and return types shown above:
`deinit` returns `void`, `uiEvent` returns `!bool`, and the other instance hooks return
`!void`, even if your implementation currently cannot fail. Use `_` for unused parameters.

The editor-only hooks never run in the runtime, so the runtime pays nothing for them.
They receive a borrowed `eggy.editor.Context`: use `editor.app` for the App and its services
for selection, undoable edits, project settings, scenes, and files. Do not retain the context.
The `ui` and draw contexts are borrowed too; use them only during their hook.
Editor updates and game rendering are suspended while the Build window is up.
See [Game UI](game-ui.md) for styling, fonts, custom renderers, and input capture.

### Optional declarations

These describe what the game or plugin provides; they are not functions to override.

| Declaration | What it adds |
| --- | --- |
| `pub const components = .{ Health, Spin };` | ECS component types for scene serialization and the Inspector. See [Components](#components). |
| `pub const input_maps = .{PlayerInput};` | Typed input maps registered before `init` for enabled plugins. See [Input mappings](input-mappings.md). |
| `pub const Preferences = struct { volume: f32 = 0.8 };` | Settings read with `app.preferences(Preferences)`. See [Preferences](#preferences). |
| `pub const editor_panels = [_]eggy.plugins.EditorPanel{...};` | Dock-panel metadata, paired with `editorPanelUi`. |
| `pub const editor_commands = [_]eggy.plugins.EditorCommand{...};` | View-menu command metadata, paired with `editorCommand`. |
| `pub const editor_file_types = [_]eggy.plugins.EditorFileType{...};` | Templates added to both Assets New menus. See [File templates](#file-templates). |

Disabling a plugin skips its instance and hooks, but its component types and preferences
remain known so scenes and settings retain their values. The game itself is always enabled.

### Order

Hooks normally run in the order the plugins are listed, with the game first. Each frame,
the game's `update` runs before its plugins' `update`. `deinit` runs in reverse, so a
plugin stops before the plugins it may depend on. `uiEvent` also runs in reverse visual
order, and stops as soon as a hook returns `true`.

If an `init` fails, the plugins already started are stopped again, and the error ends start-up.
Standalone uncaught hook errors are fatal; the editor logs game-library hook failures and
keeps running. An error stops that hook's current dispatch, so later plugins in that dispatch
are skipped. See [Error handling](error-handling.md) for recovery and ownership patterns.

### State

A plugin keeps its state in its own fields. Eggy stores plugins by value and may move them after `init`, so:

- don't keep pointers to `self` (in callbacks, say);
- use the `app` each hook is given rather than storing it.

## File templates

Declare `editor_file_types` inside `Game` or `Plugin` to add entries to both Assets
**New** menus:

```zig
pub const editor_file_types = [_]eggy.plugins.EditorFileType{.{
    .key = "material",
    .title = "Material",
    .extension = ".material.zon",
    .contents = ".{ .roughness = 0.5 }\n",
}};
```

The editor creates `Material.material.zon` in the chosen folder, adding a number if
that name already exists. `contents` is the initial file data; omit it for an empty
file. The title and extension must not contain path separators. Keys are scoped to
the published plugin, just like editor commands. Templates remain available when a
plugin is disabled, and creating a file participates in Undo/Redo.

This is a static template declaration, not a hook. Code/text files open in the
configured code editor; `.inmap.zon` files open in Eggy's Input Map editor.

## The app

`eggy.App` is what the hooks work with:

| Field | What it is |
| --- | --- |
| `window` | The SDL window. |
| `graphics` | The GPU device and the main window's swapchain. |
| `world` | The game's ECS world (`eggy.ecs`). |
| `process_init` | Zig's `std.process.Init`, as `main` would get it: `minimal.args`, `environ_map`, `arena`, `gpa` and `io`. |

Read the command line or environment through `app.process_init`, for example
`app.process_init.environ_map.get("MY_GAME_LEVEL")`. It stays valid for the whole run.

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

A component can depend on others. List them in its `dependencies`, and adding it (in the Inspector, or as a scene loads) adds them too; the Inspector won't remove a component while another on the entity needs it. Eggy's `Mesh`, `Camera` and `SceneInstance` depend on `Transform`:

```zig
pub const Wheel = struct {
    pub const dependencies = .{eggy.Transform};
    radius: f32 = 0.5,
};
```

### Drawing shapes

Every project also has Eggy's own components, listed as from `eggy`. Give an entity a `Transform` (position, rotation in degrees, scale) and a `Mesh`, and it is drawn in the scene as the `Mesh`'s shape (cube, sphere, plane, cylinder or cone) in its colour. A `Mesh`'s shape can also be a model file (`.glb`, `.gltf`, `.obj`, `.fbx`, `.dae`, `.3ds`, `.ply` or `.stl`): drag one from Assets onto the shape's dropdown. In code, `eggy.Mesh{ .shape = .of(.sphere) }` picks a built-in shape from an `eggy.mesh.Shape`. A `Mesh`'s `texture` paints an image over it (`.png`, `.jpg`, `.gif` or `.bmp`), tinted by its colour: drag an image from Assets onto the field, or onto the entity in the Scene panel or the Hierarchy. A model brings its own textures, from its materials (image files beside it, or inside a `.glb`); a `Mesh`'s texture, when set, paints over them. The built-in shapes take the whole image on each side. An entity inside another is placed relative to its parent's `Transform`.

Drag a model file from Assets into the Scene panel and it becomes a new entity, standing on the ground where you let go; drag it onto a row of the Hierarchy and it goes inside that entity. A scene file works the same way, the way instanced scenes do in Godot: the new entity gets a `SceneInstance` whose `scene` is that file, and the scene's entities are made inside it. Make a rat with its hat in `rat.scene.zon`, and the sewer scene can have as many rats as you drag in. Only the instance is saved with the sewer, so a change to `rat.scene.zon` shows in every rat. Clicking one in the Scene panel selects the whole instance, and the Hierarchy doesn't list what is inside it: change the rat by opening its own scene. The `scene` field takes a scene file dropped on it in the Inspector, like any `AssetRef(.scene)`.

Files from outside the editor (from the system's file manager) are copied into the project when dropped on the Assets panel, into the folder they land on.

Play runs the scene open in the editor. A built game starts in the project's default scene, set in File > Project Settings (`.default_scene` in `eggy.zon`), or the one `-Dscene=<path>` names; `zig build runtime` without either takes the scene the editor last had open. Exporting needs one or the other: File > Export first asks which scene the game starts in, keeps your answer as the default scene, then builds. Building the game puts every file of `resources/` beside it in `data/`, named by its id rather than its name: models and images converted so the game reads them without an importer, everything else as it is, and `data/manifest.zon` to find each. The scene is in place before your plugins' `init` runs. Project Settings also sets what the game's executable says about itself: its company, description, copyright and any entries of your own, with the project's title and version. On Windows they show in the executable's Properties; on Linux and macOS they are kept in a section of the executable (`readelf -p .eggy_metadata <game>` shows them).

### Models and descriptors

Every file in `resources/` has a descriptor beside it, `<file>.eggy`, which the editor makes and keeps with the file when you rename, move or delete it in the **Assets** panel (which doesn't list them). It holds the file's id and kind, and for a model how to import it:

```zig
.{ .id = 8470855589818597979, .kind = .model, .model = .{ .scale = 0.01 } }
```

The editor imports model files as they are, with [assimp](https://github.com/assimp/assimp), and imports them again when you come back to it from another app, so a model re-exported from your modelling tool shows its changes. Building the game (`zig build runtime`) packages each model once, as an `.eggmodel` in `zig-out/data/`, which the game loads without assimp. A project without models never builds assimp at all.

Give an entity a `Camera` (field of view, near and far) and a `Transform`, and the game is seen through it: it looks down its -z, with its +y up. Without one, the game looks at the middle of the world from above. The editor's Scene panel has a camera of its own: right-drag to look around and, while held, W, A, S, D, Q and E to fly (Shift to go faster); Alt+left-drag to orbit; middle-drag to pan; the wheel to zoom; and F to frame the entity selected in the Hierarchy. Its toolbar also offers [Touchpad navigation](editor-tools.md#scene-navigation). To move something, change its `Transform` from a system:

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
        .{ .key = "clicker", .title = "Clicker" },
        .{ .key = "about", .title = "About" },
    };

    pub fn editorPanelUi(self: *Plugin, panel: usize, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void {
        _ = editor;
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
The `key` identifies the panel independently of that title or its declaration order. Give it
a stable key to preserve its layout when renaming it. A panel without a key uses its title.
Keys are scoped to the plugin's published name; duplicate keys are compile errors and a
rare dock-ID hash collision is reported instead of routing one panel to another.

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

In the editor the game doesn't run on its own: its `update` hooks, the world's systems and input events only run while it plays (the play button on the title bar). While it doesn't, plugins' `editorUpdate` hooks run instead, for tools that work on the scene. Pressing play keeps the scene as it is and starts the game on it as it starts when shipped: the scene first, then your plugins' `init`, keeping what it spawns. Stopping puts the scene back exactly as it was, so whatever happened while playing (entities spawned included) goes. While editing, the world is the scene alone: entities your plugins' `init` spawns show only while playing, so they never end up saved into the scene. To keep where something ended up, select it and press **Ctrl+Shift+K** while playing: after Stop it keeps that `Transform` (and Edit > Undo takes it back).

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
