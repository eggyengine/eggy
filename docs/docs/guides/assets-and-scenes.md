---
sidebar_position: 7
title: Assets and scenes
---

# Assets and scenes

A resource reference, loaded CPU data, and a GPU cache entry are different things.
Keeping that distinction explicit makes the same game code usable in the editor and a
packaged runtime.

## Create files in Assets

Use **New** in the Assets toolbar, or **New >** in the right-click menu. Both offer
Scene, Input Map, Folder, and text, Zig, ZON, JSON, Markdown, and TOML templates, along with file types
declared by the game's plugins. New files get unique names and can be undone.
Right-click a folder to create inside it; right-click a file to create beside it.

Double-click `.inmap.zon` assets to open the [Input Map editor](input-mappings.md).
Images, models, audio, and fonts are imported from existing files, not created as
empty placeholders. Plugins can [add their own templates](plugins.md#file-templates).

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
dragged files. An audio reference is valid data even though playback is not implemented.

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

Bytes are sentinel-terminated and caller-owned. Image pixels are RGBA bytes, top row first.
Models contain static geometry, parts, and textures. Neither return value is a GPU handle.
Use these operations outside hot frame paths when possible: providers are synchronous.

`read` is for resources copied unchanged, such as text, scenes, and fonts.
It rejects converted models/images with `ConvertedResource`; use the typed loader instead.
Image loading supports formats decoded by the existing image importer, including PNG,
JPEG, GIF, and BMP. SVG and WebP classification does not imply texture decoding:
`loadImage` rejects them with `UnsupportedImageFormat`.

Missing/corrupt/unsupported resources return errors, not empty successful data.
Common errors include `UnsetAsset`, `FileNotFound`, `NotPackaged`, `InvalidAssetData`,
`OutOfMemory`, and `AssetLoadFailed`. Provider diagnostics explain other failures.

## Instantiate a scene

```zig
const rat_scene = eggy.AssetRef(.scene).init("resources/scene/rat.scene.zon");
const root = try app.scenes().instantiate(rat_scene, .{ .parent = parent });
```

The returned root is owned by the world and has a `Transform` and `SceneInstance`.
Its immediate scene entities exist before the call returns. Nested instances synchronize
at the normal scene-sync point. A failed read/parse/allocation removes the entities created
by that call.

The instance is saved, not its generated descendants. Editing the source scene changes
each instance when its files are refreshed. Recursive scene instances are prevented rather
than expanded forever.

An instance's entities use the source scene's parent tree and remapped entity references.
Components/fields no longer known by the project are logged and skipped, as when the
editor opens an older scene. Public low-level `Scene.capture`, `parse`, `write`, and
`instantiate` remain available for tools that need their diagnostics and entity lists.

Low-level `scene.Access` also provides `readFieldAlloc(gpa, world, entity, component, field)`
for complete field ZON and `nameAlloc(gpa, world, entity)` for an entity name. Free each
returned string with `gpa.free`; `nameAlloc` returns null without a name, while field reads
report missing components/fields as errors. The buffer-based `readField` and `name` remain
available when you manage storage yourself.

Service views and component pointers do not survive a world reset or reload. Use fresh
App access and typed `EntityRef` resolution instead of retaining borrowed storage.

## What the runtime receives

The editor maintains `<file>.eggy` descriptors beside project resources. A descriptor
contains an ID, kind, and model import scale. Use the editor's file operations to carry
descriptors through moves/renames; copies receive new IDs.

Packaging converts models to `.eggmodel` and decoded images to `.eggtexture`, copies
other resources unchanged, and names them after IDs in `data/`. `data/manifest.zon`
maps their project paths to those IDs. Do not reconstruct packaged filenames in game code.

The runtime starts in `-Dscene`'s scene, otherwise the project's default scene. A local
runtime build may fall back to the scene last open in the editor, then the first scene;
export requires an explicit/default startup scene.

## Engine-free format tools

Build tools can import the published `eggy_assets` module without linking App, SDL, GPU,
or editor code:

```zig
const engine = b.dependency("eggy", .{ .target = target, .optimize = optimize });
tool.root_module.addImport("eggy_assets", engine.module("eggy_assets"));
```

Its descriptors, manifest, model, and texture formats use explicit readers, writers,
allocators, and `std.Io` where needed. It is also re-exported as `eggy.assets` for games.

`descriptor.pathOfAlloc(gpa, path)` and `manifest.packagedNameAlloc(gpa, entry)` allocate
their resulting paths/names; free them with `gpa.free`. Their original buffer-based
counterparts remain allocation-free.

Browser resource providers are not implemented. Async reads, streaming, and scene
replacement currently return `NotImplemented`; a typed reference is not a promise that
one of those backends exists.
