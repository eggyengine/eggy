---
sidebar_position: 19
title: Error handling
---

# Error handling

Eggy uses Zig error unions, optionals, and explicit ownership. There is no exception,
global error manager, or hidden retry system to configure.

## Absence is different from failure

Use an optional when something may normally be absent. `eggy.findNamed` and
`EntityRef.get` return `null` for a missing/dead/incompatible entity; an empty controller
list means no controller is connected. Use an error when an operation could not do its job:
invalid bindings, stale timers, allocation failures, unavailable features, and failed I/O
must not be mistaken for empty successful results.

Decide whether absence is optional for your game:

```zig
const camera = eggy.findNamed(&app.world, "Camera") orelse return error.MissingCamera;
const transform = app.world.get(camera, eggy.Transform) orelse
    return error.CameraNeedsTransform;
```

An optional effect can instead skip a missing target. A required startup dependency should
return an error with a meaningful game-specific name.

## Propagate requirements; handle recoverable cases

Use `try` when your hook cannot proceed correctly without the operation:

```zig
const level = eggy.AssetRef(.scene).init("resources/scene/level.scene.zon");
_ = try app.scenes().instantiate(level, .{});
```

Use `catch switch` when you have a real alternative for specific failures. For example,
load optional notes once in `init`, retaining ownership in your plugin:

```zig
const log = std.log.scoped(.my_game);

fn readNotes(gpa: std.mem.Allocator, app: *eggy.App) !?[:0]u8 {
    return app.resources().read(gpa, .init("resources/notes.txt")) catch |err| switch (err) {
        error.FileNotFound, error.NotPackaged => {
            log.warn("optional notes are absent: {t}", .{err});
            return null;
        },
        else => return err,
    };
}
```

Do not use `catch {}` or `catch null` for every error. They hide corruption, permissions,
and allocation failures along with expected absence. Do not log a failing optional operation
every frame: decide once, retain an explicit disabled/error state, or retry after a relevant
change. Use `std.log.scoped` for context; the editor sends logs to its Console.

## Clean up where ownership changes

Use `defer` for temporary owned data and `errdefer` for a partially constructed owner:

```zig
const notes = try app.resources().read(gpa, .init("resources/notes.txt"));
defer gpa.free(notes);

var model = try app.resources().loadModel(gpa, .init("resources/models/rat.glb"));
defer model.deinit(gpa);
```

A successful `read`/`loadModel` transfers data ownership to the caller. Scene entities
instead belong to the world. A borrowed `world.get` pointer needs no free and must not
survive structural changes/reload. `Action(T)` itself does not deep-copy pointer fields.

An error does not automatically undo arbitrary changes your hook already made. Validate
and allocate first, then commit. Use the [editor's action/group APIs](editor-tools.md) for
reversible editor edits. Input-settings writes validate and atomically replace the project
file before installing the active configuration; a failed save retains the active mapping.

## Know the execution boundary

| Boundary | Unhandled error behavior |
| --- | --- |
| Standalone runtime initialization, frame, or event | Report a fatal native dialog and exit; browser reporting uses its console |
| Plugin initialization | Stop plugins already initialized; standalone startup fails |
| Game-library startup in the editor | Log failure; the editor stays open without a started game |
| Game/library update, event, UI, drawing, or editor hook | Log the failure and keep the editor/game loop running |
| Panic/assertion/`unreachable` | A programming failure, not a recoverable error union; can terminate the whole process |

The editor deduplicates repeated failures per hook category/error until the error changes
or that hook succeeds. A failed hook call can skip remaining plugins in that invocation;
it does not roll the world back. A failed UI consumer is treated as consuming the event,
rather than leaking it into gameplay. An editor tool reporting an error is not evidence
that the same error is safe to ignore in a standalone build.

Existing host recovery is explicit: the runtime logs startup-scene read/parse/instantiation
failures and continues; a missing packaged data folder is warned about. Invalid serialized
scene fields/components may be logged and skipped. Strict author calls such as
`resources().read` and `scenes().instantiate` still return their own operation failures.
If your game requires a scene, load/check it explicitly instead of relying on permissive
host startup recovery.

## Public errors and feature support

Check each API's doc comment for its error/ownership contract. Common distinctions include:

| API | Errors to distinguish |
| --- | --- |
| Resource reads | `FileNotFound`, `NotPackaged`, `InvalidAssetData`, `InvalidPath`, `OutOfMemory`, `AssetLoadFailed` |
| Input snapshots/maps | `ControllerDisconnected`, `BufferTooSmall`, `UnknownControl`, `WrongControlKind`, `InvalidBinding`, `InvalidTrigger` |
| Persistent input edits | `TransientControllerBinding`, `InputSettingsFailed` (host logs underlying I/O failure) |
| Timers/time scaling | `InvalidDuration`, `StaleTimer`, `InvalidTimeScale` |
| Missing backends | `NotImplemented`; never a fabricated successful handle |

Support queries distinguish implemented capabilities from contracts. For example,
`eggy.audio.support` remains `.not_implemented`, while `eggy.input.controller_support`
is `.available`. The latter does not guarantee a device is attached or supports rumble.
Choose an explicit alternate experience for an optional feature; do not suppress a
required subsystem failure just to keep returning success.

When writing your own public helpers, prefer a concrete error set when it gives callers
a useful stable contract. Inferred `!T` is convenient inside a feature. Use optionals for
absence and never use `unreachable` to handle a player, file, or device input error.

## Editor/game-library calls

The editor and game library are separate compilations. Raw Zig error numbers are local to
each compilation: do not put `anyerror` values in your own C ABI messages. Eggy's host
services use C-callable callbacks and fixed status codes, translated to local Zig errors
on the calling side. Other host failures are logged before returning a stable service error.
Use the provided services rather than retaining a host loader or an old library callback.

Rebuild the editor and library together after changing Eggy. Borrowed contexts, map views,
and component pointers must not outlive their documented world/library generation.
