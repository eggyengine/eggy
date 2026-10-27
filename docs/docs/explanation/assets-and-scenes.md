---
sidebar_position: 3
title: Assets, scenes, and packaging
---

A resource reference identifies a project file. Loading that reference produces
caller-owned CPU data; rendering a Mesh uses renderer-owned GPU caches. Those
objects have different lifetimes even when they refer to the same model or image.
The [loading guide](../how-to/load-assets.md) shows the calls for each task.

## The asset catalog connects source files to packaged data {#what-the-runtime-receives}

The editor keeps one hidden catalog, `.eggy/assets.zon`, giving every file and folder in
`resources/` an ID, a kind, and (for models) an import scale. Editor file operations keep
IDs through moves, renames, and trash and restore; copies receive new IDs. Keep the catalog
in version control with the assets. Projects from older versions have `<file>.eggy`
descriptors beside their resources: the editor moves them into the catalog when it opens the
project, then deletes them.

A model file opens in the Assets panel into its geometry (`Skeletal` when the model has
animation clips, else `Static`), one entry for each of its clips, and one image for each
texture its materials use (`Material 1` and on). Those entries have IDs of their own, so a
reference field can name a single clip or texture, but they are not files: they can't be
renamed, moved, or deleted. Drag a material onto a folder (or right-click it and choose
**Extract as PNG**) to save its texture there as a PNG you can edit in any image editor.

The editor refreshes model and image imports after changes. Packaging converts models
to `.eggmodel` and decoded images to `.eggtexture`, copies other resources unchanged,
and names the packaged files after their IDs in `data/`. Game code refers to assets by
reference, which the build resolves to IDs; it must not reconstruct packaged filenames.

## Scene instances belong to the world

A `SceneInstance` root refers to a source scene. Saving the containing scene stores
that instance, not its generated descendants. Refreshing the source scene updates
each instance. Clicking an instance in the Scene selects its root. The Hierarchy lists its
generated descendants under it, tinted: change their fields to tune that instance alone,
and the containing scene saves only those changes, as overrides on the instance (see
[Tune one scene instance](../how-to/edit-entity-trees.md#tune-one-scene-instance)). To
change what the instance is made of, open the source scene.

Instantiated entities keep the source scene's parent tree, with entity references
remapped to the new entities. Recursive scene instances are prevented. Components or
fields no longer known by the project are logged and skipped, as when the editor
opens an older scene.

The world owns the returned root and generated entities. Immediate scene entities
exist before `app.scenes().instantiate` returns; nested instances synchronize at the
normal scene-sync point. A failed read, parse, or allocation removes entities created
by that call. Borrowed service views and component pointers do not survive a world
reset or reload. See [ownership and reload](ownership-and-reload.md).

## Startup scene choices

The runtime starts in the scene named by `-Dscene`, otherwise the project's default
scene. A local runtime build may fall back to the scene last open in the editor, then
the first scene. Export requires an explicit or default startup scene. The
[project configuration reference](../reference/project-configuration.md) covers these
settings, and [build and export](../how-to/build-and-export.md) covers choosing them
for a build.

## Low-level scene access

Tools that need diagnostics and entity lists can use `Scene.capture`, `parse`,
`write`, and `instantiate` directly.

`scene.Access.readFieldAlloc(gpa, world, entity, component, field)` returns complete
field ZON. `nameAlloc(gpa, world, entity)` returns an entity name, or null when it has
none. Free each returned string with `gpa.free`. Field reads report missing components
or fields as errors. The buffer-based `readField` and `name` are available when the
caller manages storage.

## Engine-free format tools

Build tools can import `eggy_assets` without linking App, SDL, GPU, or editor code:

```zig
const engine = b.dependency("eggy", .{ .target = target, .optimize = optimize });
tool.root_module.addImport("eggy_assets", engine.module("eggy_assets"));
```

Its catalog, model, imported-clip, and texture formats use explicit readers, writers,
allocators, and `std.Io` where needed. Games can also access it as `eggy.assets`.

Browser builds read their preloaded packaged resources synchronously, and decode
asynchronous requests when they are polled. Scene streaming still returns `NotImplemented`.

## Switch levels

Call `try app.scenes().replace(.init("resources/levels/next.scene.zon"))` from game code.
Eggy reads and parses the target immediately, then commits it after the current gameplay
hooks and systems finish. Only one replacement can be pending.

The old entities remain until the new scene instantiates successfully. A missing file or
invalid scene reports an error rather than clearing the current level. Unknown or invalid
components reject the replacement rather than loading a partially defaulted level.

Replacement removes all old entities, including entities created by game code. Plugin
instances, world resources, schedules, preferences and game UI survive; store cross-level
progress there, not in an entity you expect to survive. Resolve entity references again
after switching. Nested scene instances populate at the usual scene-sync point.
