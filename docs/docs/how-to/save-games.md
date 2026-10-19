---
sidebar_position: 16
title: Save games
---

Use `app.storage` for a player's progress. Save slots are separate from project
resources, scene files and plugin preferences.

## Write, read and delete a slot

Serialize your game's state to bytes using the format your game owns:

```zig
try app.storage.write("slot-1", serialized_save);

const bytes = try app.storage.read(gpa, "slot-1");
defer gpa.free(bytes);
// Decode and validate bytes using your game's serializer.

try app.storage.remove("slot-1");
```

Reads return an independent allocation owned by the supplied allocator. Empty
payloads are valid. Slots contain 1–64 ASCII letters, digits, underscores or
hyphens. Names are case-sensitive logical identifiers, not paths; dots, slashes,
backslashes, spaces and traversal are rejected with `InvalidSlot`. Case-distinct
slot names remain distinct even on case-insensitive filesystems.

`write` atomically replaces the previous save. It never truncates a slot in place:
desktop/Android write and sync a sibling file before renaming it, and browsers use
one atomic localStorage replacement. Interrupted writes may leave an unused sibling
file, but not a partially written destination. Do not depend on a successful write
surviving sudden power loss, user deletion or browser eviction.

## Version your game's data

The short methods use game schema version 1. When your serialized layout changes,
choose an explicit version:

```zig
const schema: u32 = 2;
try app.storage.writeVersion("autosave", schema, serialized_save);

const bytes = try app.storage.readVersion(gpa, "autosave", schema);
defer gpa.free(bytes);
```

An incompatible game schema returns `UnsupportedSaveSchema`. To migrate a known
old schema, deliberately read that version, decode and convert it, then write the
new version. Never overwrite an incompatible or corrupt save with defaults just
because loading failed.

Eggy wraps the payload in a binary envelope with the `EGGYSAVE` magic, little-endian
engine format version (`u32`), game schema (`u32`), payload length (`u64`) and SHA-256
payload checksum. The current envelope format is 1 and its header is 56 bytes.
An unknown engine format returns `UnsupportedSaveFormat`; damaged, truncated or
trailing data returns `CorruptSave`. Payloads are limited to 64 MiB. The checksum
detects accidental damage, not cheating or malicious changes.

## Handle failures visibly

`FileNotFound` means there is no save in the requested slot, including when deleting
a missing slot. `SaveTooLarge` rejects oversized payloads. `AccessDenied`,
`StorageFull`, `StorageIo` and `OutOfMemory` are failures, not empty successful reads.
Report save failures to the player and preserve their previous progress.
Your own decoder must still validate the payload's contents.

There is no automatic empty save, preferences fallback, resource fallback or
in-memory persistence fallback.

## Where saves live

On desktop and Android, saves use SDL's writable per-user data folder for the
organization `eggy` and application `games`, then a SHA-256 project namespace and
`saves/`. No project checkout or packaged resources need to be writable.
The editor and packaged runtime share saves when they use the same project ID.
Renaming that ID starts a different namespace; moving the project does not.

Browser saves use **localStorage**, scoped to the page's origin and project ID,
not Emscripten's transient MEMFS. They survive page reloads when the browser permits
storage. Browser quotas are usually much smaller than Eggy's payload limit;
private browsing, disabled site storage, clearing site data and eviction can prevent
or remove persistence. Quota failures return `StorageFull`; unavailable or blocked
Web Storage returns `UnsupportedPlatform`. A different origin, including a different
development-server port, has different saves.
Custom web hosts must permit Emscripten's default JavaScript dynamic execution;
the current bridge does not support a Content Security Policy that forbids `eval`.

## Custom hosts

The engine host must explicitly initialize storage before game/plugin initialization:

```zig
app.storage = try eggy.storage.Storage.init(process.gpa, process.io, project.name);
```

Use the same nonempty stable project identity in editor and runtime, not the window
title, executable path or project directory. Setup errors must be handled explicitly.
An uninitialized service returns `StorageNotInitialized`.
After plugin and world shutdown, call `app.storage.deinit()` before shutting down
SDL or the process I/O. The owner may move with `App`; copied service views borrow
the heap-stable host provider and must not outlive it. Calls are synchronous: keep
them on the host/game thread and save outside hot frame paths.
