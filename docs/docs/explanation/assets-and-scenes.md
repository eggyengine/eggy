---
sidebar_position: 3
title: Assets, scenes, and packaging
---

A resource reference identifies a project file. Loading that reference produces
caller-owned CPU data; rendering a Mesh uses renderer-owned GPU caches. Those
objects have different lifetimes even when they refer to the same model or image.
The [loading guide](../how-to/load-assets.md) shows the calls for each task.

## Descriptors connect source files to packaged data {#what-the-runtime-receives}

The editor maintains `<file>.eggy` descriptors beside project resources. A descriptor
contains an ID, kind, and model import scale. Editor file operations carry descriptors
through moves and renames; copies receive new IDs. Keep descriptors with their assets
in version control.

For example, a model descriptor can scale geometry imported from centimetres:

```zig
.{ .id = 8470855589818597979, .kind = .model, .model = .{ .scale = 0.01 } }
```

The editor refreshes model and image imports after changes. Packaging converts models
to `.eggmodel` and decoded images to `.eggtexture`, copies other resources unchanged,
and names the packaged files after IDs in `data/`. `data/manifest.zon` maps project
paths to those IDs. Game code uses resource services with project paths; it must not
reconstruct packaged filenames.

## Scene instances belong to the world

A `SceneInstance` root refers to a source scene. Saving the containing scene stores
that instance, not its generated descendants. Refreshing the source scene updates
each instance. The editor selects the instance root and hides generated descendants
in the Hierarchy; edit them by opening the source scene.

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

Its descriptor, manifest, model, and texture formats use explicit readers, writers,
allocators, and `std.Io` where needed. Games can also access it as `eggy.assets`.

`descriptor.pathOfAlloc(gpa, path)` and `manifest.packagedNameAlloc(gpa, entry)`
allocate their resulting paths or names; free them with `gpa.free`. Their original
buffer-based counterparts remain allocation-free.

Browser builds read their preloaded packaged resources synchronously. Async reads and
streaming still return `NotImplemented`.

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
