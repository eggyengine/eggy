---
sidebar_position: 2
title: Ownership, Play, and reload
---

# Ownership, Play, and reload

The host owns the App and ECS world. Plugins own their fields and any resources they
allocate. The editor can replace plugin code or restore a scene without restarting its
own UI, so the lifetime of a window is longer than the lifetime of a game instance.

## Values and borrowed views

Eggy stores plugins by value and may move them after `init`. Hooks receive the current
`self` and App pointers. Keeping either pointer in a callback or another long-lived
object can leave it pointing at an old location.

| Value | Lifetime rule |
| --- | --- |
| Plugin-owned allocations | Release in `deinit`, including on restart/reload |
| Entity IDs and `EntityRef` values | Resolve before use; deletion or a world reset can invalidate the entity |
| Component pointers and query views | Borrowed from the world; do not retain through storage changes or resets |
| `app.resources()` and `app.scenes()` views | Borrowed services; obey their documented provider/world lifetime |
| Editor, UI, and draw contexts | Borrowed for the current hook/frame |
| SDL window from `app.window.window` | Borrowed from the host; do not destroy it |
| Resource bytes and typed CPU-loader results | Owned by the supplied allocator; free or call `deinit(gpa)` as documented |

Store IDs or value references and resolve them again when needed. In the editor an
entity can be deleted between frames; `app.world.isAlive(entity)` checks a stored ID.
An `AssetRef` stores an asset path and kind. It does not own loaded bytes.
A `Voice` from `app.audio()` is a handle: every voice ends when the world resets
(Play, Stop and reload), and calls on an ended voice do nothing.

For concrete lookup and cleanup patterns, use
[Find entities safely](../how-to/render-scene.md#find-entities-safely) and
[Load assets and instantiate scenes](../how-to/load-assets.md).

## Play starts from the editable scene

While editing, the world represents the scene alone. Entities created by plugin
initialization for gameplay do not become saved scene content.

Pressing Play preserves the editable scene and starts the game on it: scene entities
first, then plugin `init` and anything it spawns. Stopping discards gameplay changes
and restores the editable scene, including removing entities spawned during Play.

To keep a selected entity's current `Transform`, press Ctrl+Shift+K while playing.
After Stop that transform is retained; Edit > Undo restores its previous value.
This keeps the transform, not all gameplay state.

Pause suspends gameplay `update`, systems, and gameplay input dispatch. Drawing and
game UI continue, while `editorUpdate` is available for tools.

## A game-library reload restarts plugin state

When changed game code is detected on refocus, the editor builds a replacement library
in its Build window. It preserves world entities as scene data and restores them for
the new library.

Old instances receive `deinit`; the new library creates instances with `init`.
Plugin fields therefore start fresh and ECS systems must be registered again.
Initialization should find the entities it needs instead of relying on old pointers.

The editor's layout, panels, and Console remain. Panel declarations are reconciled:
new panels open beside the Inspector, and removed panels close. Stable panel keys
keep layout identity when titles or declaration order change.

Any callback or view tied to the old library becomes invalid when it unloads.
Release callbacks and [SDL mouse/window state](../how-to/sdl3.md) while the old instance
is still alive; do not let host callbacks retain old code pointers.

## Engine changes replace the editor

The editor and game library must use the same Eggy revision because engine pointers
cross their C-callable boundary. An engine change rebuilds the whole editor instead
of swapping an incompatible game library. The Reload button opens the rebuilt editor.

When the project is linked to an Eggy checkout and that checkout gained changes that
can break your code (commits marked `!` or `BREAKING CHANGE:`, or a new major version,
or a new minor version before 1.0), the editor asks before rebuilding onto them. A very
large update (a new major version, or five or more breaking changes) shows the whole
changelog. **Skip this session** keeps the current editor until you close it: it stops
rebuilding on refocus, and Reload asks again.

Use [Extend the editor](../how-to/extend-editor.md) for queued build/reload requests and
undoable scene changes. The [hook reference](../reference/plugin-hooks.md) defines when
initialization, cleanup, and editor hooks run.
