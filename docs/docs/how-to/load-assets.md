---
sidebar_position: 7
title: Load assets and instantiate scenes
slug: /guides/assets-and-scenes
---

Load project resources through `app.resources()` and create scene instances through
`app.scenes()`. These services let game code use project paths in both the editor and
a packaged runtime.

## Prepare project resources

Put the files in the project's `resources/` folder. The editor gives each an ID in
`.eggy/assets.zon`; keep that file in version control with the assets and use the
editor's file operations when moving or renaming them, so the IDs follow. See
[assets, scenes, and packaging](../explanation/assets-and-scenes.md) for how IDs and
packaged files relate to project paths.

Synchronous loading is useful during setup. Use owned asynchronous requests for loads
that would otherwise stall gameplay. Browser exports read their preloaded packaged data;
scene streaming is not implemented.

## Create files in Assets

Use New in the Assets toolbar, or New > in the right-click menu. Both offer Scene and
Folder, and the rest by category, each opening beside it: Rendering (Material, Surface
Shader, Post Shader), 2D (Tilemap), Animation (Animation Clip), UI (UI Scene) and Input
(Input Map), along with file types declared by the game's plugins. Write code and other text files in your code editor. New
files get unique names and can be undone.
Right-click a folder to create inside it; right-click a file to create beside it.

Double-click `.inmap.zon` assets to open the [Input Map editor](../how-to/map-input.md).
Images, models, audio, and fonts are imported from existing files, not created as
empty placeholders. Plugins can [add their own templates](../reference/plugin-hooks.md#file-templates).
Drop files from the system's file manager onto Assets to copy them into the target folder.

## Place models and scenes

Drag a model from Assets into the Scene to create an entity where it lands, or onto a
Hierarchy row to parent it there. Drop a model onto a Mesh shape field to replace its
shape. Drop an image onto a Mesh texture field, a Scene entity, or its Hierarchy row to
assign a texture.

A scene file dropped into Scene/Hierarchy creates a `SceneInstance` root. Only that root
is saved in the containing scene; generated descendants belong to the source scene.
Clicking an instance selects its root. The Hierarchy lists its generated descendants
under it, tinted, so you can [tune that one instance](edit-entity-trees.md#tune-one-scene-instance);
open the source scene to change what it is made of. The SceneInstance's scene field also
accepts a scene-file drop.

Hierarchy Add creates an empty entity; Delete removes it and its descendants.
Drag onto a row to reparent, or onto its top/bottom edge to reorder siblings. Scenes
preserve that order.

## Reference project files

```zig
const picture = eggy.AssetRef(.image).init("resources/art/portrait.png");
const model = eggy.AssetRef(.model).init("resources/models/ship.glb");
```

`init` validates a literal at compile time. Use `try AssetRef(kind).parse(path)` for
runtime text. Paths are project-relative, use `/`, and fit in 256 bytes. Absolute paths,
traversal, empty segments, backslashes, and a file of the wrong kind are rejected.
An empty path means an unset reference.

A reference stores its path by value and loads nothing. Inspector slots accept matching
dragged files. An audio reference plays through an `AudioSource` or
[`app.audio()`](../guides/play-sound.md).

## Read bytes, images, or models

```zig
const notes = eggy.AssetRef(.text).init("resources/notes.txt");
const text = try app.resources().read(gpa, notes);
defer gpa.free(text);

var image = try app.resources().loadImage(gpa, picture);
defer image.deinit(gpa);

var geometry = try app.resources().loadModel(gpa, model);
defer geometry.deinit(gpa);
```

Free the sentinel-terminated bytes with the allocator passed to `read`. Release images
and models with `deinit`, as above. Image pixels are RGBA bytes, top row first; models
contain geometry, parts, textures, and the rig (bones and blend shapes) of an animated
model. These are CPU data. To display a model,
use a [Mesh component](../how-to/render-scene.md#meshes-and-textures).

`read` is for resources copied unchanged, such as text, scenes, and fonts.
It rejects converted models/images with `ConvertedResource`; use the typed loader instead.
Image loading supports formats decoded by the existing image importer, including PNG,
JPEG, GIF, and BMP. SVG and WebP classification does not imply texture decoding:
`loadImage` rejects them with `UnsupportedImageFormat`.

Missing/corrupt/unsupported resources return errors, not empty successful data.
Common errors include `UnsetAsset`, `FileNotFound`, `NotPackaged`, `InvalidAssetData`,
`OutOfMemory`, and `AssetLoadFailed`. Provider diagnostics explain other failures.

## Load without blocking gameplay

Store the returned request in your plugin and poll it on later updates:

```zig
const request = try app.resources().loadModelAsync(gpa, model);
// On later updates, while this request is pending:
if (try app.resources().poll(request)) |loaded| {
    var result = loaded;
    defer result.deinit();
    // result.value.model is owned CPU data; upload GPU resources on the render thread.
}
```

`readAsync` reads copied files; `loadImageAsync` decodes pixels. `progress` reports
queued, loading, cancelling, or complete. Poll consumes completed requests, including
errors, exactly once; using a consumed handle returns `InvalidResourceRequest`.
Results remain independently owned after the request or world is gone.

Keep the supplied allocator alive until completion or world reset. Request bookkeeping
and result allocation happen on the caller thread; native imports use private worker
arenas. At most eight outstanding requests are allowed, including completed results not
yet polled. Additional requests return `TooManyResourceRequests`.

`cancel(request)` is cooperative and does not wait: an in-progress import finishes,
discards its output, then polling returns `ResourceCancelled`. Reset/reload/shutdown joins
workers before unloading code or closing providers. Browser builds do not create threads;
polling decodes already-preloaded data on the main thread, not a background network fetch.

## Instantiate a scene

```zig
const rat_scene = eggy.AssetRef(.scene).init("resources/scene/rat.scene.zon");
const root = try app.scenes().instantiate(rat_scene, .{ .parent = parent });
```

Choose an existing parent entity for `.parent`, or pass `.{}` for an unparented instance.
The returned root is owned by the world and has a `Transform` and `SceneInstance`.
Its immediate scene entities exist before the call returns. Nested instances synchronize
at the normal scene-sync point. A failed read/parse/allocation removes the entities created
by that call.

Service views and component pointers do not survive a world reset or reload. Use fresh
App access and typed `EntityRef` resolution instead of retaining borrowed storage.

## Stream a scene behind a loading screen

`stream` loads a scene over the frames that follow instead of all at once. It reads the
scene file in the background, puts the models and images the scene uses on the GPU one per
frame, and then places the scene. Pass `.replace = true` to swap out the whole world, as a
level change does, or leave it out to add the scene beside the world, under `.parent` if
you give one.

```zig
const level = eggy.AssetRef(.scene).init("resources/scene/level.scene.zon");
self.loading = try app.scenes().stream(level, .{ .replace = true });

// In a later update:
if (self.loading) |ticket| if (try app.scenes().streamed(ticket)) |placed| {
    self.loading = null;
    _ = placed.root; // null after a replace, the instance's root otherwise
};
```

Until the scene is placed, Eggy covers the game with a loading screen. It shows the scene's
name, a progress bar, and which model or image is loading. To draw your own screen, pass
`.loading_screen = false` and read `app.scenes().loading()` in `gameUi`. It gives the scene,
the stage (`reading`, `models_and_images` or `placing`), how many of the scene's models and
images are done out of how many, the item loading now, and `fraction()`, from 0 to 1.

Only one scene streams at a time. A second `stream` call before the first is placed fails
with `SceneStreamBusy`. The game keeps updating while a scene streams. Each model or image
still loads on the main thread, so a very large one can hold a single frame. If a scene
fails to load, `streamed` returns the error and the world is left as it was.

## Check the loaded result

After `instantiate` succeeds, inspect the returned root and its immediate entities.
Nested instances appear at the normal scene-sync point. In the editor, an instance
selects as one root; open its source scene to inspect or edit generated descendants.

Test a packaged runtime as well as the editor. A missing resource must report an error
such as `FileNotFound` or `NotPackaged`; do not replace a failed load with empty data.
Check [startup scene configuration](../reference/project-configuration.md) if the
runtime opens a different scene from the one you expected.

## Understand packaged files {#what-the-runtime-receives}

[Assets, scenes, and packaging](../explanation/assets-and-scenes.md) explains the asset
catalog, packaged IDs, world-owned instances, and startup scene choices.
[Error handling](../how-to/handle-errors.md) covers required and optional loads.
See [feature support](../reference/feature-support.md#capability-support) for unavailable backends.

### Use engine-free format tools {#engine-free-format-tools}

See [engine-free format tools](../explanation/assets-and-scenes.md#engine-free-format-tools)
for the `eggy_assets` build import and format ownership, and the
[API reference](pathname:///api/) for low-level scene and asset operations.
