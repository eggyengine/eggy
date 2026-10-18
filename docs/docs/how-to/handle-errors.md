---
sidebar_position: 12
title: Diagnose and handle errors
slug: /guides/error-handling
---

Decide which operations your game requires, handle specific recoverable failures, and
release owned resources when a hook returns an error. Check the execution boundary
before relying on the editor to keep running after a failure.

Use these patterns inside a [game or plugin hook](../reference/plugin-hooks.md#hooks).
Eggy uses Zig error unions and optionals with explicit ownership; it has no exception,
global error manager, or hidden retry system.

## Inspect the Console

Use the Errors, Warnings, Info, and Debug level filters together with the text
filter to narrow the log. The text filter searches both messages and details.
Debug messages stay hidden unless enabled in Preferences. Logs written with
`std.log.scoped` appear in the Console.

Click a line to expand or collapse its selectable, copyable details. Compiler
source excerpts, notes, and reference traces stay grouped with the diagnostic,
including when Info is disabled. The Console omits the build-step tree,
failed-command lines, and redundant summaries. Open the Build window when you
need the raw build output.

Follow a source link to open its line and column in the editor configured under
Edit > Preferences > Code editor. If an Eggy compiler error includes a project
declaration, the source link prefers that declaration. The system-default editor
may open the file without jumping to the location.

For an older `editorUi` or `editorPanelUi` signature, inspect the details for the
original compiler diagnostic, the expected signature, and the project declaration.

### Copy or dismiss diagnostics

Use Copy shown to copy messages that pass the current filters, including their
details. Copy message copies the current message or the selected detail text.

Hide message dismisses an entry without deleting it. Restore hidden brings entries
back through the current filters, so a restored entry can remain filtered out.
Clear deletes the log.

## Decide whether a missing value is an error {#absence-is-different-from-failure}

Use an optional when something may normally be absent. `eggy.findNamed` and
`EntityRef.get` return `null` for a missing/dead/incompatible entity; an empty controller
list means no controller is connected. Use an error when an operation could not do its job:
invalid bindings, stale timers, allocation failures, unavailable features, and failed I/O
must be reported as failures.

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

Do not use `catch {}` or `catch null` for every error. They hide corruption, permission,
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
and allocate first, then commit. Use the [editor's action/group APIs](../how-to/extend-editor.md) for
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

## Trace the reported failure {#public-errors-and-feature-support}

Read the failing operation's error and ownership contract in the
[API reference](pathname:///api/), then check the relevant subsystem:

- For resource failures, check the [path and packaging](../how-to/load-assets.md).
  Distinguish `FileNotFound` and `NotPackaged` from `InvalidAssetData`, `InvalidPath`,
  `OutOfMemory`, and `AssetLoadFailed` before deciding whether a fallback is appropriate.
- For input, check [device state](../how-to/read-input.md) and
  [map configuration](../how-to/map-input.md). `ControllerDisconnected` and
  `BufferTooSmall` need different handling from `UnknownControl`, `WrongControlKind`,
  `InvalidBinding`, and `InvalidTrigger`.
- For persistent input edits, distinguish `TransientControllerBinding` from
  `InputSettingsFailed`. For the latter, read the underlying I/O failure in the host log.
- For `InvalidDuration`, `StaleTimer`, or `InvalidTimeScale`, check the
  [timer and time controls](../how-to/timers.md) used by the failing call.
- For `NotImplemented`, check [feature support](../reference/feature-support.md#capability-support).
  Missing backends do not fabricate successful handles.
- For SDL's `SdlError`, read `sdl.errors.get()` immediately for the underlying reason.
  The [mouse and window guide](../how-to/sdl3.md#failures-and-reloads) shows how to log it.

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

## Check both failure paths

Test `readNotes` with the optional file absent. It should log the warning once when
called from `init` and return null. Other failures must still propagate.

Test a missing required scene with the explicit `scenes().instantiate` call. Check
the editor's Console, then test the standalone runtime, where an unhandled hook
error is fatal. The host's permissive startup-scene recovery does not replace this
required load.

## Related contracts

See [plugin hooks](../reference/plugin-hooks.md#hooks) for execution order,
[ownership and reload](../explanation/ownership-and-reload.md) for borrowed lifetimes,
and [feature support](../reference/feature-support.md#capability-support) before making
an unavailable subsystem a requirement.
